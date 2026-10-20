# Immich → living-room TV photo frame
#
# The Chromecast's screensaver is Aerial Views, whose Immich source can follow
# albums but not people. This keeps one album, "Living Room TV", holding a fresh
# nightly selection of photos of the girls: half from the last year, half older,
# with the older half spread evenly across years so the baby years are not
# drowned out by whichever year had the most photos. Each run draws a new random
# sample, so the TV never settles on the same set.
#
# Writes go straight to the album_asset table rather than through the API, so no
# Immich credential exists for this. Immich's own triggers on that table keep
# updateId and the delete audit current, which is what the mobile apps sync on.
# Only the one album named below is ever touched.
{pkgs, ...}: let
  albumName = "Living Room TV";
  # Immich user UUID owning both the album and the named people (alex).
  ownerId = "c85fe467-a36a-457a-a260-a67dfe2199da";
  people = ["Amanda" "Beatrice"];
  recentCount = 120;
  olderCount = 120;
  # Smallest face, as a fraction of image width, that counts as "in" a photo.
  # Drops group shots where a daughter is a speck in the background.
  minFaceWidth = 0.06;

  sql = pkgs.writeText "immich-tv-frame.sql" ''
    \set ON_ERROR_STOP on
    begin;

    create temp table frame_album on commit drop as
      select a.id from album a
      join album_user au on au."albumId" = a.id and au.role = 'owner'
      where a."albumName" = :'album' and au."userId" = :'owner' and a."deletedAt" is null;

    with new_album as (
      insert into album ("albumName", description)
      select :'album', 'Managed by immich-tv-frame on galactica; contents are replaced nightly.'
      where not exists (select 1 from frame_album)
      returning id
    ), new_owner as (
      insert into album_user ("albumId", "userId", role)
      select id, :'owner', 'owner' from new_album
      returning "albumId"
    )
    insert into frame_album select "albumId" from new_owner;

    -- One row per photo; near-duplicate bursts collapse to a single candidate.
    create temp table pool on commit drop as
      select distinct on (coalesce(a."duplicateId", a.id)) a.id, a."localDateTime" as taken
      from asset a
      join asset_face f on f."assetId" = a.id and f."deletedAt" is null and f."isVisible"
      join person p on p."personGroupId" = f."personGroupId"
      where p.name = any(:'people'::text[]) and p."ownerId" = :'owner'
        and a.type = 'IMAGE' and a.visibility = 'timeline' and a."deletedAt" is null
        and a."originalFileName" not ilike '%screenshot%'
        and (f."boundingBoxX2" - f."boundingBoxX1")::float / f."imageWidth" >= :minface
      order by coalesce(a."duplicateId", a.id), random();

    create temp table pick on commit drop as
      (select id from pool where taken >= now() - interval '1 year'
       order by random() limit :recent)
      union
      (select id from (
         select id, row_number() over (partition by extract(year from taken) order by random()) as rn
         from pool where taken < now() - interval '1 year'
       ) s order by rn, random() limit :older);

    delete from album_asset
    where "albumId" = (select id from frame_album)
      and "assetId" not in (select id from pick);

    insert into album_asset ("albumId", "assetId")
    select (select id from frame_album), id from pick
    on conflict do nothing;

    update album set "albumThumbnailAssetId" = (select id from pick order by random() limit 1)
    where id = (select id from frame_album);

    select count(*) || ' photos in album' from album_asset where "albumId" = (select id from frame_album);
    commit;
  '';

  immichTvFrame = pkgs.writeShellApplication {
    name = "immich-tv-frame";
    runtimeInputs = [pkgs.postgresql];
    text = ''
      exec psql -X -q -At -h /run/postgresql -U immich -d immich \
        -v album=${pkgs.lib.escapeShellArg albumName} \
        -v owner=${ownerId} \
        -v people='{${builtins.concatStringsSep "," people}}' \
        -v recent=${toString recentCount} \
        -v older=${toString olderCount} \
        -v minface=${toString minFaceWidth} \
        -f ${sql}
    '';
  };
in {
  environment.systemPackages = [immichTvFrame];

  systemd.services.immich-tv-frame = {
    description = "Refresh the living-room TV photo album in Immich";
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichTvFrame}/bin/immich-tv-frame";
      # Maps to the immich database role via the ident map in db.nix.
      User = "media";
      Group = "media";
    };
  };

  systemd.timers.immich-tv-frame = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}

{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib;
{
  nixpkgs.overlays = [
    (final: prev: {
      radarr = prev.radarr.overrideAttrs (old: rec {
        installPhase = ''
          runHook preInstall
          mkdir -p $out/{bin,share/${old.pname}-${old.version}}
          cp -r * $out/share/${old.pname}-${old.version}/.
          makeWrapper "${final.dotnet-runtime}/bin/dotnet" $out/bin/Radarr \
            --add-flags "$out/share/${old.pname}-${old.version}/Radarr.dll" \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
              final.curl final.sqlite final.libmediainfo final.mono final.openssl final.icu final.zlib ]}
          runHook postInstall
        '';
      });
      
      prowlarr = prev.prowlarr.overrideAttrs (old: {
        installPhase = ''
          runHook preInstall
          mkdir -p $out/{bin,share/${old.pname}-${old.version}}
          cp -r * $out/share/${old.pname}-${old.version}/.
          makeWrapper "${final.dotnet-runtime}/bin/dotnet" $out/bin/Prowlarr \
            --add-flags "$out/share/${old.pname}-${old.version}/Prowlarr.dll" \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
              final.curl final.sqlite final.libmediainfo final.mono final.openssl final.icu final.zlib ]}
          runHook postInstall
        '';
      });
    })
  ];
}
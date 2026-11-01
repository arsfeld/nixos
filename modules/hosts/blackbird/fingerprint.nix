# Fingerprint: fprintd with the goodix-521d libfprint, gdm-fingerprint PAM module path.
{
  configurations.nixos.blackbird.module = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Goodix 27c6:521d (built-in fingerprint reader) is on libfprint's
    # known-unsupported list, so fprintd is pointed at
    # pkgs.libfprint-goodix-521d, a fork carrying the community goodixtls
    # driver patched to accept this sensor's firmware. fprintd takes libfprint
    # as an overridable argument, which keeps the fork scoped to this host
    # instead of overlaying libfprint globally -- the overlay in
    # modules/flake/lib.nix would otherwise put all nine hosts on a libfprint
    # that carries an out-of-tree driver none of them have hardware for.
    #
    # Security note (deliberate, accepted choice, reviewed 2026-09-05): NixOS
    # defaults security.pam.services.<name>.fprintAuth to services.fprintd.enable,
    # so `enable = true` below implicitly inserts `auth sufficient pam_fprintd.so`
    # ahead of pam_unix in every PAM service NixOS generates -- sudo, su,
    # polkit-1, sshd, gdm-fingerprint and others. A fingerprint is therefore
    # sufficient on its own for root escalation via sudo/polkit, not merely a
    # convenience alongside the password. This is intentional: the user has
    # accepted sudo-by-fingerprint knowing the sensor's channel is keyed with a
    # PSK of 32 zero bytes (see the Task 4C/Task 9 fingerprint-sensor spec), so
    # brief physical access to the USB device could capture the image stream.
    #
    # Dual-boot: booting Windows does nothing by itself, but *enrolling in
    # Windows Hello* reverts the sensor to firmware 10034 and provisions a fresh
    # random PSK, after which fprintd fails activation with
    # "Invalid device PSK". Recovery is to reflash from Linux with the zero PSK.
    # The PSK differs on every Windows provisioning, so there is no key to
    # recover and no way to make both OSes work at once -- see Task 9 in the
    # spec, and packages/libfprint-goodix-521d/extract-firmware.py for the
    # 10034 image the reflash needs.
    # sshd picking up pam_fprintd is an inert side effect of the same default --
    # nobody can touch a laptop's internal USB fingerprint sensor over a
    # network session, and `sufficient` just falls through to pam_unix on
    # failure/no-match, so remote password auth is unaffected. Do not set
    # fprintAuth = false anywhere below; that would silently change accepted
    # behaviour. See docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
    # for the full writeup.
    services.fprintd = {
      enable = true;
      package = pkgs.fprintd.override {
        libfprint = pkgs.libfprint-goodix-521d;
      };
    };

    # nixpkgs builds the gdm-fingerprint PAM stack from `pkgs.fprintd` rather
    # than `config.services.fprintd.package` (gdm.nix, vs pam.nix which does use
    # the latter), so the override above reaches every PAM service except this
    # one. Login still works -- pam_fprintd links no libfprint, it is a D-Bus
    # client of net.reactivated.Fprint, and the daemon owning that name is ours
    # -- but it is the only thing dragging a second fprintd and a stock
    # libfprint into the system closure. Point it at the same package.
    security.pam.services.gdm-fingerprint.rules.auth.fprintd.modulePath =
      lib.mkForce "${config.services.fprintd.package}/lib/security/pam_fprintd.so";
  };
}

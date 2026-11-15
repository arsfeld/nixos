# Elementary wallpapers and 30-minute rotation for Pantheon desktop and LightDM greeter.
#
# Fixes three gaps in nixpkgs' Pantheon packaging:
#   1. elementary-greeter's hardcode-fallback-background.patch points at NixOS's
#      simple-dark-gray; override it to elementaryos-default and set dconf
#      picture-uri defaults so GreeterCompositor never falls back to a missing
#      adwaita-l.jxl (solid black background).
#   2. switchboard-plug-pantheon-shell skips every entry where get_is_symlink()
#      is true, hiding all buildEnv symlinks in /run/current-system/sw/share/backgrounds;
#      narrow the skip check to only elementaryos-default.
#   3. io.elementary.settings-daemon only syncs picture-uri to LightDM when it
#      changes interactively; seed LightDM greeter data + AccountsService before
#      display-manager starts, and rotate both Gala and LightDM at login + every 30m.
{
  flake.modules.nixos.pantheon-wallpapers = {
    key = "modules/desktop/pantheon-wallpapers";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        wallpaperDir = "${pkgs.pantheon.elementary-wallpapers}/share/backgrounds";
        normalUsers = lib.attrValues (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

        seedUserScript = user: let
          qUser = lib.escapeShellArg user.name;
        in ''
          user_dir="/var/lib/lightdm-data/${user.name}"
          dest="$user_dir/wallpaper"
          install -d -m 0770 -o ${qUser} -g lightdm "$user_dir"
          if [ ! -s "$dest" ]; then
            chosen=$(find "${wallpaperDir}" -maxdepth 1 -type f -name '*.jpg' | shuf -n 1)
            if [ -n "$chosen" ]; then
              install -m 0644 -o ${qUser} -g lightdm "$chosen" "$dest"
            fi
          fi
          if [ -s "$dest" ]; then
            user_uid=$(id -u ${qUser})
            user_path="/org/freedesktop/Accounts/User$user_uid"
            gdbus call --system \
              --dest org.freedesktop.Accounts \
              --object-path /org/freedesktop/Accounts \
              --method org.freedesktop.Accounts.FindUserByName \
              ${qUser} >/dev/null 2>&1 || true
            current_bg=$(
              gdbus call --system \
                --dest org.freedesktop.Accounts \
                --object-path "$user_path" \
                --method org.freedesktop.DBus.Properties.Get \
                org.freedesktop.DisplayManager.AccountsService \
                BackgroundFile 2>/dev/null || true
            )
            if [ "$current_bg" != "(<'$dest'>,)" ]; then
              gdbus call --system \
                --dest org.freedesktop.Accounts \
                --object-path "$user_path" \
                --method org.freedesktop.DBus.Properties.Set \
                org.freedesktop.DisplayManager.AccountsService \
                BackgroundFile "<'$dest'>" >/dev/null 2>&1 || true
            fi
          fi
        '';
      in {
        config = lib.mkIf config.services.desktopManager.pantheon.enable {
          nixpkgs.overlays = [
            (_final: prev: {
              pantheon = prev.pantheon.overrideScope (pfinal: pprev: {
                elementary-greeter = pprev.elementary-greeter.overrideAttrs (old: {
                  postPatch =
                    (old.postPatch or "")
                    + ''
                      substituteInPlace src/Widgets/BackgroundImage.vala \
                        --replace-fail "${prev.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath}" "${pfinal.elementary-wallpapers}/share/backgrounds/elementaryos-default"
                    '';
                });

                switchboard-plug-pantheon-shell = pprev.switchboard-plug-pantheon-shell.overrideAttrs (old: {
                  postPatch =
                    (old.postPatch or "")
                    + ''
                      substituteInPlace src/Views/Wallpaper.vala \
                        --replace-fail "file_info.get_is_symlink ()" '(file_info.get_is_symlink () && file_info.get_name () == "elementaryos-default")'
                    '';
                });
              });
            })
          ];

          programs.dconf.profiles.user.databases = [
            {
              settings."org/gnome/desktop/background" = {
                picture-uri = "file:///run/current-system/sw/share/backgrounds/elementaryos-default";
                picture-uri-dark = "";
                picture-options = "zoom";
              };
            }
          ];

          systemd.services.pantheon-greeter-wallpaper-seed = lib.mkIf config.services.xserver.displayManager.lightdm.enable {
            description = "Seed Pantheon greeter wallpaper for normal users";
            wantedBy = ["multi-user.target" "display-manager.service"];
            before = ["display-manager.service"];
            after = ["accounts-daemon.service" "systemd-tmpfiles-setup.service"];
            wants = ["accounts-daemon.service"];
            path = [pkgs.coreutils pkgs.findutils pkgs.glib.bin];
            serviceConfig.Type = "oneshot";
            script = ''
              set -euo pipefail
              if ! id -u lightdm >/dev/null 2>&1; then
                exit 0
              fi
              if [ ! -d /var/lib/lightdm-data ]; then
                install -d -m 1775 -o lightdm -g lightdm /var/lib/lightdm-data
              fi
              ${lib.concatMapStringsSep "\n" seedUserScript normalUsers}
            '';
          };

          systemd.user.services.pantheon-wallpaper-rotate = {
            description = "Rotate Pantheon desktop and login screen wallpaper";
            after = ["graphical-session.target"];
            partOf = ["graphical-session.target"];
            path = [pkgs.coreutils pkgs.findutils pkgs.glib.bin pkgs.gnused];
            serviceConfig.Type = "oneshot";
            script = ''
              set -euo pipefail
              case "''${XDG_CURRENT_DESKTOP:-}" in
                *Pantheon*) ;;
                *) exit 0 ;;
              esac

              current=$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null | tr -d "'" || true)
              current_local=$(gio info -a standard::name "$current" 2>/dev/null | sed -n 's/^local path: //p' || true)
              if [ -n "$current_local" ]; then
                current_base=$(basename "$(readlink -f "$current_local" 2>/dev/null || printf '%s' "$current_local")")
              else
                current_base=""
              fi

              chosen_store=$(
                find "${wallpaperDir}" -maxdepth 1 -type f -name '*.jpg' \
                  ! -name "$current_base" \
                  | shuf -n 1
              )
              if [ -z "$chosen_store" ]; then
                chosen_store=$(find "${wallpaperDir}" -maxdepth 1 -type f -name '*.jpg' | shuf -n 1)
              fi
              [ -n "$chosen_store" ] || exit 0

              base=$(basename "$chosen_store")
              if [ -e "/run/current-system/sw/share/backgrounds/$base" ]; then
                chosen="/run/current-system/sw/share/backgrounds/$base"
              else
                chosen="$chosen_store"
              fi

              chosen_uri=$(gio info -a standard::name "$chosen" | sed -n 's/^uri: //p')
              [ -n "$chosen_uri" ] || exit 0

              gsettings set org.gnome.desktop.background picture-uri "$chosen_uri"
              gsettings set org.gnome.desktop.background picture-uri-dark ""

              greeter_dir="/var/lib/lightdm-data/$USER"
              if [ -d "$greeter_dir" ] && [ -w "$greeter_dir" ]; then
                install -m 0644 "$chosen" "$greeter_dir/wallpaper"
                gdbus call --system \
                  --dest org.freedesktop.Accounts \
                  --object-path "/org/freedesktop/Accounts/User$(id -u)" \
                  --method org.freedesktop.DBus.Properties.Set \
                  org.freedesktop.DisplayManager.AccountsService \
                  BackgroundFile "<'$greeter_dir/wallpaper'>" >/dev/null 2>&1 || true
              fi
            '';
          };

          systemd.user.timers.pantheon-wallpaper-rotate = {
            description = "Periodic Pantheon wallpaper rotation timer";
            wantedBy = ["graphical-session.target"];
            partOf = ["graphical-session.target"];
            timerConfig = {
              OnActiveSec = "0s";
              OnUnitActiveSec = "30min";
            };
          };
        };
      })
    ];
  };
}

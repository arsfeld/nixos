# Systemd failure and deploy reports
#
# Every service gets `onFailure = ["email@%n.service"]`. email@ does not mail:
# it notes the failure in /run/unit-failures/<unit> and queues system-report,
# which sends one mail per settled change.
#
# Mail about steady state, not transitions. A deploy's switch-to-configuration
# stops and restarts many units at once, and plenty fail along the way (a
# dependency stopped under them, a restart racing its socket) before its start
# phase brings them back. Boot is the same. So system-report waits until no
# activation runs and boot is over, gives Restart= units a minute to come back,
# and reports only units that are still failed then, all in one mail. During a
# deploy that mail is also the deploy notice: which generation replaced which,
# and every unit failed now. A unit is reported at most once an hour; failures
# in between are counted into its next report.
#
# Example usage:
#   systemdEmailNotify = {
#     toEmail = "admin@example.com";
#     fromEmail = "noreply@example.com";
#   };
{
  flake.modules.nixos.base = {
    key = "modules/base/systemd-email-notify";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        systemctl = "${config.systemd.package}/bin/systemctl";

        # Returns once no activation runs and boot is over (at most 30 min),
        # plus a minute for Restart= units to come back.
        #
        # Never take /run/nixos/switch-to-configuration.lock to detect an
        # activation: switch-to-configuration grabs it non-blocking and aborts
        # if anyone holds it, even briefly.
        waitForSteadyState = pkgs.writeShellScript "wait-for-steady-state" ''
          activating() {
            ${systemctl} is-active --quiet nixos-rebuild-switch-to-configuration.service \
              || ${pkgs.procps}/bin/pgrep -f 'bin/switch-to-configuration' >/dev/null \
              || [ "$(${systemctl} is-system-running 2>/dev/null)" = starting ]
          }
          waited=0
          while activating && [ "$waited" -lt 1800 ]; do
            sleep 5
            waited=$((waited + 5))
          done
          sleep 60
        '';

        systemReport =
          pkgs.writers.writePython3 "system-report" {
            flakeIgnore = ["E501" "W503"];
          }
          (builtins.readFile ./_system-report.py);
      in {
        options = {
          systemd.services = lib.mkOption {
            type = with lib.types;
              attrsOf (
                submodule {
                  config.onFailure = ["email@%n.service"];
                }
              );
          };

          systemdEmailNotify.toEmail = lib.mkOption {
            type = lib.types.str;
            default = config.constellation.email.toEmail;
            description = ''
              Email address to send service failure notifications to.
              Defaults to the constellation email configuration if available.
            '';
          };

          systemdEmailNotify.fromEmail = lib.mkOption {
            type = lib.types.str;
            default = config.constellation.email.fromEmail;
            description = ''
              Email address to use as the sender for service failure notifications.
              Defaults to the constellation email configuration if available.
            '';
          };
        };

        config = {
          systemd.services."email@" = {
            description = "Notes a unit failure for system-report";
            onFailure = lib.mkForce [];
            serviceConfig.Type = "oneshot";
            script = ''
              mkdir -p /run/unit-failures
              echo >> "/run/unit-failures/$1"
              ${systemctl} start --no-block system-report.service
            '';
            scriptArgs = "%i";
          };

          systemd.services.system-report = {
            description = "Mails unit failures and deploys once the system settles";
            onFailure = lib.mkForce [];
            # Queued mid-switch and still waiting when the switch reloads
            # units: a restart would only lose the wait.
            restartIfChanged = false;
            path = [config.systemd.package]; # systemctl, journalctl
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.escapeShellArgs [
                systemReport
                waitForSteadyState
                "${pkgs.send-email-event}/bin/send-email-event"
                config.systemdEmailNotify.fromEmail
                config.systemdEmailNotify.toEmail
              ];
              TimeoutStartSec = "2h";
            };
          };

          # Queue the deploy report from inside the activation, the one step
          # every switch and test runs and dry-activate does not. At that point
          # /run/current-system still names the old generation. Boot runs the
          # activation too, before systemd (or inside the initrd's), where
          # is-system-running is never running/degraded, so boot sends nothing
          # here; boot-mail-alert covers it. Re-activating the same generation
          # sends nothing either.
          system.activationScripts.deployMail = ''
            case "$(${systemctl} is-system-running 2>/dev/null || true)" in
              running | degraded)
                if [ "$(readlink -f /run/current-system || true)" != "$(readlink -f "$systemConfig")" ]; then
                  mkdir -p /run/deploy-mail
                  readlink -f /run/current-system > /run/deploy-mail/from || true
                  ${systemctl} start --no-block system-report.service || true
                fi
                ;;
            esac
          '';
        };
      })
    ];
  };
}

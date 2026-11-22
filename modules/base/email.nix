# Constellation email notification module
#
# This module provides email notification capabilities for system events using
# msmtp as the mail transfer agent. It sends automated alerts for important
# system lifecycle events to keep administrators informed about system status.
#
# Key features:
# - Boot notifications when system starts up
# - Shutdown notifications before system powers off
# - Deploy notifications once a switch settles, listing failed units
# - Weekly heartbeat emails to confirm system is operational
# - SMTP authentication with encrypted password storage
# - Configurable sender and recipient addresses
# - Integration with PurelyMail SMTP service
#
# The module helps monitor system availability and detect unexpected reboots
# or prolonged downtime by sending regular status updates.
{
  flake.modules.nixos.base = {
    key = "modules/base/email";
    imports = [
      ({
        lib,
        pkgs,
        config,
        ...
      }: let
        sendEmailEvent = "${pkgs.send-email-event}/bin/send-email-event --email-from ${config.constellation.email.fromEmail} --email-to ${config.constellation.email.toEmail}";
        systemctl = "${config.systemd.package}/bin/systemctl";

        # A deploy's switch-to-configuration stops and restarts many units at
        # once, and plenty fail along the way (a dependency stopped under them,
        # a restart racing its socket) before its start phase brings them back.
        # Boot is the same. Anything that reports on the system's state waits
        # this out: until no activation runs and boot is over (at most 30 min),
        # then a minute more for Restart= units to come back.
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

        # Sent once a switch has settled: which generation replaced which, and
        # what is failed now. The per-unit failure mails say the same about
        # each unit, but only for units still failed at this point.
        deployMail = pkgs.writeShellScript "deploy-mail" ''
          set -u
          ${waitForSteadyState}
          old=$(cat /run/deploy-mail/from 2>/dev/null || echo unknown)
          new=$(readlink -f /run/current-system)
          failed=$(${systemctl} list-units --state=failed --plain --no-legend --no-pager | ${pkgs.gawk}/bin/awk '{print $1}')
          if [ -n "$failed" ]; then
            event="deployed, $(echo "$failed" | wc -l) unit(s) failed"
          else
            event="deployed"
          fi
          ${sendEmailEvent} "$event" "<pre>From: ''${old#/nix/store/}
          To:   ''${new#/nix/store/}
          NixOS $(cat "$new/nixos-version" 2>/dev/null)

          Failed units:
          ''${failed:-none}</pre>"
        '';
      in {
        options.constellation.email = {
          fromEmail = lib.mkOption {
            type = lib.types.str;
            default = "admin@rosenfeld.one";
            description = ''
              The email address to send notifications from.
              This should be a valid address configured in your SMTP service.
            '';
            example = "noreply@example.com";
          };

          waitForSteadyState = lib.mkOption {
            type = lib.types.path;
            internal = true;
            readOnly = true;
            default = waitForSteadyState;
            description = "Script that returns once no deploy or boot is in progress.";
          };

          toEmail = lib.mkOption {
            type = lib.types.str;
            default = "alex@rosenfeld.one";
            description = ''
              The email address to send notifications to.
              This is where all system alerts will be delivered.
            '';
            example = "admin@example.com";
          };
        };

        config = {
          sops.secrets.smtp_password = {
            mode = "0444";
            sopsFile = config.constellation.sops.commonSopsFile;
          };

          programs.msmtp = {
            enable = true;
            accounts = {
              default = {
                auth = true;
                tls = true;
                from = config.constellation.email.fromEmail;
                host = "smtp.purelymail.com";
                port = 587;
                user = config.constellation.email.toEmail;
                passwordeval = "cat ${config.sops.secrets.smtp_password.path}";
              };
            };
            defaults = {
              aliases = builtins.toFile "aliases" ''
                default: ${config.constellation.email.fromEmail}
                root: ${config.constellation.email.fromEmail}
              '';
            };
          };

          # network-online.target, not nss-lookup.target: the latter only orders
          # after name resolution is *configured*, which does not imply a routable
          # network, so the boot mail raced the interface coming up. send-email-event
          # retries internally, so no queue is needed to ride out a slow start.
          # Both boot and shutdown mails must survive a switch untouched: any
          # change to their units (a new send-email-event, a new address) would
          # otherwise make switch-to-configuration restart them, and a restart
          # sends "is shutting down" from preStop and "just booted" from start.
          systemd.services."boot-mail-alert" = {
            restartIfChanged = false;
            wantedBy = ["multi-user.target"];
            after = ["network-online.target"];
            wants = ["network-online.target"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = "${sendEmailEvent} 'just booted'";
          };
          systemd.services."shutdown-mail-alert" = {
            restartIfChanged = false;
            wantedBy = ["multi-user.target"];
            after = ["network-online.target"];
            wants = ["network-online.target"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = "true";
            # Belt and braces: only a real shutdown or reboot, never a stop
            # by hand or by a switch.
            preStop = ''
              if [ "$(${systemctl} is-system-running || true)" = stopping ]; then
                ${sendEmailEvent} 'is shutting down'
              fi
            '';
          };
          # Queue the deploy mail from inside the activation, the one step
          # every switch and test runs and dry-activate does not. At that point
          # /run/current-system still names the old generation. Boot runs the
          # activation too, before systemd (or inside the initrd's), where
          # is-system-running is never running/degraded, so boot sends nothing
          # here; boot-mail-alert covers it. Re-activating the same generation
          # sends nothing either. The job is queued with --no-block and the
          # service waits for the switch to finish before it looks.
          system.activationScripts.deployMail = ''
            case "$(${systemctl} is-system-running 2>/dev/null || true)" in
              running | degraded)
                if [ "$(readlink -f /run/current-system || true)" != "$(readlink -f "$systemConfig")" ]; then
                  mkdir -p /run/deploy-mail
                  readlink -f /run/current-system > /run/deploy-mail/from || true
                  ${systemctl} start --no-block deploy-mail-alert.service || true
                fi
                ;;
            esac
          '';
          systemd.services."deploy-mail-alert" = {
            # Started mid-switch and still waiting when the switch reloads
            # units: a restart would only lose the wait.
            restartIfChanged = false;
            path = [pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = deployMail;
              TimeoutStartSec = "40min";
            };
          };
          systemd.services."weekly-mail-alert" = {
            serviceConfig.Type = "oneshot";
            script = "${sendEmailEvent} 'is still alive'";
          };
          systemd.timers."weekly-mail-alert" = {
            wantedBy = ["timers.target"];
            partOf = ["weekly-mail-alert.service"];
            timerConfig.OnCalendar = "weekly";
          };
        };
      })
    ];
  };
}

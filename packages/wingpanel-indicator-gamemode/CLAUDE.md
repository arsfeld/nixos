# The GameMode Wingpanel indicator

Design: `docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md`.
Wired in by `modules/constellation/pantheon-gamemode.nix` wherever GameMode and Pantheon
are both on.

- `src/Names.vala` is pure and unit-tested (`tests/TestNames.vala`, run in `checkPhase`);
  put any new naming rule there with a test, not in `Indicator.vala`.
- The log lines in `Indicator.vala` are asserted by `tests/pantheon-gamemode-test.nix`
  (`nix build .#checks.x86_64-linux.pantheon-gamemode-test -L`). Change both together.
- Fake games must be real binaries: nixpkgs' coreutils is multicall, so `gamemoderun sleep`
  registers as `coreutils`.

## Looking at it on raider

    just pantheon::panel-run                       # this checkout's indicator, live
    gamemoderun sleep 120 &
    gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
      --method org.gtk.Actions.Activate open-indicator "[<'gamemode'>]" '{}'
    just pantheon::shot out.png 2240 0 1200 500

Wingpanel's own `open-indicator`/`close-indicator` actions open the popover, so there is no
test hook and no input injection. Everything about `shot` (locked or blanked screens, why
it is the only capture that works) is in `modules/constellation/pantheon-dock/CLAUDE.md`.

The restarted panel docks at the top like the stock one. The popover needs a moment to
render after `open-indicator`: wait 1-2 s before `shot`, and if the first capture shows
only the panel, activate again. Afterwards `pkill -f '(^|/)io\.elementary\.wingpanel$'`
and gala respawns the stock panel.

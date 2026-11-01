# The Tailscale Wingpanel indicator

Design: `docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md`.
Wired in by `modules/desktop/pantheon-tailscale.nix` wherever Tailscale and Pantheon
are both on, together with `--operator=arosenfeld`, without which every write is a 403.

- `src/Model.vala` is pure and unit-tested (`tests/TestModel.vala`, run in `checkPhase`);
  put any new JSON reading or wording there with a test, not in `Indicator.vala`.
- The log lines in `Indicator.vala` are asserted by `tests/pantheon-tailscale-test.nix`
  (`nix build .#checks.x86_64-linux.pantheon-tailscale-test -L`). Change both together.
- Never log at warning or above for tailscaled being down, bad JSON or a refused write;
  the VM test fails on any warning from this log domain.
- The LocalAPI is not a stable public API. After a nixpkgs bump that moves tailscale's
  minor version, re-capture `/localapi/v0/status` and one `watch-ipn-bus?mask=22` line
  and check the members `Model.vala` reads still exist.

## Looking at it on raider

    just pantheon::panel-run tailscale             # this checkout's indicator, live
    until grep -q 'Tailscale: ' /tmp/io.elementary.wingpanel.log; do sleep 0.5; done; sleep 1
    gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
      --method org.gtk.Actions.Activate open-indicator "[<'tailscale'>]" '{}'
    sleep 2; just pantheon::shot out.png 2240 0 1200 500

Everything about `shot` (locked or blanked screens, why it is the only capture that
works) is in `modules/desktop/pantheon-dock/CLAUDE.md`. Afterwards
`pkill -f '(^|/)io\.elementary\.wingpanel$'` and gala respawns the stock panel.

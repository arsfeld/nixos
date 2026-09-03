# Blackbird GNOME Monitor Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Blackbird a GNOME Quick Settings control for the M34WQ's hardware volume and make EasyEffects processing output-specific and correctly owned.

**Architecture:** Add an opt-in GNOME monitor-control module option that wires I2C/DDC, `ddcutil`, the GNOME MonitorControl extension, and its declarative settings together. Enable it only on Blackbird. Move EasyEffects presets and exact device-route autoload mappings into Home Manager's XDG data files, retaining a narrowly scoped root cleanup for legacy root-owned files.

**Tech Stack:** NixOS modules, Home Manager, GNOME Shell 50, dconf, DDC/CI via `ddcutil`, EasyEffects 8, PipeWire, WirePlumber

**Spec:** `docs/superpowers/specs/2026-09-02-blackbird-gnome-monitor-volume-design.md`

## Global Constraints

- Work directly on `master`; do not create a branch or worktree.
- Preserve unrelated and user-owned changes.
- Do not activate or deploy Blackbird without explicit approval.
- Use the pinned `nixpkgs-unstable` input for the GNOME extension because the stable package set does not contain it.
- Never delete the complete `~/.config/easyeffects` tree or its `db` directory.
- Keep the monitor-control option disabled by default so no other host gains I2C access or the extension implicitly.

### Task 1: Add the opt-in GNOME monitor-volume feature

**Files:**

- Create: `tests/blackbird-audio-control-test.nix`
- Modify: `flake-modules/checks.nix`
- Modify: `modules/constellation/desktop.nix`
- Modify: `hosts/blackbird/configuration.nix`

- [ ] **Step 1: Add a failing evaluation check**

Create `tests/blackbird-audio-control-test.nix` with assertions for the enabled and disabled cases:

```nix
{
  self,
  inputs,
  system,
}: let
  lib = inputs.nixpkgs.lib;
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  blackbird = self.nixosConfigurations.blackbird.config;
  raider = self.nixosConfigurations.raider.config;
  packageNamed = name: packages:
    lib.any (package: lib.getName package == name) packages;
  enabledExtensions = config:
    lib.concatMap
    (database: database.settings."org/gnome/shell".enabled-extensions or [])
    config.programs.dconf.profiles.user.databases;
  monitorSettings = lib.findFirst
    (settings: settings != null)
    null
    (map
      (database: database.settings."org/gnome/shell/extensions/monitor-control" or null)
      blackbird.programs.dconf.profiles.user.databases);
in
  assert blackbird.constellation.desktop.gnome.monitorControl.enable;
  assert blackbird.hardware.i2c.enable;
  assert packageNamed "ddcutil" blackbird.environment.systemPackages;
  assert packageNamed "gnome-shell-extension-monitorcontrol-brightness-and-volume"
    blackbird.environment.systemPackages;
  assert builtins.elem "monitor-control@ahmed-shaalan" (enabledExtensions blackbird);
  assert monitorSettings != null;
  assert monitorSettings.show-brightness;
  assert monitorSettings.show-volume;
  assert monitorSettings.unify-volume;
  assert !raider.constellation.desktop.gnome.monitorControl.enable;
  assert !builtins.elem "monitor-control@ahmed-shaalan" (enabledExtensions raider);
    pkgs.runCommand "blackbird-audio-control-test" {} ''
      touch $out
    ''
```

Expose it in `flake-modules/checks.nix`:

```nix
blackbird-audio-control-test = import ../tests/blackbird-audio-control-test.nix {
  inherit self inputs system;
};
```

- [ ] **Step 2: Run the check and confirm it fails for the missing option**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.blackbird-audio-control-test
```

Expected: evaluation fails because `constellation.desktop.gnome.monitorControl.enable` does not exist yet.

- [ ] **Step 3: Define the option and its conditional system configuration**

In the `gnome` option block in `modules/constellation/desktop.nix`, add:

```nix
monitorControl.enable = lib.mkEnableOption "GNOME Quick Settings controls for DDC/CI monitors";
```

Within the GNOME implementation, conditionally configure:

```nix
hardware.i2c.enable = cfg.gnome.monitorControl.enable;
```

Append the extension UUID to the existing enabled-extension list:

```nix
++ lib.optional cfg.gnome.monitorControl.enable "monitor-control@ahmed-shaalan"
```

At the end of the existing dconf `settings` attribute set, replace its closing `};` with this merge. Keep every existing settings entry unchanged:

```nix
} // lib.optionalAttrs cfg.gnome.monitorControl.enable {
  "org/gnome/shell/extensions/monitor-control" = {
    show-brightness = true;
    show-volume = true;
    unify-volume = true;
  };
};
```

Append these packages only when the option is enabled:

```nix
++ lib.optionals cfg.gnome.monitorControl.enable [
  pkgs.ddcutil
  pkgs-unstable.gnomeExtensions.monitorcontrol-brightness-and-volume
]
```

Keep the condition attached to each addition rather than making DDC support global.

- [ ] **Step 4: Enable the feature only on Blackbird**

In `hosts/blackbird/configuration.nix`, inside `constellation.desktop.gnome`, add:

```nix
monitorControl.enable = true;
```

- [ ] **Step 5: Run the focused check**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.blackbird-audio-control-test
```

Expected: the check builds successfully; Blackbird contains the option, I2C support, packages, UUID, and settings, while Raider remains unchanged.

- [ ] **Step 6: Verify the packaged extension metadata**

Run:

```bash
extension_path="$(
  nix build --no-link --print-out-paths --impure --expr '
    let
      flake = builtins.getFlake (toString ./.);
      pkgs = import flake.inputs.nixpkgs-unstable {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
    in pkgs.gnomeExtensions.monitorcontrol-brightness-and-volume
  '
)"
jq '{uuid, "shell-version"}' \
  "$extension_path/share/gnome-shell/extensions/monitor-control@ahmed-shaalan/metadata.json"
```

Expected: the UUID is `monitor-control@ahmed-shaalan` and `shell-version` contains `50`.

- [ ] **Step 7: Commit the module feature**

```bash
git add tests/blackbird-audio-control-test.nix flake-modules/checks.nix modules/constellation/desktop.nix hosts/blackbird/configuration.nix
git commit -m "feat(blackbird): add GNOME monitor volume controls"
```

### Task 2: Migrate EasyEffects presets and device autoloading

**Files:**

- Create: `hosts/blackbird/easyeffects-no-effects-preset.json`
- Modify: `tests/blackbird-audio-control-test.nix`
- Modify: `hosts/blackbird/configuration.nix`

- [ ] **Step 1: Extend the evaluation check with failing EasyEffects assertions**

Add bindings for Blackbird's Home Manager configuration and managed XDG files:

```nix
blackbirdHome = blackbird.home-manager.users.arosenfeld;
easyEffectsFiles = blackbirdHome.xdg.dataFile;
speakerAutoload = builtins.fromJSON
  easyEffectsFiles."easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text;
monitorAutoload = builtins.fromJSON
  easyEffectsFiles."easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text;
```

Assert these exact paths exist:

```nix
assert easyEffectsFiles ? "easyeffects/output/ASUS_G14_2020.json";
assert easyEffectsFiles ? "easyeffects/output/No_Effects.json";
assert easyEffectsFiles ? "easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json";
assert easyEffectsFiles ? "easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json";
assert speakerAutoload.device == "alsa_output.pci-0000_04_00.6.analog-stereo";
assert speakerAutoload."device-description" == "Ryzen HD Audio Controller Analog Stereo";
assert speakerAutoload."device-profile" == "Speakers";
assert speakerAutoload."preset-name" == "ASUS_G14_2020";
assert monitorAutoload.device == "alsa_output.pci-0000_01_00.1.hdmi-stereo";
assert monitorAutoload."device-description" == "TU116 High Definition Audio Controller Digital Stereo (HDMI)";
assert monitorAutoload."device-profile" == "HDMI / DisplayPort";
assert monitorAutoload."preset-name" == "No_Effects";
assert builtins.elem "wireplumber.service"
  blackbird.systemd.user.services.easyeffects.after;
assert !(blackbird.system.activationScripts ? setupEasyEffectsG14);
```

- [ ] **Step 2: Run the check and confirm the new assertions fail**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.blackbird-audio-control-test
```

Expected: evaluation fails because the native EasyEffects data files do not yet exist and the legacy activation script is still present.

- [ ] **Step 3: Add the empty monitor preset**

Create `hosts/blackbird/easyeffects-no-effects-preset.json`:

```json
{
  "output": {
    "blocklist": [],
    "plugins_order": []
  }
}
```

- [ ] **Step 4: Declare EasyEffects presets and autoload files with Home Manager**

In `hosts/blackbird/configuration.nix`, replace the preset-install portion of the root activation script with:

```nix
home-manager.users.arosenfeld.xdg.dataFile = {
  "easyeffects/output/ASUS_G14_2020.json".source =
    ./easyeffects-blackbird-preset.json;
  "easyeffects/output/No_Effects.json".source =
    ./easyeffects-no-effects-preset.json;

  "easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text =
    builtins.toJSON {
      device = "alsa_output.pci-0000_04_00.6.analog-stereo";
      "device-description" = "Ryzen HD Audio Controller Analog Stereo";
      "device-profile" = "Speakers";
      "preset-name" = "ASUS_G14_2020";
    };

  "easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text =
    builtins.toJSON {
      device = "alsa_output.pci-0000_01_00.1.hdmi-stereo";
      "device-description" = "TU116 High Definition Audio Controller Digital Stereo (HDMI)";
      "device-profile" = "HDMI / DisplayPort";
      "preset-name" = "No_Effects";
    };
};
```

These file names and JSON keys match EasyEffects 8's autoload manager. Preserve the existing `~/.config/easyeffects/db/easyeffectsrc`; it contains the user's current application settings.

- [ ] **Step 5: Replace the legacy root write with targeted cleanup**

Retain a small system activation script solely because the old files and directories are root-owned. Remove only the paths previously created by this repository:

```nix
system.activationScripts.easyeffectsLegacyCleanup.text = ''
  rm -f \
    /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json \
    /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json \
    /home/arosenfeld/.config/easyeffects/settings.json

  rmdir --ignore-fail-on-non-empty \
    /home/arosenfeld/.config/easyeffects/autoload/output \
    /home/arosenfeld/.config/easyeffects/autoload \
    /home/arosenfeld/.config/easyeffects/output \
    /home/arosenfeld/.config/easyeffects
'';
```

Do not broaden these paths, recurse, or remove `~/.config/easyeffects/db`.

- [ ] **Step 6: Order EasyEffects after the complete audio session**

Update the NixOS user service so it starts after the graphical session and complete audio session, and wants both audio services:

```nix
after = [
  "graphical-session.target"
  "pipewire.service"
  "wireplumber.service"
];
wants = [
  "pipewire.service"
  "wireplumber.service"
];
```

- [ ] **Step 7: Run the focused check and inspect generated JSON**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.blackbird-audio-control-test
nix eval --raw '.#nixosConfigurations.blackbird.config.home-manager.users.arosenfeld.xdg.dataFile."easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text' | jq .
nix eval --raw '.#nixosConfigurations.blackbird.config.home-manager.users.arosenfeld.xdg.dataFile."easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text' | jq .
```

Expected: the focused check succeeds and the two JSON objects contain the exact observed device names, descriptions, routes, and intended preset names.

- [ ] **Step 8: Commit the EasyEffects migration**

```bash
git add hosts/blackbird/configuration.nix hosts/blackbird/easyeffects-no-effects-preset.json tests/blackbird-audio-control-test.nix
git commit -m "fix(blackbird): migrate EasyEffects speaker presets"
```

### Task 3: Perform full static verification

**Files:**

- Verify all files changed in Tasks 1 and 2

- [ ] **Step 1: Format the repository**

Run:

```bash
nix develop -c just fmt
```

Review the diff and ensure formatting did not alter unrelated user work.

- [ ] **Step 2: Re-run the focused regression check**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.blackbird-audio-control-test
```

Expected: success.

- [ ] **Step 3: Build the complete Blackbird system closure**

Run:

```bash
nix build --no-link .#nixosConfigurations.blackbird.config.system.build.toplevel
```

Expected: the full system closure builds successfully, including the unstable GNOME extension and Home Manager files.

- [ ] **Step 4: Review repository state**

Run:

```bash
git diff --check
git status --short
git log --oneline -2
```

Expected: no whitespace errors; only planned files are changed or committed. If formatting changed planned files after their task commit, commit only those formatting changes with a descriptive message.

### Task 4: Test the live desktop behind explicit approval gates

**Files:** None

- [ ] **Step 1: Stop and request explicit approval for test activation**

Do not run an activation or deployment command as part of the implementation tasks above. Present the successful check and system-build evidence, then ask the user to approve a test activation on Blackbird.

- [ ] **Step 2: After approval, perform a test activation**

Run:

```bash
nix develop -c just test blackbird
```

Log out and back in once so GNOME Shell loads the newly installed extension and updated dconf profile cleanly.

- [ ] **Step 3: Verify DDC and extension runtime state**

Run on Blackbird:

```bash
ddcutil detect
ddcutil getvcp 62
gnome-extensions info monitor-control@ahmed-shaalan
gsettings get org.gnome.shell enabled-extensions
gsettings get org.gnome.shell.extensions.monitor-control show-volume
gsettings get org.gnome.shell.extensions.monitor-control unify-volume
```

Expected: the M34WQ is detected, VCP code `0x62` is readable, the extension is enabled without an error state, and both volume settings are true.

- [ ] **Step 4: Verify behavior from GNOME's UI**

Open GNOME Quick Settings and verify:

1. The M34WQ volume slider is visible.
2. Moving it changes the monitor's audible volume and on-screen volume value.
3. GNOME's normal output volume remains at 100% while unified volume is enabled.
4. Muting and restoring the monitor works without using a terminal.
5. Connecting a headset does not unexpectedly change the monitor's hardware volume.

- [ ] **Step 5: Verify EasyEffects routing and logs**

Switch the default output between the internal speakers and M34WQ. Confirm:

1. Internal speakers load `ASUS_G14_2020`.
2. M34WQ loads `No_Effects`.
3. `wpctl status` and `pw-link -l` show one valid output route without a stale duplicate graph.
4. `journalctl --user -u easyeffects -b` contains no legacy-preset migration permission failures.

Unplug and reconnect the DisplayPort monitor once, then repeat the output switch to verify hotplug recovery.

- [ ] **Step 6: Stop and request explicit approval for permanent deployment**

Only after the live checks pass, ask separately for permission to deploy permanently. After approval, run:

```bash
nix develop -c just deploy blackbird
```

Report the deployed system generation and the final runtime verification result.

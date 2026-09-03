# Blackbird GNOME Monitor Volume Design

## Problem

Blackbird can send audio over DisplayPort to the Gigabyte M34WQ, but the monitor has an independent hardware volume control. BetterDisplay on macOS can leave that control at zero, so Linux may show an active, correctly routed PipeWire stream while the monitor remains silent.

The desired experience is to control that hardware volume from GNOME Quick Settings, without requiring terminal commands. Blackbird's existing EasyEffects setup also needs repair: a system activation script writes an obsolete EasyEffects layout into the user's configuration directory as root, causing migration permission errors and allowing speaker tuning to affect outputs it was not designed for.

## GNOME Monitor Control

Add an opt-in `constellation.desktop.gnome.monitorControl.enable` option. It remains disabled by default and is enabled only for Blackbird.

When enabled, the option will:

- enable NixOS I2C/DDC support;
- install `ddcutil` and the GNOME extension `MonitorControl - Brightness and Volume` from the pinned unstable package set;
- enable the extension UUID `monitor-control@ahmed-shaalan` declaratively;
- show monitor brightness and volume sliders in GNOME Quick Settings; and
- enable the extension's unified-volume behavior, which keeps the PipeWire output at full scale while delegating volume changes to the monitor's DDC/CI volume control.

The extension package currently supports GNOME Shell 45 through 50, including Blackbird's GNOME Shell 50.

## EasyEffects Ownership and Routing

Home Manager will own EasyEffects presets and autoload mappings under the EasyEffects 8 native data directory, `~/.local/share/easyeffects`.

Two output presets will be present:

- `ASUS_G14_2020`, containing the existing internal-speaker processing chain; and
- `No_Effects`, containing an empty output chain for the M34WQ.

Autoload mappings will use the exact PipeWire device names and route descriptions observed on Blackbird:

- `alsa_output.pci-0000_04_00.6.analog-stereo` / `Speakers` loads `ASUS_G14_2020`;
- `alsa_output.pci-0000_01_00.1.hdmi-stereo` / `HDMI / DisplayPort` loads `No_Effects`.

The user EasyEffects service will wait for both PipeWire and WirePlumber. A targeted root activation cleanup will remove only the three obsolete files created by the current repository configuration, then remove their directories only if empty. The EasyEffects settings database and any unrelated user files will be preserved.

## Verification and Deployment

An evaluation check will cover both the enabled Blackbird configuration and a disabled GNOME host, preventing the feature from leaking to other machines. It will also verify the Home Manager EasyEffects files and service ordering.

The Blackbird system closure will be built before any activation. Deployment remains a separate, explicit approval gate. After an approved test activation and GNOME login, runtime verification will cover DDC discovery, Quick Settings volume behavior, EasyEffects output switching, hotplug behavior, and absence of migration errors.

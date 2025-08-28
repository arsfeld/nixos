# Repository Guidelines

## Project Structure & Module Organization
- `flake.nix`/`flake.lock`: Single entrypoint; defines hosts, packages, checks.
- `hosts/<name>/`: Machine configs (`configuration.nix`, optional `disko-config.nix`, `hardware-configuration.nix`).
- `modules/`: Reusable NixOS modules auto‑loaded via Haumea.
- `packages/<pkg>/`: Custom packages (expose as `default`).
- `home/`: Home Manager modules.
- `overlays/`: Nixpkgs overlays.
- `tests/`: NixOS tests (e.g., `router-test.nix`).
- `secrets/`: Agenix‑encrypted `.age` files only.
- `just/` and `justfile`: Task runner recipes.
- `docs/` + `mkdocs.yml`: Documentation site.

## Build, Test, and Development Commands
- `nix develop`: Enter dev shell (just, alejandra, black, mkdocs, etc.).
- `nix fmt` or `just fmt`: Format Nix with alejandra.
- `nix flake check -L`: Run all checks (deploy‑rs checks, NixOS tests).
- `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`: Build a system locally.
- `just deploy <host>` / `just boot <host>`: Deploy via deploy‑rs (boot for kernel/bootloader).
- `just build <host>`: Build and push to cache.
- `just router-test` or `nix build .#checks.x86_64-linux.router-test -L`: Run router integration test.
- Docs: `mkdocs serve -a 0.0.0.0:8000` (from dev shell).

## Coding Style & Naming Conventions
- Nix: Format with alejandra; 2‑space indent; small composable modules; attribute names are kebab‑case.
- Python: `black` formatting; snake_case modules and functions.
- Bash: `#!/usr/bin/env bash` + `set -euo pipefail`; long flags; 2‑space indent.
- Paths: `hosts/<host>`, `modules/<area>/<module>.nix`, `packages/<name>/default.nix`.

## Testing Guidelines
- Prefer NixOS tests in `tests/*.nix` with clear `testScript` subtests.
- Name tests `<area>-test.nix` (e.g., `router-test.nix`).
- Validate locally with `nix flake check -L`; add targeted `checks` when possible.

## Commit & Pull Request Guidelines
- Commit style: Angular + emoji (see README).
  - Example: `✨ feat(router): add NAT-PMP server`.
- PRs: concise description, affected hosts/modules, linked issues, commands run (`nix flake check`, builds), and relevant test output. For docs, include screenshots/links.

## Security & Configuration Tips
- Secrets: never commit plaintext. Edit via `agenix -e secrets/<name>.age`.
- Use `.envrc.local` for machine‑local settings; keep it untracked.
- Review `just install`/`disko` warnings carefully—these can wipe disks.

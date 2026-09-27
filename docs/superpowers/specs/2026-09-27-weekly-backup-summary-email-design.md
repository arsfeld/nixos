# Weekly Fleet Backup Summary Email

Date: 2026-09-27
Status: Proposed

## Problem

The constellation fleet relies on Backrest and rustic for distributed backups across four hosts (`galactica`, `basestar`, `pegasus`, and `raider`), backing up to local storage, REST servers, and OVHcloud Cold Archive.

Currently:
1. **Silent on success:** Routine backup runs fire ntfy notifications only upon failure (`CONDITION_ANY_ERROR`). While ideal for minimizing alert fatigue during the week, there is no positive confirmation that backups are consistently succeeding across all hosts.
2. **Redundant generic heartbeats:** Every host running `constellation.email` sends an independent, generic weekly heartbeat (`is still alive`) via `systemd.timers."weekly-mail-alert"`. On `galactica` (the central storage and backup hub), this heartbeat provides no visibility into the actual health or freshness of the backups.
3. **Multi-client visibility gap:** Backups from `basestar`, `pegasus`, and `raider` all land on `galactica`'s `restic-rest-server`, but `galactica`'s existing `backup-status` script queries the shared repository as a whole without partitioning snapshots by host. A successful backup from `basestar` can mask a stalled or failing backup from `raider` or `pegasus`.

## Goals

1. **Centralized Fleet Digest:** A single weekly email generated and dispatched by `galactica` on Sunday evening (20:00 UTC / 16:00 EDT) after all weekend weekly backups and prune jobs have completed.
2. **Comprehensive Coverage:** Monitors all fleet backup targets:
   - `galactica` local system (`/mnt/storage/backups/restic`)
   - `basestar` system backup (`storage` repo partitioned by `--host basestar`)
   - `pegasus` system backup (`storage` repo partitioned by `--host pegasus`)
   - `raider` laptop system backup (`storage` repo partitioned by `--host raider`)
   - `galactica` offsite copy on pegasus REST server (`rest:http://pegasus.bat-boa.ts.net:8000/`)
   - `galactica` offsite cold archive (`galactica-backup-cold` via `rustic`)
3. **Differentiated Staleness Thresholds:**
   - Daily servers (`galactica` local, `basestar`): stale if older than **48h**.
   - Laptop (`raider`): warning badge if between **72h and 168h (7 days)**, critical if older than **168h**.
   - Weekly targets (`pegasus` client, `galactica` pegasus offsite, OVH Cold Archive): stale if older than **192h (8 days)**.
4. **Rich HTML Email Dashboard:** Mobile- and desktop-friendly email featuring hero status banner, summary tiles, target status table, storage pool and repository footprint metrics, and direct links to the Backrest Web Portal.
5. **Heartbeat Consolidation:** Suppress `galactica`'s generic `weekly-mail-alert.timer` so the operator receives one meaningful weekly backup digest rather than redundant noise.
6. **Resilience & Safe Fallbacks:** Query failures or network timeouts for individual remote targets (e.g. pegasus offline) report as `UNREACHABLE` without aborting the rest of the report. A script crash or persistent SMTP delivery failure triggers an ntfy alert via `OnFailure=backup-notify@backup-summary.service`.
7. **CLI Diagnosability:** Package a `backup-summary` command with `--dry-run` and `--stdout` flags for operator testing.

## Non-Goals

- Replacing Backrest or restic as orchestrators or snapshot engines.
- Triggering or orchestrating backup runs or retries (this is strictly an auditor and reporter).
- Replacing instantaneous ntfy failure alerts for immediate broken backups during the week.

## Architecture

```mermaid
flowchart TD
    subgraph Galactica [galactica (Storage Host)]
        Timer[backup-summary.timer<br/>Sun 20:00 UTC] --> Service[backup-summary.service]
        Service --> Binary[backup-summary CLI]

        subgraph Local Sources
            LocalRepo["/mnt/storage/backups/restic<br/>(galactica local-system)"]
            SharedRepo["/mnt/storage/backups/restic-server<br/>(basestar, pegasus, raider)"]
            Pool["/mnt/storage filesystem"]
            RusticOVH["rustic snapshots<br/>(OVH Cold Archive)"]
        end

        subgraph Remote Sources
            PegasusRest["rest:http://pegasus.bat-boa.ts.net:8000/<br/>(galactica pegasus offsite)"]
        end

        Binary -->|restic snapshots| LocalRepo
        Binary -->|restic snapshots --host| SharedRepo
        Binary -->|statvfs + du| Pool
        Binary -->|rustic snapshots| RusticOVH
        Binary -->|restic snapshots (30s timeout)| PegasusRest

        Binary -->|renders Jinja2| HTML[HTML Email]
        Binary -->|msmtp with retry| SMTP[PurelyMail SMTP]
        SMTP --> Operator[alex@rosenfeld.one]

        Service -.->|OnFailure| Ntfy[backup-notify@<br/>ntfy.arsfeld.one/backups]
    end
```

### 1. NixOS Module (`modules/constellation/backup-summary.nix`)

Declares the options and wires the systemd service and timer:

```nix
options.constellation.backupSummary = {
  enable = mkEnableOption "weekly fleet backup summary email digest";

  schedule = mkOption {
    type = types.str;
    default = "Sun *-*-* 20:00:00 UTC";
    description = "systemd OnCalendar schedule for the weekly summary email.";
  };

  toEmail = mkOption {
    type = types.str;
    default = config.constellation.email.toEmail;
    description = "Recipient email address.";
  };

  fromEmail = mkOption {
    type = types.str;
    default = config.constellation.email.fromEmail;
    description = "Sender email address.";
  };

  backrestPortalUrl = mkOption {
    type = types.str;
    default = "https://backrest.arsfeld.one/";
    description = "Public URL for the Backrest portal.";
  };
};
```

When enabled on `galactica`:
- Installs `pkgs.backup-summary` to `environment.systemPackages`.
- Configures `systemd.services.backup-summary` (oneshot, `RequiresMountsFor = "/mnt/storage"`, `onFailure = ["backup-notify@backup-summary.service"]`).
- Configures `systemd.timers.backup-summary`.
- Sets `systemd.timers."weekly-mail-alert".enable = false;` to eliminate redundant heartbeats on `galactica`.

### 2. Python Reporter Package (`packages/backup-summary/`)

Packaged via `pkgs.writeShellApplication` or `pkgs.python3.pkgs.buildPythonApplication` with runtime dependencies:
- Python 3 with `jinja2`
- `restic`, `rustic`, `msmtp`, `coreutils`, `util-linux`

Directory layout:
- `packages/backup-summary/default.nix`
- `packages/backup-summary/backup_summary.py`
- `packages/backup-summary/summary-email.html.j2`

### 3. Target Query & Staleness Matrix

| Target Name | Query Method | Host / Path Filter | Max Age (Hours) | Warning Range | Classification |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **galactica: local** | `restic -r /mnt/storage/backups/restic snapshots --json` | `hostname: galactica`, `/` | 48 | N/A | Daily server |
| **basestar: system** | `restic -r rest:http://127.0.0.1:8000/ snapshots --json` | `hostname: basestar` | 48 | N/A | Daily server |
| **pegasus: system** | `restic -r rest:http://127.0.0.1:8000/ snapshots --json` | `hostname: pegasus` | 192 | N/A | Weekly server |
| **raider: system** | `restic -r rest:http://127.0.0.1:8000/ snapshots --json` | `hostname: raider` | 168 | 72h - 168h | Laptop |
| **galactica: pegasus**| `timeout 30 restic -r rest:http://pegasus.bat-boa.ts.net:8000/ snapshots --json` | `hostname: galactica` | 192 | Unreachable = Warn | Weekly offsite |
| **galactica: ovh** | `rustic -P ovh snapshots` | profile `ovh` | 192 | N/A | Weekly cold archive |

*Note on shared repo queries:*
Querying `rest:http://127.0.0.1:8000/` once yields the JSON snapshot array for all clients. The collector parses this array in Python and partitions snapshots by `snapshot["hostname"]`. This avoids repeated network calls or index parsing.

### 4. Storage Footprint Calculation

1. **Filesystem Pool (`/mnt/storage`):**
   - Uses `os.statvfs("/mnt/storage")` to compute Total, Used, Free GiB/TiB and percentage used.
2. **Repository Footprint:**
   - Reads disk usage of `/mnt/storage/backups/restic-server` and `/mnt/storage/backups/restic`.
   - Uses `du -sb` with cached or timeout protection.

### 5. Email Templating & Aesthetic

The template `summary-email.html.j2` is structured with table-based markup and inline CSS for email client compatibility:
- **Preheader:** Concise summary (`All 6 backup targets healthy` or `Attention Needed: 1 stale, 1 warning`).
- **Hero Card:**
  - Header: Host name `GALACTICA`, subtitle `WEEKLY FLEET BACKUP DIGEST`.
  - Date and time of audit.
  - Overall status banner (Green for All Healthy, Amber for Warnings, Red for Stale/Errors).
- **Summary Metrics Tiles:**
  - Monitored Targets (e.g. `6`)
  - Healthy Count (Green)
  - Attention Needed (Amber/Red)
  - `/mnt/storage` pool usage percentage with colored bar.
- **Target Status Table:**
  - Columns: Host & Target, Destination, Last Snapshot (date + relative age), Limit, Status Badge.
  - Badges: `[ OK ]` (Green pill), `[ WARN ]` (Amber pill), `[ STALE ]` (Red pill), `[ UNREACHABLE ]` (Gray/Red pill).
- **Storage Breakdown Card:**
  - Pool capacity and repo disk consumption.
- **Action Buttons & CLI Tips:**
  - CTA Button linking to `https://backrest.arsfeld.one/`.
  - Monospace snippet for terminal quick-check (`ssh galactica backup-status`).

### 6. Error Handling & Delivery Retries

- **Target Query Timeout:** Remote queries (e.g. pegasus REST server) are wrapped in a 30s timeout. If pegasus is offline, the target status is recorded as `UNREACHABLE` with error details, and the overall status is downgraded to "Attention Needed", but email generation continues normally.
- **SMTP Retries:** Delivery invokes `msmtp <toEmail>` with stdin piped. If msmtp fails, the script retries up to 8 times with exponential backoff capped at 30 seconds (matching `packages/send-email-event/send-email.py`).
- **Service Failure Alerting:** If the script encounters an unhandled fatal error or msmtp fails after 8 retries, `systemd.services.backup-summary` fails with non-zero exit, triggering `OnFailure=backup-notify@backup-summary.service` to post an alert to `https://ntfy.arsfeld.one/backups`.

## Implementation Details

### Configuration Files Touched

1. **`packages/backup-summary/`**:
   - `default.nix`: Package derivation using `pkgs.writeShellApplication` or `python3.withPackages`.
   - `backup_summary.py`: Collector and sender script.
   - `summary-email.html.j2`: Email HTML template.
2. **`modules/constellation/backup-summary.nix`**:
   - New constellation module declaring `constellation.backupSummary` options, systemd service, timer, and heartbeat suppression.
3. **`modules/constellation/default.nix`**:
   - Register `./backup-summary.nix` in module imports.
4. **`hosts/galactica/backup/default.nix`** (or `hosts/galactica/configuration.nix`):
   - Enable `constellation.backupSummary.enable = true;`.
5. **`docs/architecture/backup.md`**:
   - Document the weekly backup digest service, schedule, and reporting flow.

## Verification Plan

### Automated / Evaluation Checks
1. **Nix Evaluation:**
   ```bash
   nix eval .#nixosConfigurations.galactica.config.system.build.toplevel
   ```
2. **Package Build:**
   ```bash
   nix build .#backup-summary
   ```

### Operational Verification
1. **CLI Dry Run on Galactica:**
   ```bash
   backup-summary --dry-run
   ```
   Verify console output lists all 6 targets with accurate last-snapshot times and correct status classifications.
2. **HTML Output Inspection:**
   ```bash
   backup-summary --stdout > /tmp/backup-summary.html
   ```
   Inspect `/tmp/backup-summary.html` in a browser to confirm table styling, colors, and responsive card rendering.
3. **Live Test Email:**
   ```bash
   backup-summary --send
   ```
   Verify email receipt at `alex@rosenfeld.one` with correct subject and formatting.
4. **Systemd Unit & Timer Check:**
   ```bash
   systemctl list-timers backup-summary.timer
   systemctl status backup-summary.timer
   ```
   Confirm `weekly-mail-alert.timer` is disabled and `backup-summary.timer` is active for Sunday 20:00 UTC.

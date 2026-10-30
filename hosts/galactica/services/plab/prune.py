"""Which finished Vault torrents to take out of Transmission (data kept).

PornoLab is a ratio tracker, so its torrents seed until they reach RATIO or sit IDLE_DAYS
without an upload, and at most MAX_SEEDING of them stay. Every other tracker earns
nothing by seeding, so those go as soon as they finish. Nothing outside the Vault dir,
and nothing still downloading, is ever chosen.

Design: docs/superpowers/specs/2026-10-30-vault-seed-prune-design.md
"""
from urllib.parse import urlsplit

RATIO = 2.0
IDLE_DAYS = 7
MAX_SEEDING = 50


def _is_lab(torrent):
    hosts = (urlsplit(tr.get("announce", "")).hostname or "" for tr in torrent.get("trackers", []))
    return any("plab" in h or "pornolab" in h for h in hosts)


def _idle_days(torrent, now):
    # Counted from completion too, so a torrent that just finished gets the full window.
    return (now - max(torrent["doneDate"], torrent["activityDate"])) / 86400


def decide(torrents, now, vault_dir):
    """Return (id, name, reason) for each torrent to remove."""
    vault_dir = vault_dir.rstrip("/")
    finished = [t for t in torrents
                if t["percentDone"] >= 1
                and (t["downloadDir"].rstrip("/") == vault_dir or t["downloadDir"].startswith(vault_dir + "/"))]
    out, seeding = [], []
    for t in finished:
        idle = _idle_days(t, now)
        if not _is_lab(t):
            out.append((t["id"], t["name"], "complete, not PornoLab"))
        elif t["uploadRatio"] >= RATIO:
            out.append((t["id"], t["name"], f"ratio {t['uploadRatio']:.2f}"))
        elif idle >= IDLE_DAYS:
            out.append((t["id"], t["name"], f"idle {idle:.1f}d, ratio {t['uploadRatio']:.2f}"))
        else:
            seeding.append((idle, t))
    seeding.sort(key=lambda pair: pair[0], reverse=True)  # longest idle first
    for idle, t in seeding[:max(0, len(seeding) - MAX_SEEDING)]:
        out.append((t["id"], t["name"], f"over {MAX_SEEDING} seeding, idle {idle:.1f}d, ratio {t['uploadRatio']:.2f}"))
    return out

#!/usr/bin/env python3
"""Stage recent Immich assets into a flat directory for Syncthing → Pixel → Google Photos.

The staging directory is the only state. Every staged filename is a pure function of
the asset row it came from, so a run reconciles by comparing the filenames the query
wants against the filenames already on disk — there is no manifest to drift out of
sync with reality.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


class Abort(Exception):
    """Stop the run before anything in the staging directory is touched."""


@dataclass(frozen=True)
class Config:
    staging: Path
    tmp: Path
    lock: Path
    owner_id: str
    window_days: int
    shrink_guard_percent: int
    db_name: str
    db_user: str
    db_socket: str

    @classmethod
    def from_env(cls) -> "Config":
        def need(name: str) -> str:
            value = os.environ.get(name)
            if not value:
                sys.exit(f"{name} is not set")
            return value

        return cls(
            staging=Path(need("IPS_STAGING_DIR")),
            tmp=Path(need("IPS_TMP_DIR")),
            lock=Path(need("IPS_LOCK_FILE")),
            owner_id=need("IPS_OWNER_ID"),
            window_days=int(need("IPS_WINDOW_DAYS")),
            shrink_guard_percent=int(need("IPS_SHRINK_GUARD_PERCENT")),
            db_name=need("IPS_DB_NAME"),
            db_user=need("IPS_DB_USER"),
            db_socket=need("IPS_DB_SOCKET"),
        )


def log(message: str) -> None:
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {message}", flush=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage recent Immich assets for the Pixel.")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--force", action="store_true", help="proceed past the shrink guard")
    parser.parse_args(argv)
    log("not implemented yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""User-level state/cache locations (the install directory is never written to)."""
from __future__ import annotations

import os
from pathlib import Path


def _xdg(var: str, fallback: str) -> Path:
    return Path(os.environ.get(var) or Path.home() / fallback)


def state_dir() -> Path:
    """Instance state file and serial transcripts (contain instance IDs and IPs)."""
    override = os.environ.get("ALPINE_FLEET_STATE_DIR")
    return Path(override) if override else _xdg("XDG_STATE_HOME", ".local/state") / "alpine-fleet"


def kexec_cache() -> Path:
    """Host-side cache of kexec binaries built for the target's stock OS."""
    override = os.environ.get("KEXEC_CACHE")
    return Path(override) if override else _xdg("XDG_CACHE_HOME", ".cache") / "alpine-fleet" / "kexec"

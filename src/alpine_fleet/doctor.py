"""`alpine-fleet doctor`: report missing host tools and print (or run) the install command.

pip cannot install system packages, so this never runs at install time and only
runs a package-manager command after an explicit confirmation.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

# (tools that must exist, {package manager: package that provides them})
SYSTEM_GROUPS = [
    (["ssh", "scp", "ssh-keygen"], {
        "pacman": "openssh", "apt": "openssh-client", "dnf": "openssh-clients",
        "zypper": "openssh-clients", "apk": "openssh-client", "brew": "openssh"}),
    (["jq"], {p: "jq" for p in ("pacman", "apt", "dnf", "zypper", "apk", "brew")}),
]

INSTALL = {
    "pacman": ["pacman", "-S", "--needed"],
    "apt": ["apt", "install"],
    "dnf": ["dnf", "install"],
    "zypper": ["zypper", "install"],
    "apk": ["apk", "add"],
    "brew": ["brew", "install"],
}


def detect_pm() -> str | None:
    return next((pm for pm in INSTALL if shutil.which(pm)), None)


def bash_major() -> int:
    bash = shutil.which("bash")
    if not bash:
        return 0
    try:
        out = subprocess.check_output([bash, "-c", "echo ${BASH_VERSINFO[0]}"], text=True)
        return int(out.strip())
    except (subprocess.SubprocessError, ValueError, OSError):
        return 0


def find_oci() -> str | None:
    if os.environ.get("OCI_BIN"):
        return os.environ["OCI_BIN"]
    beside_python = Path(sys.executable).parent / "oci"
    return str(beside_python) if beside_python.exists() else shutil.which("oci")


def oci_config_path() -> Path:
    return Path(os.environ.get("OCI_CONFIG_FILE", "~/.oci/config")).expanduser()


def check() -> tuple[list[tuple[str, str, str]], list[str]]:
    """Return (rows, packages_to_install). Row = (status, label, hint); status is
    ok / MISSING (blocks a run) / optional."""
    rows: list[tuple[str, str, str]] = []
    pm = detect_pm()
    pkgs: list[str] = []

    for tools, by_pm in SYSTEM_GROUPS:
        missing = [t for t in tools if not shutil.which(t)]
        label = "/".join(tools)
        if not missing:
            rows.append(("ok", label, ""))
        else:
            pkg = by_pm.get(pm or "")
            rows.append(("MISSING", label, f"install package '{pkg}'" if pkg else "install with your package manager"))
            if pkg and pkg not in pkgs:
                pkgs.append(pkg)

    major = bash_major()
    if major >= 4:
        rows.append(("ok", "bash >= 4", ""))
    else:
        hint = "macOS ships bash 3.2; run: brew install bash" if sys.platform == "darwin" else "install bash 4 or newer"
        rows.append(("MISSING", "bash >= 4", hint))

    if find_oci():
        rows.append(("ok", "oci CLI", ""))
    else:
        rows.append(("MISSING", "oci CLI", "pipx install 'alpine-fleet[oci]'  (or: pip install oci-cli)"))

    if oci_config_path().exists():
        rows.append(("ok", "OCI config", str(oci_config_path())))
    else:
        rows.append(("MISSING", "OCI config", "run: oci setup config"))

    if shutil.which("podman") or shutil.which("docker"):
        rows.append(("ok", "podman/docker", ""))
    else:
        rows.append(("optional", "podman/docker", "only needed for `alpine-fleet cache` (faster runs)"))

    return rows, pkgs


def blocking() -> list[str]:
    rows, _ = check()
    return [label for status, label, _ in rows if status == "MISSING"]


def run(fix: bool = False) -> int:
    rows, pkgs = check()
    for status, label, hint in rows:
        mark = {"ok": "ok      ", "MISSING": "MISSING ", "optional": "optional"}[status]
        print(f"  [{mark}] {label:<16} {hint}")

    pm = detect_pm()
    if pkgs and pm:
        cmd = list(INSTALL[pm]) + pkgs
        if pm != "brew" and os.geteuid() != 0:
            cmd = ["sudo"] + cmd
        print("\nInstall the missing system packages with:\n  " + " ".join(cmd))
        if fix:
            if input("Run it now? [y/N] ").strip().lower() == "y":
                subprocess.call(cmd)
                return 0 if not blocking() else 1
    elif pkgs:
        print("\nNo known package manager found; install: " + ", ".join(pkgs))

    return 1 if blocking() else 0
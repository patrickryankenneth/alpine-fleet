"""alpine-fleet command line interface."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from . import __version__, doctor, paths

PKG = Path(__file__).resolve().parent
SCRIPTS = PKG / "scripts"
ANSWERFILE = PKG / "answerfiles" / "oci-e2-micro.answerfile"

WARNING = """\
WARNING: this replaces the target instance's operating system with Alpine Linux
and erases its boot disk (/dev/sda). Use it only on disposable or recoverable
instances. Root ends up key-only (no password): if you lose your private key,
rebuild the instance."""

EPILOG = WARNING + """

commands:
  doctor     check host tools (ssh, jq, oci, bash>=4) and print install commands
  discover   show E2.1.Micro / A1.Flex headroom per availability domain
  up         launch an E2.1.Micro if needed and convert it to Alpine
  convert    convert an existing instance:  convert <user@ip> <instance-ocid>
  down       terminate the instance recorded in the state file
  cache      build the Oracle Linux 7 kexec cache (faster runs; needs podman/docker)

Extra flags for discover/down/cache are passed to the underlying script
(e.g. `alpine-fleet down --yes`, `alpine-fleet cache --force`)."""


def _env() -> dict[str, str]:
    env = dict(os.environ)
    if not env.get("OCI_BIN"):
        found = doctor.find_oci()
        if found:
            env["OCI_BIN"] = found
    env.setdefault("ALPINE_FLEET_STATE_DIR", str(paths.state_dir()))
    env.setdefault("KEXEC_CACHE", str(paths.kexec_cache()))
    return env


def _bash(script: str, extra: list[str]) -> int:
    # Always via `bash`: wheels and copies can lose exec bits.
    return subprocess.call(["bash", str(SCRIPTS / script), *extra], env=_env())


def _confirm(expect: str | None, yes: bool) -> bool:
    print(WARNING, file=sys.stderr)
    if yes:
        return True
    if not sys.stdin.isatty():
        print("Refusing to continue without --yes (stdin is not a terminal).", file=sys.stderr)
        return False
    if expect:
        return input(f"\nType the target's address ({expect}) to continue: ").strip() == expect
    return input("\nContinue? [y/N] ").strip().lower() == "y"


def _orchestrate(args: argparse.Namespace, target: str | None = None, ocid: str | None = None) -> int:
    missing = doctor.blocking()
    if missing:
        print("Missing requirements: " + ", ".join(missing) + "\nRun: alpine-fleet doctor", file=sys.stderr)
        return 2
    expect = target.split("@", 1)[-1] if target else None
    if not _confirm(expect, args.yes):
        print("Aborted.", file=sys.stderr)
        return 1
    state = paths.state_dir()
    cmd = [sys.executable, str(SCRIPTS / "orchestrate.py"),
           "--script-dir", str(SCRIPTS),
           "--answerfile", args.answerfile,
           "--state-file", str(state / "current-instance.json"),
           "--serial-log", str(state / "serial.log"),
           "--alpine-version", args.alpine_version,
           "--ssh-pubkey", args.ssh_pubkey,
           "--provider", args.provider]
    if args.console_key:
        cmd += ["--key", args.console_key]
    if args.debug:
        cmd.append("--debug")
    if getattr(args, "no_launch", False):
        cmd.append("--no-launch")
    if target:
        cmd += [target, ocid]
    return subprocess.call(cmd, env=_env())


def _add_run_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument("--yes", "-y", action="store_true", help="skip the destructive-action confirmation")
    p.add_argument("--debug", "-v", action="store_true", help="echo the raw serial console and bootstrap output")
    p.add_argument("--alpine-version", default="v3.24", help="Alpine release branch (default: %(default)s)")
    p.add_argument("--ssh-pubkey", default=str(Path.home() / ".ssh" / "id_ed25519.pub"),
                   help="public key installed for root (default: %(default)s)")
    p.add_argument("--console-key", default=None, help="RSA key for the OCI serial console (default: ~/.ssh/oci-console-rsa)")
    p.add_argument("--answerfile", default=str(ANSWERFILE), help="setup-alpine answerfile (default: the bundled OCI one)")
    p.add_argument("--provider", choices=["oci", "gcp"], default="oci", help="cloud provider (default: %(default)s)")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="alpine-fleet",
        description="Turn a disposable OCI micro VM into a lightweight, hardened Alpine machine.",
        epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"alpine-fleet {__version__}")
    sub = ap.add_subparsers(dest="cmd", metavar="<command>")

    d = sub.add_parser("doctor", help="check host requirements")
    d.add_argument("--fix", action="store_true", help="offer to run the install command")

    sub.add_parser("discover", help="show free-tier capacity per availability domain", add_help=False)

    up = sub.add_parser("up", help="launch (if needed) and convert to Alpine")
    _add_run_flags(up)
    up.add_argument("--no-launch", action="store_true", help="never launch; use the recorded instance")

    cv = sub.add_parser("convert", help="convert an existing instance")
    cv.add_argument("target", metavar="USER@IP", help="stock-OS login, e.g. opc@203.0.113.7")
    cv.add_argument("instance_ocid", metavar="INSTANCE_OCID")
    _add_run_flags(cv)

    sub.add_parser("down", help="terminate the recorded instance", add_help=False)
    sub.add_parser("cache", help="build the kexec cache", add_help=False)
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_parser()
    args, extra = ap.parse_known_args(argv)
    if args.cmd is None:
        ap.print_help()
        return 0
    if args.cmd in ("doctor", "up", "convert") and extra:
        ap.error("unrecognized arguments: " + " ".join(extra))

    if args.cmd == "doctor":
        return doctor.run(fix=args.fix)
    if args.cmd == "discover":
        return _bash("discover-capacity.sh", extra)
    if args.cmd == "down":
        return _bash("teardown-e2.sh", extra)
    if args.cmd == "cache":
        return _bash("prepare-kexec-cache.sh", extra)
    if args.cmd == "up":
        return _orchestrate(args)
    if args.cmd == "convert":
        return _orchestrate(args, args.target, args.instance_ocid)
    return 1

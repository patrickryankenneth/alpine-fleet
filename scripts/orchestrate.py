#!/usr/bin/env python3
"""
orchestrate.py — single-process, resumable controller for the kexec jump.

Every run detects where the box is and resumes from there:
  prejump    opc@ SSH works            -> stage, kexec, serial login, push key
  unknown    nothing answers           -> serial login, push key, re-detect
  ram        root SSH, / is tmpfs      -> install if needed, reboot
  installed  root SSH, / on /dev/sda*  -> verify + harden (lock root)
"""
import argparse
import base64
import re
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    import pexpect
except ImportError:
    sys.exit("FATAL: pexpect required — run: pip install pexpect")

# Alpine's ash prompt is "<hostname>:<cwd># ", e.g. "localhost:~# ". A bare
# "#" is too loose to expect() safely — OCI's own console banner contains a
# doc URL with a "#fragment" in it, which pexpect will happily match before
# the real prompt ever appears. "~#" is specific enough to avoid that while
# still surviving a hostname change (e.g. after setup-alpine sets one).
PROMPT = "~#"

SSH_BASE = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR"]


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]")
SERIAL_LOG = None

_T0 = time.time()
_MARKS = []          # (label, monotonic seconds since start)


def mark(label):
    """Record the end of a phase. A per-phase summary is printed at the end so
    you can see where the wall-clock time actually goes."""
    _MARKS.append((label, time.time() - _T0))


def print_timing():
    print("\n[orchestrate] phase timing:")
    prev = 0.0
    for label, t in _MARKS:
        print(f"  {t - prev:6.0f}s  {label}")
        prev = t
    print(f"  {prev:6.0f}s  total")


class SerialLog:
    """pexpect logfile_read target. Always writes an escape-stripped copy of the
    serial stream to a file; echoes it to stdout only with --debug. Keeping raw
    output off the user's terminal is what stops Alpine's cursor-position
    queries (ESC[6n) from being answered by the terminal and leaking replies
    (;14R;1R...) into the shell prompt afterward."""

    def __init__(self, path, echo):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = str(path)
        self.echo = echo
        self.f = open(self.path, "w", encoding="utf-8")

    def write(self, s):
        clean = ANSI_RE.sub("", s).replace("\r", "")
        self.f.write(clean)
        self.f.flush()
        if self.echo:
            sys.stdout.write(clean)
            sys.stdout.flush()

    def flush(self):
        self.f.flush()

    def tail(self, n=40):
        try:
            return "\n".join(Path(self.path).read_text(errors="replace").splitlines()[-n:])
        except OSError:
            return ""


def load_state(state_file: Path) -> dict:
    if not state_file.exists():
        sys.exit(
            f"FATAL: no ssh_target/instance_ocid given and no state file at {state_file}.\n"
            f"Either pass both explicitly, or run launch-e2.sh first (it writes this file)."
        )
    try:
        return json.loads(state_file.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"FATAL: {state_file} is not valid JSON: {e}")




def find_oci():
    found = os.environ.get("OCI_BIN") or shutil.which("oci")
    if not found:
        sys.exit("FATAL: oci CLI not found on PATH (set OCI_BIN to override).")
    return found


def instance_running(instance_id):
    p = subprocess.run(
        [find_oci(), "compute", "instance", "get", "--instance-id", instance_id,
         "--query", 'data."lifecycle-state"', "--raw-output"],
        capture_output=True, text=True)
    return p.returncode == 0 and p.stdout.strip() == "RUNNING"


def ensure_instance(state_file: Path, script_dir: str) -> dict:
    """Return the state dict of a RUNNING instance, launching one via
    launch-e2.sh if the state file is missing or points at a dead instance."""
    if state_file.exists():
        try:
            st = json.loads(state_file.read_text())
        except json.JSONDecodeError:
            st = {}
        if st.get("instance_id") and instance_running(st["instance_id"]):
            return st
        stale = state_file.with_name(state_file.name + ".stale")
        print(f"[orchestrate] state file points at a non-RUNNING instance — moving to {stale.name}")
        state_file.rename(stale)
    print("[orchestrate] no live instance — launching one via launch-e2.sh "
          "(retries until capacity appears; Ctrl-C to abort)...")
    rc = subprocess.run([f"{script_dir}/launch-e2.sh"]).returncode
    if rc != 0:
        sys.exit(f"FATAL: launch-e2.sh failed (exit {rc}).")
    if not state_file.exists():
        sys.exit("FATAL: launch-e2.sh exited 0 but wrote no state file — it most likely "
                 "hit 'already at cap' (2/2 E2 RUNNING). Terminate one or pass "
                 "ssh_target and instance_ocid explicitly.")
    return json.loads(state_file.read_text())


def get_console_connection_string(instance_ocid: str, key_path: str, script_dir: str) -> str:
    result = subprocess.run(
        [f"{script_dir}/console-connect.sh", "--instance-id", instance_ocid, "--key", key_path],
        capture_output=True, text=True, check=True,
    )
    lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
    if not lines:
        sys.exit("FATAL: console-connect.sh produced no connection string on stdout")
    return lines[-1]


def push_file_over_serial(console, local_path, remote_path, chunk_size=1000):
    """Generic chunked-base64 push — used for both the answerfile and
    the SSH public key."""
    data = Path(local_path).read_bytes()
    b64 = base64.b64encode(data).decode()
    console.sendline(f"rm -f {remote_path}.b64")
    console.expect(PROMPT, timeout=10)
    for i in range(0, len(b64), chunk_size):
        console.sendline(f"echo -n '{b64[i:i+chunk_size]}' >> {remote_path}.b64")
        console.expect(PROMPT, timeout=10)
    console.sendline(f"base64 -d {remote_path}.b64 > {remote_path} && rm {remote_path}.b64")
    console.expect(PROMPT, timeout=10)
    console.sendline(f"wc -c {remote_path}")
    console.expect(f"{len(data)} {re.escape(remote_path)}", timeout=10)
    console.expect(PROMPT, timeout=10)


def push_authorized_key(console, pubkey_path):
    console.sendline("mkdir -p /root/.ssh && chmod 700 /root/.ssh")
    console.expect(PROMPT, timeout=10)
    push_file_over_serial(console, pubkey_path, "/root/.ssh/authorized_keys")
    console.sendline("chmod 600 /root/.ssh/authorized_keys")
    console.expect(PROMPT, timeout=10)


def push_answerfile_over_serial(console, answerfile_path, remote_path="/root/answers", chunk_size=1000):
    push_file_over_serial(console, answerfile_path, remote_path, chunk_size)


def login_to_alpine(console, attempts=6):
    """Ctrl-C, never Enter: Enter would answer whatever prompt a stale
    setup-alpine is parked at (default at the erase prompt is 'n')."""
    for _ in range(attempts):
        console.sendcontrol("c")
        idx = console.expect(["login:", PROMPT, pexpect.TIMEOUT], timeout=5)
        if idx == 0:
            console.sendline("root")
            console.expect(PROMPT, timeout=15)
            break
        if idx == 1:
            break
    else:
        sys.exit(f"FATAL: no login/shell prompt after {attempts} Ctrl-C nudges.")

    # Sync: the typed line contains __SYNC''_OK__, the output contains
    # __SYNC_OK__, so only real command output matches (not echo/backlog).
    for _ in range(5):
        console.sendline("echo __SYNC''_OK__")
        if console.expect(["__SYNC_OK__", pexpect.TIMEOUT], timeout=5) == 0:
            console.expect(PROMPT, timeout=5)
            return
    sys.exit("FATAL: shell never echoed sync marker — console not in a clean shell.")


def serial_run(console, cmd, timeout=60):
    """Run cmd on the serial shell and return its exit code. Syncs on a marker
    that only real output can produce: the typed line contains __RC''_$?__,
    the output contains __RC_<n>__, so the echo can't satisfy the match."""
    console.sendline(f"{cmd}; echo __RC''_$?__")
    console.expect(r"__RC_(\d+)__", timeout=timeout)
    rc = int(console.match.group(1))
    console.expect(PROMPT, timeout=10)
    return rc


def ensure_sshd(console):
    """The netboot live env boots with NO sshd running (setup-alpine is what
    normally installs/starts it), so a key pushed over serial is unreachable
    until sshd is up. Output is shown live via console.logfile."""
    print("\n[orchestrate] ensuring network + sshd on the live env...")
    serial_run(console, "ip -4 addr show; ip -4 route")
    if serial_run(console, "ip -4 addr show | grep 'inet ' | grep -qv '127.0.0.1'") != 0:
        print("[orchestrate] no non-loopback IPv4 — trying DHCP on eth0")
        serial_run(console, "udhcpc -i eth0 -n -q", timeout=30)
    if serial_run(console, "command -v sshd >/dev/null || apk add --quiet openssh", timeout=180) != 0:
        sys.exit("FATAL: could not install openssh on the live env — see serial output above "
                 "(network/apk repo problem?).")
    if serial_run(console, "rc-service sshd start || rc-service sshd restart", timeout=30) != 0:
        sys.exit("FATAL: sshd would not start on the live env — see serial output above.")
    serial_run(console, "rc-service sshd status; netstat -ltn | grep ':22 '")


def ssh_run(target, cmd, timeout=30):
    try:
        p = subprocess.run(SSH_BASE + [target, cmd], capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 255, ""
    return p.returncode, p.stdout


PROBE = "__PROBE_OK__"


def detect_state(ip, ssh_target):
    """OCI's stock images install a forced command on root's authorized_keys
    ("Please login as the user opc...") that swallows whatever command we send
    and can exit 0 without running it. So a zero exit code proves nothing: a
    state only counts if our own marker comes back in the output."""
    rc, out = ssh_run(f"root@{ip}",
                      f"echo {PROBE}; test -f /etc/alpine-release && echo __ALPINE__; mount | grep ' / '")
    if rc == 0 and PROBE in out and "__ALPINE__" in out:
        return "installed" if "/dev/sda" in out else "ram"
    rc, out = ssh_run(ssh_target, f"echo {PROBE}")
    return "prejump" if rc == 0 and PROBE in out else "unknown"


def wait_for_state(ip, ssh_target, secs, want=None):
    """Poll until state != unknown (or == want). Returns last state seen."""
    deadline = time.time() + secs
    state = detect_state(ip, ssh_target)
    while time.time() < deadline and (state == "unknown" if want is None else state != want):
        time.sleep(5)
        state = detect_state(ip, ssh_target)
    return state


def install_complete(ip):
    """RAM env only: does /dev/sda3 hold a finished Alpine install?"""
    rc, _ = ssh_run(
        f"root@{ip}",
        "mkdir -p /mnt/chk && mount -o ro /dev/sda3 /mnt/chk 2>/dev/null; "
        "test -f /mnt/chk/etc/alpine-release; rc=$?; umount /mnt/chk 2>/dev/null; exit $rc")
    return rc == 0


HARDEN = r"""set -e
echo "--- verify"
cat /etc/alpine-release; uname -r
mount | grep ' / '
free -m
awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "used: %d MB of %d MB, available: %d MB\n",(t-a)/1024,t/1024,a/1024}' /proc/meminfo
echo "--- harden"
cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-harden
cp -p /etc/shadow /etc/shadow.pre-harden
# sshd is first-match-wins, so remove every existing (or commented) copy of the
# directives we care about, then append ours. Nothing earlier can override them.
for k in PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication; do
  sed -i "/^[#[:space:]]*$k[[:space:]]/d" /etc/ssh/sshd_config
done
printf '%s\n' 'PermitRootLogin prohibit-password' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config
/usr/sbin/sshd -t
# NOT `passwd -l root`: BusyBox writes a '!'-prefixed hash, and Alpine's sshd
# (built without PAM) treats that as a LOCKED account and refuses even pubkey
# logins. '*' can never match a password but still permits key auth.
sed -i 's/^root:[^:]*:/root:*:/' /etc/shadow
echo "shadow root field now: $(grep '^root:' /etc/shadow | cut -d: -f2)"
rc-service sshd restart
"""

# Run on the box if a FRESH key login fails after hardening: undo the lock and
# dump sshd's own reason for the refusal (BusyBox syslog -> /var/log/messages).
ROLLBACK_AND_DIAG = r"""cp -p /etc/shadow.pre-harden /etc/shadow
cp -p /etc/ssh/sshd_config.pre-harden /etc/ssh/sshd_config
rc-service sshd restart
echo "--- sshd log (why the fresh login was refused)"
grep sshd /var/log/messages | tail -n 25
echo "--- sshd_config (effective auth settings)"
/usr/sbin/sshd -T 2>/dev/null | grep -E 'permitrootlogin|pubkeyauth|passwordauth|usepam|authorizedkeysfile'
echo "--- authorized_keys"
ls -l /root/.ssh/authorized_keys; cut -c1-60 /root/.ssh/authorized_keys
echo "--- shadow root field (restored)"
grep '^root:' /etc/shadow | cut -c1-8
exit
"""

# Executed over a brand-new key-only connection AFTER hardening. Getting output
# back proves key login works; the rest reports what sshd is actually enforcing.
FRESH_CHECK = (
    "echo __FRESH_OK__; "
    "printf 'root_shadow=%s\\n' \"$(grep '^root:' /etc/shadow | cut -d: -f2 | cut -c1)\"; "
    "/usr/sbin/sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '; true"
)

MEM_CMD = (r"""awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d %d %d\n",(t-a)/1024,t/1024,a/1024}' /proc/meminfo; """
           r"""free -m; grep -o 'crashkernel=[^ ]*' /proc/cmdline || echo 'crashkernel=(not set)'""")


def read_ram(target):
    """((used_mb, total_mb, available_mb), raw_text) or (None, ""). used =
    MemTotal-MemAvailable, computed identically on both OSes. MemTotal is what
    each *kernel* can see, so totals differ between OSes; available is the
    fair number to compare (what a new workload can actually get)."""
    rc, out = ssh_run(target, MEM_CMD, timeout=20)
    m = re.search(r"^(\d+) (\d+) (\d+)$", out or "", re.M) if rc == 0 else None
    if not m:
        return None, ""
    raw = out[m.end():].strip()
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))), raw


def fresh_key_login(ip, tries=8, delay=5):
    """Brand-new connection (no multiplexing, key only), retried in case sshd
    is still coming up. Returns (ok, attempt, stdout, last_stderr)."""
    err = ""
    for n in range(1, tries + 1):
        p = subprocess.run(SSH_BASE + ["-o", "ControlPath=none", "-o", "ControlMaster=no",
                                       "-o", "PreferredAuthentications=publickey",
                                       f"root@{ip}", FRESH_CHECK],
                           capture_output=True, text=True, timeout=30)
        if p.returncode == 0 and "__FRESH_OK__" in p.stdout:
            return True, n, p.stdout, ""
        err = p.stderr
        if n < tries:
            time.sleep(delay)
    return False, tries, "", err


def main():
    default_script_dir = Path(__file__).resolve().parent
    default_state_file = default_script_dir.parent / "state" / "current-instance.json"
    default_answerfile = default_script_dir.parent / "answerfiles" / "oci-e2-micro.answerfile"

    ap = argparse.ArgumentParser()
    ap.add_argument("ssh_target", nargs="?", default=None,
                     help="<user>@<instance-ip>. Omit to read from --state-file.")
    ap.add_argument("instance_ocid", nargs="?", default=None,
                     help="OCID of target instance. Omit to read from --state-file.")
    ap.add_argument("--state-file", default=str(default_state_file),
                     help=f"JSON state file (default: {default_state_file})")
    ap.add_argument("--key", default=str(Path.home() / ".ssh" / "oci-console-rsa"))
    ap.add_argument("--script-dir", default=str(default_script_dir))
    ap.add_argument("--answerfile", default=str(default_answerfile))
    ap.add_argument("--alpine-version", default="v3.24")
    ap.add_argument("--debug", "-v", action="store_true",
                     help="Echo the raw serial console and bootstrap.sh output live.")
    ap.add_argument("--serial-log", default=str(default_script_dir.parent / "state" / "serial.log"),
                     help="Where the cleaned serial transcript is written (default: state/serial.log).")
    ap.add_argument("--no-launch", action="store_true",
                     help="Never launch an instance; fail if the state file has none.")
    ap.add_argument("--ssh-pubkey", default=str(Path.home() / ".ssh" / "id_ed25519.pub"),
                     help="Public key installed into /root/.ssh/authorized_keys on the "
                          "live RAM environment BEFORE setup-disk runs, so it carries "
                          "over onto the installed disk (setup-disk -m sys copies the "
                          "running root filesystem, including /root/.ssh). Root's "
                          "password is still set interactively by setup-alpine (Alpine's "
                          "answerfile format has no way to skip that step) — this script "
                          "auto-answers it with a random throwaway, then locks password "
                          "login entirely afterward so only this key can get in.")
    args = ap.parse_args()

    if args.ssh_target is None or args.instance_ocid is None:
        if args.no_launch:
            st = load_state(Path(args.state_file))
        else:
            st = ensure_instance(Path(args.state_file), args.script_dir)
            mark("instance launched + public IP")
        if args.instance_ocid is None:
            args.instance_ocid = st.get("instance_id")
        if args.ssh_target is None:
            ip = st.get("public_ip")
            user = st.get("ssh_user", "opc")
            if not ip:
                sys.exit(f"FATAL: {args.state_file} has no public_ip field.")
            args.ssh_target = f"{user}@{ip}"
        if not args.instance_ocid:
            sys.exit(f"FATAL: {args.state_file} has no instance_id field.")
        print(f"[orchestrate] using state file: ssh_target={args.ssh_target} instance_ocid={args.instance_ocid}")

    conn_cmd = get_console_connection_string(args.instance_ocid, args.key, args.script_dir)
    print(f"[orchestrate] serial command: {conn_cmd}")

    print("[orchestrate] opening serial console session...")
    console = pexpect.spawn(conn_cmd, timeout=30, encoding="utf-8")
    global SERIAL_LOG
    SERIAL_LOG = SerialLog(args.serial_log, echo=args.debug)
    console.logfile_read = SERIAL_LOG

    # Step 1: Verify console before jumping. Consume the WHOLE banner
    # (through its closing ===== line), not just the word "IMPORTANT" —
    # otherwise the banner's doc URL (which contains a "#fragment") is
    # left sitting in the buffer and can falsely satisfy a later PROMPT
    # match before the real shell prompt ever arrives.
    try:
        console.expect("IMPORTANT", timeout=25)
        console.expect("=================================================", timeout=10)
    except pexpect.TIMEOUT:
        sys.exit("FATAL: never saw OCI console banner. Aborting before jump.")

    print("\n[orchestrate] console confirmed live.")
    mark("serial console connection live")

    ip = args.ssh_target.split("@", 1)[1]
    serial_used = False

    def serial_prepare():
        nonlocal serial_used
        if not Path(args.ssh_pubkey).exists():
            sys.exit(f"FATAL: --ssh-pubkey not found at {args.ssh_pubkey}.")
        login_to_alpine(console)
        print(f"[orchestrate] pushing {args.ssh_pubkey} to /root/.ssh/authorized_keys...")
        push_authorized_key(console, args.ssh_pubkey)
        ensure_sshd(console)
        serial_used = True

    state = detect_state(ip, args.ssh_target)
    if state == "unknown":
        print("[orchestrate] nothing answers on SSH — waiting up to 90s (may be mid-reboot)...")
        state = wait_for_state(ip, args.ssh_target, 90)
    print(f"[orchestrate] detected state: {state}")
    mark("stock OS reachable (waiting for it to boot)")

    ram_before = None
    if state == "prejump":
        ram_before, ram_before_raw = read_ram(args.ssh_target)
        if ram_before:
            print("[orchestrate] RAM on the stock OCI image, before the jump:")
            print("\n".join("    " + l for l in ram_before_raw.splitlines()))
        print("[orchestrate] staging via network SSH...")
        staging = subprocess.run(
            [f"{args.script_dir}/bootstrap.sh", args.ssh_target, args.alpine_version, args.answerfile],
            input="y\n", text=True, capture_output=not args.debug)
        if staging.returncode != 0:
            if not args.debug:
                print(staging.stdout or "", staging.stderr or "", sep="\n", file=sys.stderr)
            sys.exit("FATAL: bootstrap.sh staging failed. Serial session left untouched.")
        if not args.debug:   # debug already streamed everything; otherwise show the remote step timings
            for line in (staging.stdout or "").splitlines():
                if "(t+" in line or line.startswith("kexec cache:") or "host-cached kexec" in line:
                    print("    " + line.strip())
        mark("staging (kexec-tools + netboot downloads)")
        print("[orchestrate] staged. Triggering the jump (kexec -e)...")
        subprocess.run(["ssh", "-o", "ConnectTimeout=5", args.ssh_target, "sudo", "kexec", "-e"])
        print("[orchestrate] watching serial for Alpine boot (up to 10 min; it downloads a ~290 MB module image at boot, so speed varies)...")
        waited = 0
        while True:
            try:
                console.expect("localhost login:", timeout=60)
                break
            except pexpect.TIMEOUT:
                waited += 60
                if waited >= 600:
                    sys.exit("FATAL: never saw Alpine login prompt on serial within 600s. "
                             "The box may still be booting: re-run orchestrate.py to resume, or check state/serial.log.")
                print(f"[orchestrate] still waiting for Alpine to boot ({waited}s)...")
        mark("jump: Alpine booted to login prompt")
        state = "unknown"

    if state == "unknown":
        # Alpine live env with no key yet, or installed system with network down.
        serial_prepare()
        mark("serial login + key push + sshd up")
        state = wait_for_state(ip, args.ssh_target, 60)
        if state == "unknown":
            sys.exit("FATAL: key pushed over serial but root SSH still unreachable — "
                     "check network/sshd on the box via serial.")
        print(f"[orchestrate] re-detected state: {state}")

    if state == "ram":
        if install_complete(ip):
            print("[orchestrate] install already finished on /dev/sda3 — skipping setup-alpine.")
        else:
            print("[orchestrate] RAM env, install not complete — running setup-alpine over serial.")
            if not serial_used:   # already logged in + key pushed + sshd up if we got here via serial
                serial_prepare()
            print("[orchestrate] pushing answerfile over serial (chunked base64)...")
            push_answerfile_over_serial(console, args.answerfile)
            print("[orchestrate] running: setup-alpine -e -f /root/answers")
            console.sendline("setup-alpine -e -f /root/answers")
            if console.expect(["Setup a user", pexpect.TIMEOUT], timeout=30) == 0:
                console.sendline("")
            if console.expect(["Erase the above disk", pexpect.TIMEOUT], timeout=60) != 0:
                sys.exit("FATAL: never saw erase confirmation within 60s — not guessing 'y'.")
            console.sendline("y")
            console.expect("Installation is complete", timeout=300)
            mark("setup-alpine install to disk")

        print("[orchestrate] rebooting onto the installed disk...")
        if serial_used:
            console.sendline("sync; reboot")
        else:
            ssh_run(f"root@{ip}", "sync; reboot", timeout=15)
        state = wait_for_state(ip, args.ssh_target, 240, want="installed")
        mark("reboot onto installed disk")

    if state != "installed":
        sys.exit(f"FATAL: never reached the installed system (last state: {state}). "
                 f"Check the box over serial.")

    print("[orchestrate] installed Alpine reachable — verifying + hardening...")
    # Keep one authenticated session open across the lock so we can roll back
    # if a *new* login turns out to be refused.
    keeper = subprocess.Popen(SSH_BASE + ["-o", "ControlPath=none", "-o", "ControlMaster=no",
                                          f"root@{ip}", "sh"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
    h = subprocess.run(SSH_BASE + ["-o", "ControlPath=none", f"root@{ip}", "sh -s"],
                       input=HARDEN, text=True, capture_output=True)
    print(h.stdout, end="")
    if h.stderr:
        print(h.stderr, end="", file=sys.stderr)
    if h.returncode != 0:
        out, _ = keeper.communicate(ROLLBACK_AND_DIAG, timeout=30)
        print(out, file=sys.stderr)
        sys.exit("FATAL: verify/harden failed. Config and shadow were rolled back via the held session.")
    m = re.search(r"used: (\d+) MB of (\d+) MB, available: (\d+) MB", h.stdout)
    ram_after = (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None

    print("[orchestrate] verifying a fresh key-only root login (retrying while sshd settles)...")
    ok, attempt, out, err = fresh_key_login(ip)
    if not ok:
        print(f"[orchestrate] FRESH LOGIN REFUSED after {attempt} attempts. ssh said:\n{err}", file=sys.stderr)
        out, _ = keeper.communicate(ROLLBACK_AND_DIAG, timeout=30)
        print(out, file=sys.stderr)
        sys.exit("FATAL: hardening locked out key login; rolled back via the held session. See diagnostics above.")
    keeper.communicate("exit\n", timeout=15)

    problems = []
    if not re.search(r"^passwordauthentication no$", out, re.M):
        problems.append("sshd is still allowing password authentication")
    if not re.search(r"^permitrootlogin (prohibit-password|without-password)$", out, re.M):
        problems.append("PermitRootLogin is not key-only")
    if not re.search(r"^root_shadow=[*!]$", out, re.M):
        problems.append("root's shadow password field is not disabled")
    if problems:
        sys.exit("FATAL: key login works but the box is NOT locked down: " + "; ".join(problems)
                 + f"\n--- fresh-login report ---\n{out}")
    print(f"[orchestrate] OK: fresh key-only root login succeeded (attempt {attempt}); "
          f"password login disabled (sshd + shadow).")

    if ram_after:
        a_used, a_total, a_avail = ram_after
        if ram_before:
            b_used, b_total, b_avail = ram_before
            gain = a_avail - b_avail
            print(f"[orchestrate] RAM available to workloads: {b_avail} MB (stock OCI image) -> {a_avail} MB (Alpine)"
                  f" = +{gain} MB ({a_avail / b_avail:.1f}x)" if b_avail else "")
            print(f"[orchestrate]   in use (total-available): {b_used} MB -> {a_used} MB;"
                  f" kernel-visible total: {b_total} MB -> {a_total} MB (each kernel reserves different memory at boot)")
        else:
            print(f"[orchestrate] RAM on Alpine: {a_avail} MB available, {a_used} MB in use, of {a_total} MB "
                  f"(no 'before' figure: run resumed after the jump)")
    mark("harden + verify")
    print_timing()
    print("\n[orchestrate] done.")
    print(f"\nssh root@{ip}")


if __name__ == "__main__":
    try:
        main()
    except (SystemExit, pexpect.ExceptionPexpect) as e:
        failed = isinstance(e, pexpect.ExceptionPexpect) or e.code not in (0, None)
        if failed and SERIAL_LOG is not None and not SERIAL_LOG.echo:
            print(f"\n--- last serial output ({SERIAL_LOG.path}) ---\n{SERIAL_LOG.tail()}\n---",
                  file=sys.stderr)
        raise
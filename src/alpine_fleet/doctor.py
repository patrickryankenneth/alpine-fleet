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


def ts_key_path() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or "~/.config").expanduser()
    return Path(os.environ.get("TS_KEY_FILE") or base / "alpine-fleet" / "tailscale-key")


def ts_token() -> str | None:
    if os.environ.get("TS_API_KEY", "").strip():
        return os.environ["TS_API_KEY"].strip()
    try:
        return "".join(ts_key_path().read_text().split()) or None
    except OSError:
        return None


TS_HELP = (
    "set TS_API_KEY, or save a key (https://login.tailscale.com/admin/settings/keys) to "
    "~/.config/alpine-fleet/tailscale-key with chmod 600"
)


def tailscale_problem() -> str | None:
    """Reason --tailscale cannot work, or None. Checked before launching anything."""
    if not shutil.which("curl"):
        return "curl is required for --tailscale"
    if not ts_token():
        return "no Tailscale API key found: " + TS_HELP
    return None


def ts_api_ok(token: str) -> bool:
    import base64
    import urllib.request
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/devices",
        headers={"Authorization": "Basic " + base64.b64encode(f"{token}:".encode()).decode()})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status == 200
    except Exception:
        return False


def ts_rows(network: bool = False) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    token = ts_token()
    if not token:
        rows.append(("optional", "tailscale key", TS_HELP))
        return rows
    from_env = bool(os.environ.get("TS_API_KEY", "").strip())
    rows.append(("ok", "tailscale key", "from $TS_API_KEY" if from_env else str(ts_key_path())))
    if not from_env:
        try:
            if ts_key_path().stat().st_mode & 0o077:
                rows.append(("optional", "key file mode", f"too open: chmod 600 {ts_key_path()}"))
        except OSError:
            pass
    if network:
        if ts_api_ok(token):
            rows.append(("ok", "tailscale API", "key accepted"))
        else:
            rows.append(("optional", "tailscale API", "request failed: key expired/invalid or no network"))
    if not shutil.which("tailscale"):
        rows.append(("optional", "tailscale CLI", "install it on this host so <alias> resolves"))
    return rows


def ts_acl_row(token: str) -> tuple[str, str, str]:
    """Heuristic ACL check (reads the policy only). tag:fleet <-> servers."""
    import base64
    import json
    import urllib.request
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/acl",
        headers={"Authorization": "Basic " + base64.b64encode(f"{token}:".encode()).decode(),
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            pol = json.load(r)
    except Exception as e:
        return ("optional", "tailnet ACL", f"could not fetch policy: {e}")
    rules = pol.get("acls") or []
    if not rules:
        return ("optional", "tailnet ACL", "no 'acls' rules (grants or default policy?): verify tag:fleet <-> servers by hand")

    def covers(spec: str, port: int) -> bool:
        for p in spec.split(","):
            if p == "*" or p == str(port):
                return True
            a, _, b = p.partition("-")
            if a.isdigit() and b.isdigit() and int(a) <= port <= int(b):
                return True
        return False

    def allowed(src_ok, dst_ok, port: int) -> bool:
        for r in rules:
            if r.get("action") != "accept" or not any(src_ok(s) for s in r.get("src", [])):
                continue
            for d in r.get("dst", []):
                host, _, spec = d.rpartition(":")
                if dst_ok(host) and covers(spec, port):
                    return True
        return False

    missing = []
    for port in (6443, 8472):
        if not allowed(lambda s: s in ("tag:fleet", "*"), lambda h: h != "tag:fleet", port):
            missing.append(f"tag:fleet->servers:{port}")
    for port in (8472, 10250):
        if not allowed(lambda s: True, lambda h: h in ("tag:fleet", "*"), port):
            missing.append(f"servers->tag:fleet:{port}")
    if missing:
        return ("optional", "tailnet ACL", "no accept rule found for " + ", ".join(missing) + " (heuristic: check by hand)")
    return ("ok", "tailnet ACL", "rules found: fleet->servers 6443,8472; servers->fleet 8472,10250")


def k3s_rows() -> list[tuple[str, str, str]]:
    """Read-only checks for --k3s. Never modifies the cluster."""
    import json
    import socket
    import subprocess
    kc = ["k3s", "kubectl"] if shutil.which("k3s") else (["kubectl"] if shutil.which("kubectl") else None)
    if not kc:
        return [("optional", "k3s cluster", "kubectl not found (only needed for --k3s)")]

    def kj(*a: str):
        r = subprocess.run(kc + list(a) + ["-o", "json"], capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

    try:
        nodes = kj("get", "nodes")
        svc = kj("-n", "default", "get", "svc", "kubernetes")
    except Exception as e:
        return [("optional", "k3s cluster", f"cannot query cluster: {e}")]
    if not nodes:
        return [("optional", "k3s cluster", "cannot reach the cluster with kubectl")]
    items = nodes.get("items", [])
    rows: list[tuple[str, str, str]] = [("ok", "k3s cluster", f"{len(items)} nodes visible")]

    bad = []
    for n in items:
        be = n["metadata"].get("annotations", {}).get("flannel.alpha.coreos.com/backend-type")
        if be in ("host-gw", "wireguard-native"):  # virtual-kubelet nodes have none
            bad.append(f"{n['metadata']['name']}={be}")
    if bad:
        rows.append(("optional", "flannel backend", ", ".join(bad) +
                     ": host-gw can't work over Tailscale; run the k3s servers with --flannel-backend=vxlan"))
    else:
        rows.append(("ok", "flannel backend", "no host-gw/wireguard-native nodes"))

    pods = sorted({c for n in items for c in (n.get("spec", {}).get("podCIDRs") or [])})
    svc_ip = ((svc or {}).get("spec") or {}).get("clusterIP", "?")
    rows.append(("ok", "pod/svc CIDRs", f"pods {', '.join(pods) or '?'}; services contain {svc_ip}. "
                 "Any server with firewalld must trust these ranges"))

    crio = [n["metadata"]["name"] for n in items
            if "cri-o" in n.get("status", {}).get("nodeInfo", {}).get("containerRuntimeVersion", "")]
    if crio:
        rows.append(("optional", "CRI-O short names", f"on {', '.join(crio)}: if CoreDNS shows ImageInspectError, add "
                     "unqualified-search-registries = [\"docker.io\"] in /etc/containers/registries.conf.d/ and restart crio"))

    url = ""
    cf = Path(os.environ.get("XDG_CONFIG_HOME") or "~/.config").expanduser() / "alpine-fleet" / "k3s-url"
    try:
        url = cf.read_text().strip()
    except OSError:
        r = subprocess.run(kc + ["config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}"],
                           capture_output=True, text=True)
        url = r.stdout.strip()
    hp = url.split("://", 1)[-1].split("/")[0]
    host, port = (hp.rsplit(":", 1) + ["6443"])[:2] if ":" in hp else (hp, "6443")
    if host in ("127.0.0.1", "localhost", ""):
        t = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True) if shutil.which("tailscale") else None
        host = t.stdout.split()[0] if t and t.returncode == 0 and t.stdout.split() else ""
    if not host:
        rows.append(("optional", "k3s API reach", f"no tailnet API URL: put https://<tailscale-ip>:6443 in {cf}"))
    else:
        try:
            socket.create_connection((host, int(port)), timeout=5).close()
            rows.append(("ok", "k3s API reach", f"{host}:{port} reachable"))
        except (OSError, ValueError) as e:
            rows.append(("optional", "k3s API reach", f"{host}:{port} not reachable ({e})"))

    token = ts_token()
    if token:
        rows.append(ts_acl_row(token))
    return rows


def blocking() -> list[str]:
    rows, _ = check()
    return [label for status, label, _ in rows if status == "MISSING"]


def run(fix: bool = False) -> int:
    rows, pkgs = check()
    rows += ts_rows(network=True)
    rows += k3s_rows()
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

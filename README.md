# 🏔️ alpine-fleet

> Give me a disposable OCI micro VM, and I will deterministically and declaratively turn it into a lightweight, hardened Alpine machine.

`alpine-fleet` converts an Oracle Cloud (OCI) **VM.Standard.E2.1.Micro** instance from the stock Oracle Linux image into a minimal **Alpine Linux** install with **key-only root SSH** (no password). Once your OCI CLI is configured, a run is hands-off: it launches the instance, jumps it into Alpine with `kexec`, installs Alpine to the boot disk over the serial console, locks down SSH, and verifies the result. Proven on the E2.1.Micro across 50+ end-to-end runs.

> ⚠️ **Destructive operation**
> This project installs Alpine onto `/dev/sda` and **replaces the existing operating system**. The orchestrator confirms the installer's "erase disk" prompt automatically. Use it only on disposable or recoverable instances.

```bash
pipx install 'alpine-fleet[oci]'
alpine-fleet doctor          # checks your host, prints the install command for anything missing
alpine-fleet up              # launch (if needed), convert, harden, verify
```

## 📊 Why do this? (The RAM Vampire)

The E2.1.Micro free-tier instance has 1 GB of RAM, so what the OS itself uses matters. Measured on OCI PHX over five runs:

| Metric | Stock Oracle Linux 7.9 | Alpine Linux 3.24 |
| :--- | :--- | :--- |
| **RAM available to workloads** | 288–316 MB | **778–792 MB** |
| **In use (total − available)** | 351–379 MB | **167–181 MB** |
| **Total the kernel reports** | 668 MB | 960 MB |

That is **+472 to +500 MB (2.5–2.7×)** more usable RAM.

The stock boot reports `crashkernel=auto` and exposes noticeably less memory to the running system than Alpine's kernel does (this project did not measure exactly how much of that difference is the crash-kernel reservation). The rest of the improvement comes from Alpine's much smaller userspace. A full automated run takes about **315–337 seconds**.

## 🛠️ Install and requirements

```bash
pipx install 'alpine-fleet[oci]'     # or: pip install 'alpine-fleet[oci]'
alpine-fleet doctor                  # add --fix to be offered the install command
```

pip cannot install system packages, so `doctor` checks them for you (Python 3.9+; Linux, macOS or WSL; native Windows is not supported).

| Tool | Needed for | How to get it |
| :--- | :--- | :--- |
| **OCI CLI** | Launch, teardown, capacity discovery | Installed by the `[oci]` extra, then run `oci setup config` |
| **`jq`** | JSON handling in the shell scripts | `pacman -S jq`, `apt install jq`, `dnf install jq`, `brew install jq` |
| **OpenSSH** (`ssh`, `scp`, `ssh-keygen`) | Remote staging and serial tunneling | System package (`openssh-client` on Debian/Ubuntu) |
| **bash 4+** | The shell scripts | macOS ships 3.2: `brew install bash` |
| **`podman`** or **`docker`** *(optional)* | `alpine-fleet cache` (faster runs) | System package manager |

You also need free E2.1.Micro capacity in your OCI region, a VCN with a public subnet, and an SSH keypair (default public key: `~/.ssh/id_ed25519.pub`, and its private key must be your default SSH identity).

The OCI serial console proxy requires an **RSA** key (Ed25519 is rejected), by default `~/.ssh/oci-console-rsa`. If you don't have one:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/oci-console-rsa -N ''
```

Working from a checkout instead: `pip install -e '.[oci]'`.

## 🚀 Usage

| Command | What it does |
| :--- | :--- |
| `alpine-fleet doctor [--fix]` | Check host requirements; print the install command for anything missing. |
| `alpine-fleet discover` | Show E2.1.Micro and A1.Flex headroom per availability domain, discovered dynamically. |
| `alpine-fleet up [--yes] [--debug] [--no-launch]` | Launch an instance if none is running (retries until capacity appears), then convert, harden and verify. Prints phase timings and a RAM comparison, and ends with the `ssh root@<ip>` command. |
| `alpine-fleet convert USER@IP INSTANCE_OCID` | Convert an existing instance. You must type its address to confirm (or pass `--yes`). |
| `alpine-fleet down [--yes]` | Terminate the instance recorded in the state file. |
| `alpine-fleet cache [--force]` | Build the Oracle Linux 7 `kexec` binary cache in a container (skips installing `kexec-tools` on the target). |

`up` and `convert` also accept `--alpine-version` (default `v3.24`), `--ssh-pubkey`, `--console-key` and `--answerfile`.

Every run detects where the box is (stock OS, Alpine in RAM, or installed) and resumes from there, so an interrupted run can simply be repeated.

**Where things live.** Instance state and serial transcripts (instance IDs and IPs) are in `~/.local/state/alpine-fleet/`; the kexec cache is in `~/.cache/alpine-fleet/kexec/`. Nothing is written to the install directory.

**Environment overrides.**

| Variable | Effect |
| :--- | :--- |
| `SUBNET_ID`, `IMAGE_ID`, `COMPARTMENT_ID` | Override auto-discovery (default: first subnet found, newest compatible Oracle Linux image, tenancy root compartment). |
| `DISPLAY_NAME`, `SSH_KEY_FILE` | Instance name and the public key given to the stock image's `opc` user. |
| `OCI_BIN`, `OCI_CONFIG_FILE` | Use a specific `oci` binary or config file. |
| `ALPINE_FLEET_STATE_DIR`, `KEXEC_CACHE` | Relocate state and cache. |
| `NO_KEXEC_CACHE=1` | Ignore the cache and install `kexec-tools` on the target. |

## ⚠️ Before you run it

**This project is intentionally destructive.** The answerfile installs to `/dev/sda` and replaces the existing operating system. Do not run it against a VM that holds data you need. The orchestrator waits for the installer's erase prompt and confirms it, but it does *not* check which disk the prompt names.

The `kexec` transition is also disruptive: **SSH to the stock OS disappears the moment the new kernel takes over.** That is expected. The orchestrator treats the lost connection as a state transition and continues through the serial console.

## ⚙️ How it works

1. **Launch:** Provisions an E2.1.Micro in an availability domain with headroom and opens a serial console connection.
2. **Stage:** Connects over SSH. Copies the cached `kexec` (or installs `kexec-tools` on the target if there is no cache), downloads the Alpine netboot kernel and initramfs in parallel, and loads them with `kexec -l`.
3. **Jump:** Triggers `kexec -e`. Alpine boots into RAM and downloads its ~290 MB module image from the Alpine mirror; that download's speed varies from run to run.
4. **Install:** Over the serial console: logs in, pushes your public key, starts `sshd`, pushes the answerfile (chunked base64) to `/root/answers`, and runs `setup-alpine -e -f /root/answers`. The root password prompt is bypassed with `-e`.
5. **Reboot:** Reboots off the physical block volume onto the installed disk.
6. **Harden and verify:** Root's password field is set to `*`, `PermitRootLogin prohibit-password` and `PasswordAuthentication no` are written to `sshd_config`, and a fresh key-only login is tested (retried while `sshd` settles). If that login is refused, the hardening changes (`sshd_config` and root's shadow entry) are **rolled back** through a session held open across the change, and `sshd`'s log is printed.

### 🚨 The `*` versus `!` gotcha

BusyBox `passwd -l` writes a `!`-prefixed hash. Alpine's `sshd` is built without PAM, and without PAM, OpenSSH treats a `!` hash as a locked account and refuses **public-key** logins too. Setting the field to `*` blocks password logins but still allows SSH keys. *Use `*`.*

## 🚧 Known limits

- **Provider support: OCI only, tested on VM.Standard.E2.1.Micro only.** The bundled answerfile assumes `/dev/sda` and performs a destructive disk install. Other clouds, images and shapes need their own disk and device handling.
- The free tier allows two E2.1.Micro instances; `up` stops if two are already running.
- The `kexec` cache applies to the stock **Oracle Linux 7** image. Any other image misses the cache and falls back to installing `kexec-tools` on the target, which is much slower.
- Root ends key-only with no password. If your private key is lost, you must rebuild the instance.
- Boot time depends on the mirror; the orchestrator waits up to 10 minutes for the Alpine login prompt.
- macOS hosts need bash 4+ (see above) and have not been tested.

## 📂 Repository layout

```text
src/alpine_fleet/
  cli.py, doctor.py, paths.py   the `alpine-fleet` command
  scripts/                      orchestrate.py, bootstrap.sh, launch/teardown/discover/console helpers, lib/
  answerfiles/                  setup-alpine answerfile for the OCI micro
licenses/, THIRD_PARTY_NOTICES.txt
```

`scripts/e2e-test.sh` (a destructive full-cycle test) lives in the repo only and is not shipped in the wheel.

## 📄 License

MIT. Third-party notices are in `THIRD_PARTY_NOTICES.txt` and `licenses/`. The `kexec` binary in the cache is built locally from Oracle's own package and is never distributed with this project.
# 🏔️ alpine-fleet

Automated conversion of an Oracle Cloud (OCI) **VM.Standard.E2.1.Micro** instance from the stock Oracle Linux image into a minimal **Alpine Linux** install with **key-only root SSH** (no password). 

Once your machine is configured, the whole run is zero-touch: it launches the instance, jumps it into Alpine with `kexec`, installs Alpine to the boot disk over the serial console, locks down SSH, and verifies the result.

> ⚠️ **Destructive Operation**  
> This project installs Alpine onto `/dev/sda` and **replaces the existing operating system**. The orchestrator confirms the installer's "erase disk" prompt automatically. Use it only on disposable or recoverable instances.

```bash
# First run: build the kexec cache, then do one full lifecycle cycle
./scripts/e2e-test.sh --prepare     
```

## 📊 Why do this? (The RAM Vampire)

The OCI E2.1.Micro free-tier instance has 1 GB of RAM, so what the OS itself uses matters immensely. Measured on OCI PHX over four runs:

| Metric | Stock Oracle Linux 7.9 | Alpine Linux 3.24 |
| :--- | :--- | :--- |
| **RAM available to workloads** | 289–316 MB | **778–792 MB** |
| **In use (total − available)** | 351–379 MB | **167–181 MB** |
| **Total the kernel reports** | 668 MB | 960 MB |

That is **+472 to +500 MB (2.5–2.7×)** more usable RAM. 

The stock boot reports `crashkernel=auto` and exposes noticeably less memory to the running system than Alpine's kernel does (this project did not measure exactly how much of that difference is the crash-kernel reservation). The rest of the improvement comes from Alpine's much smaller userspace. A full automated `orchestrate.py` run takes about **315–337 seconds**.

## 🛠️ Requirements

You need free E2.1.Micro capacity in your OCI region and the following tools:

| Tool | Needed for | Installation |
| :--- | :--- | :--- |
| **OCI CLI** | Launch, teardown, capacity discovery | `pip install oci-cli` (or Oracle's installer), then `oci setup config` |
| **`jq`** | JSON handling in the shell scripts | `pacman -S jq`, `apt install jq`, or `brew install jq` |
| **OpenSSH** (`ssh`, `scp`, `ssh-keygen`) | Remote staging and serial tunneling | System package manager (`openssh-client` on Debian/Ubuntu).* |
| **Python 3 + `pexpect`** | `orchestrate.py` (drives the serial console) | `pip install pexpect`, or `python-pexpect` (Arch) / `python3-pexpect` (Debian/Ubuntu). |
| **`podman`** or **`docker`** *(optional)* | Building the `kexec` cache | System package manager |

*\*Note: The OCI console proxy requires an **RSA** key (Ed25519 is rejected). The script will automatically use `ssh-keygen` to generate one at `~/.ssh/oci-console-rsa` if it doesn't exist.*

## 🚀 Usage

| Command | What it does |
| :--- | :--- |
| `scripts/e2e-test.sh [--runs N] [--debug] [--prepare]` | Full cycle: tear down, launch, jump, install, harden, assert. Stops at the first failure. |
| `scripts/orchestrate.py [--debug]` | Launch (if no live instance) and drive it to the final state; prints phase timing and a RAM comparison. |
| `scripts/discover-capacity.sh` | Show E2.1.Micro and A1.Flex headroom per availability domain, discovered dynamically. |
| `scripts/prepare-kexec-cache.sh [--force]` | Build the Oracle Linux 7 `kexec` binary cache in a container. |
| `scripts/teardown-e2.sh [--yes]` | Terminate the instance recorded in `state/current-instance.json`. |

*`SUBNET_ID` overrides the subnet picked automatically. Runtime state and serial transcripts live in `state/` (ignored by git: it contains instance IDs and IPs). A successful run ends by printing the `ssh root@<ip>` command.*

## ⚠️ Before you run it

**This project is intentionally destructive.** The answerfile installs to `/dev/sda` and replaces the existing operating system. Do not run it against a VM that holds data you need. The orchestrator waits for the installer's erase prompt and confirms it, but it does *not* check which disk the prompt names.

The `kexec` transition is also disruptive: **SSH to the stock OS disappears the moment the new kernel takes over.** That is expected. The orchestrator treats the lost connection as a state transition and continues through the serial console.

## ⚙️ How it works

1. **Launch:** Provisions an E2.1.Micro in an availability domain with headroom and opens a serial console connection.
2. **Stage:** Connects over SSH. Copies the cached `kexec` (or installs `kexec-tools` on the target if there is no cache), downloads the Alpine netboot kernel and initramfs in parallel, and loads them with `kexec -l`.
3. **Jump:** Triggers `kexec -e`. Alpine boots into RAM and downloads its ~290 MB module image from the Alpine mirror; that download's speed varies from run to run.
4. **Install:** Over the serial console: logs in, pushes your public key, starts `sshd`, pushes the answerfile (via chunked base64) to `/root/answers`, and runs `setup-alpine -e -f /root/answers`. The root password prompt is bypassed with `-e`.
5. **Reboot:** Reboots off the physical block volume onto the installed disk.
6. **Harden and Verify:** Root's password field is set to `*`, `PermitRootLogin prohibit-password` and `PasswordAuthentication no` are written to `sshd_config`, and a fresh key-only login is tested (retried while `sshd` settles). If that login is refused, the hardening changes (`sshd_config` and root's shadow entry) are **rolled back** through a session held open across the change, and `sshd`'s log is printed.

### 🚨 The `*` versus `!` gotcha

BusyBox `passwd -l` writes a `!`-prefixed hash. Alpine's `sshd` is built without PAM, and without PAM, OpenSSH treats a `!` hash as a locked account and refuses **public-key** logins too. Setting the field to `*` blocks password logins but still allows SSH keys. *Use `*`.*

## 🚧 Known limits

- **Tested on OCI VM.Standard.E2.1.Micro only.** The current answerfile assumes `/dev/sda` and performs a destructive disk install. Other clouds, images, and shapes need their own disk and device handling.
- The `kexec` cache applies to the stock **Oracle Linux 7** image (`cache/kexec/ol-7/kexec`). Any other image misses the cache and falls back to installing `kexec-tools` on the target package manager, which is much slower.
- Root ends key-only with no password. If your private key is lost, you must rebuild the instance.
- Boot time depends on the mirror; the orchestrator waits up to 10 minutes for the Alpine login prompt.

## 📂 Layout

```text
scripts/      orchestrate.py, e2e-test.sh, bootstrap.sh, launch/teardown/discover/console helpers, lib/
answerfiles/  setup-alpine answerfile for the OCI micro
cache/        host-side kexec cache (built locally, not committed)
state/        current instance and serial logs (not committed)
```
# alpine-fleet

Swap a running cloud VM's OS to Alpine Linux **without console access to the provider's image-import pipeline** — using `kexec` to jump straight into an Alpine installer kernel, no reboot into a bootloader required.

Useful when:
- Your cloud provider's custom-image import feature is gated behind a paid tier / requires a billing method you don't want to attach for a free-tier box.
- You just want a much lighter OS on a small (e.g. 1GB RAM) instance than the default image ships with.
- You're fine with the instance being destroyed and re-provisioned if something goes wrong (this is **not** a zero-risk operation).

## How it works

1. SSH into the running instance (whatever OS it currently has — tested on Ubuntu 24.04).
2. Install `kexec-tools`, download Alpine's netboot kernel/initramfs/modloop.
3. `kexec -l` the new kernel with boot params telling it where to fetch its own root filesystem and packages from (`ip=dhcp`, `alpine_repo=`, `modloop=`).
4. `kexec -e` — jumps directly into the new kernel in RAM, skipping the bootloader/BIOS entirely. Your SSH session dies immediately.
5. The instance boots into a live Alpine environment. From there, `setup-alpine` installs it permanently to disk.
6. Reboot — the instance now boots Alpine from disk like any normal install.

## Why this needs a serial/console connection

Step 4 is a one-way door for the *current* boot — if anything goes wrong (bad kernel params, no network, wrong root device), you get a kernel panic and no way back in over SSH. A cloud provider's serial console (OCI, most others have an equivalent) is your only visibility during that window. **Set this up and confirm it works before running `kexec -e`.**

## Usage

```bash
./scripts/bootstrap.sh <ssh-user>@<instance-ip>
```

See `scripts/bootstrap.sh` for the exact kexec invocation and `answerfiles/` for a non-interactive `setup-alpine` template.

## Provider notes

- **OCI**: tested end-to-end on `VM.Standard.E2.1.Micro` (1 GB RAM). Console access via `oci compute instance-console-connection create` (requires an **RSA** key — OCI's console connection service rejects ed25519).
- **GCP / Azure**: not yet scripted here — both support native custom-image import more easily than OCI's free tier does, so the recommended path there is building a proper Alpine image with `packer`/`alpine-make-vm-image` and importing it normally, rather than kexec. PRs welcome if someone wants to script the kexec path for them anyway.

## Known gotchas (learned the hard way)

- The netboot initramfs alone is **not enough** — you need `alpine_repo=` and `modloop=` boot params or it panics with `/sbin/init not found`.
- `ip=dhcp` handles both DHCP *and* DNS setup inside the initramfs; doing it manually via `udhcpc` in an emergency shell does **not** set `/etc/resolv.conf`, which silently breaks package fetching.
- `setup-alpine`'s default netmask guess (based on IP class) is often wrong for cloud VCN subnets — check your actual subnet CIDR rather than accepting the default.
- SSH keys/config added *before* the final reboot into the disk install don't persist — the live/kexec environment's `/root` is not the same filesystem as the disk install `setup-alpine` just created. Add keys **after** the final reboot.
- OCI console connections are deleted automatically under some disconnect conditions — don't assume one console session lasts you the whole procedure; re-check `lifecycle-state` if a reconnect fails.

## Disclaimer

This is a disruptive, semi-experimental technique. It uses standard Linux kernel functionality (`kexec`) on infrastructure you control — the same approach providers like Hetzner and OVH document for their own rescue-mode tooling. It is **not** a way to bypass any security control; it's a way to install different software on a machine you already have root on. That said: only run this on instances you're fully prepared to lose.

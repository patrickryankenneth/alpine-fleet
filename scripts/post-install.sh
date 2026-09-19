#!/bin/sh
# Run this ON THE INSTANCE, as root, AFTER the final reboot into the
# real disk-based Alpine install (not in the live/kexec environment —
# anything written there does not persist to disk).
#
# Usage (paste your own public key as the first argument, or edit below):
#   ./post-install.sh "ssh-ed25519 AAAA... you@host"

set -eu

PUBKEY="${1:?Usage: post-install.sh \"<your-ssh-public-key>\"}"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<EOF
${PUBKEY}
EOF
chmod 600 /root/.ssh/authorized_keys

# Allow root login via key only, never via password.
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
rc-service sshd restart

echo "Done. Test from your local machine with:"
echo "  ssh -i <your-private-key> root@<instance-ip>"

#!/usr/bin/env bash
# Initial server setup: creates a sudo user with SSH key login and enables a
# firewall that allows SSH. Supports Ubuntu/Debian and RHEL-family
# (RHEL, Rocky, AlmaLinux, CentOS Stream, Fedora).
#
# Usage (as root):
#   USERNAME=sammy PUBLIC_KEY="ssh-ed25519 AAAA... you@laptop" ./user-initial-setup.sh
# or edit the defaults below.

set -euo pipefail

USERNAME="${USERNAME:-sammy}"                       # Change this
PUBLIC_KEY="${PUBLIC_KEY:-ssh-rsa AAAAB3NzaC1yc2E...}"  # Your public key
SSH_PORT="${SSH_PORT:-22}"
# The account has no password, so sudo needs NOPASSWD to be usable.
# Set SUDO_NOPASSWD=no if you will set a password yourself (passwd $USERNAME).
SUDO_NOPASSWD="${SUDO_NOPASSWD:-yes}"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root (or with sudo)." >&2
    exit 1
fi

if [[ "$PUBLIC_KEY" == *"AAAAB3NzaC1yc2E..." ]]; then
    echo "Set PUBLIC_KEY to your real public key first." >&2
    exit 1
fi

# --- Detect distro family ---------------------------------------------------
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    echo "Cannot detect OS (/etc/os-release missing)." >&2
    exit 1
fi

case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) FAMILY=debian; SUDO_GROUP=sudo ;;
    *" rhel "*|*" fedora "*|*" centos "*) FAMILY=rhel; SUDO_GROUP=wheel ;;
    *) echo "Unsupported OS: ${PRETTY_NAME:-unknown}" >&2; exit 1 ;;
esac
echo "Detected ${PRETTY_NAME:-$ID} (family: $FAMILY)"

# --- Create user ------------------------------------------------------------
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists, skipping creation."
else
    if [[ $FAMILY == debian ]]; then
        adduser --disabled-password --gecos "" "$USERNAME"
    else
        useradd -m -s /bin/bash "$USERNAME"
        passwd -l "$USERNAME" >/dev/null   # no password login; key only
    fi
fi
usermod -aG "$SUDO_GROUP" "$USERNAME"

if [[ $SUDO_NOPASSWD == yes ]]; then
    SUDOERS_FILE="/etc/sudoers.d/90-$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" >/dev/null
fi

# --- SSH key ----------------------------------------------------------------
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
mkdir -p "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
grep -qxF "$PUBLIC_KEY" "$HOME_DIR/.ssh/authorized_keys" \
    || echo "$PUBLIC_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.ssh"
# Fix SELinux contexts on RHEL so sshd can read the key
if command -v restorecon &>/dev/null; then
    restorecon -R "$HOME_DIR/.ssh" || true
fi

# --- Firewall ---------------------------------------------------------------
if [[ $FAMILY == debian ]]; then
    if ! command -v ufw &>/dev/null; then
        apt-get update -y && apt-get install -y ufw
    fi
    if [[ $SSH_PORT == 22 ]]; then
        ufw allow OpenSSH
    else
        ufw allow "${SSH_PORT}/tcp"
    fi
    ufw --force enable
else
    if ! command -v firewall-cmd &>/dev/null; then
        dnf install -y firewalld
    fi
    systemctl enable --now firewalld
    if [[ $SSH_PORT == 22 ]]; then
        firewall-cmd --permanent --add-service=ssh
    else
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
        # Let SELinux allow sshd on the non-standard port
        if command -v semanage &>/dev/null; then
            semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
                || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" || true
        fi
    fi
    firewall-cmd --reload
fi

echo "Setup complete! User: $USERNAME"
echo "Test from another terminal BEFORE closing this session:"
echo "  ssh -p $SSH_PORT $USERNAME@<server-ip>"

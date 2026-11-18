#!/usr/bin/env bash
# Initial server setup: creates a sudo user with SSH key login and enables a
# firewall that allows SSH.
#
# Supported: Debian/Ubuntu (and derivatives), RHEL family (RHEL, Rocky, Alma,
# CentOS Stream, Oracle, Fedora, Amazon Linux), SUSE/openSUSE, Arch (and
# derivatives), Alpine.
#
# Usage (as root):
#   USERNAME=sammy PUBLIC_KEY="ssh-ed25519 AAAA... you@laptop" bash user-initial-setup.sh
#
# Variables:
#   USERNAME       user to create                       (default: sammy)
#   PUBLIC_KEY     SSH public key to authorize          (required)
#   SSH_PORT       SSH port to allow in the firewall    (default: 22)
#   SUDO_NOPASSWD  yes|no  passwordless sudo            (default: yes)
#   SKIP_FIREWALL  yes|no  don't touch the firewall     (default: no)

set -euo pipefail

USERNAME="${USERNAME:-sammy}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
# The account has no password, so sudo needs NOPASSWD to be usable.
SUDO_NOPASSWD="${SUDO_NOPASSWD:-yes}"
SKIP_FIREWALL="${SKIP_FIREWALL:-no}"

warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root (or with sudo)."
[[ -n $PUBLIC_KEY && $PUBLIC_KEY != *"AAAAB3NzaC1yc2E..." ]] \
    || die "Set PUBLIC_KEY to your real public key."
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid USERNAME: $USERNAME"
[[ $SSH_PORT =~ ^[0-9]+$ ]] || die "Invalid SSH_PORT: $SSH_PORT"

# --- Detect distro ----------------------------------------------------------
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
IDS=" ${ID:-} ${ID_LIKE:-} "

case "$IDS" in
    *" debian "*|*" ubuntu "*)                       PM=apt;    SUDO_GROUP=sudo  ;;
    *" rhel "*|*" fedora "*|*" centos "*)            PM=dnf;    SUDO_GROUP=wheel ;;
    *" suse "*|*" opensuse "*|*" sles "*)            PM=zypper; SUDO_GROUP=wheel ;;
    *" arch "*)                                      PM=pacman; SUDO_GROUP=wheel ;;
    *" alpine "*)                                    PM=apk;    SUDO_GROUP=wheel ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}" ;;
esac
if [[ $PM == dnf ]] && ! command -v dnf &>/dev/null; then PM=yum; fi   # Amazon Linux 2, CentOS 7
echo "Detected ${PRETTY_NAME:-$ID} (package manager: $PM, admin group: $SUDO_GROUP)"

pkg_install() {
    case $PM in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        pacman) pacman -Syu --noconfirm --needed "$@" ;;  # full upgrade; partial (-Sy) upgrades break Arch
        apk)    apk add --no-cache "$@" ;;
    esac
}

# Enable and start a service on systemd or OpenRC; warn (don't abort) if neither runs.
enable_service() {
    local svc=$1
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        systemctl enable --now "$svc" || warn "could not start $svc"
    elif command -v rc-update &>/dev/null; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
        rc-service "$svc" start || warn "could not start $svc"
    else
        warn "no init system detected; start $svc manually"
    fi
}

# --- Base tools -------------------------------------------------------------
# useradd/usermod/passwd -l come from different packages per family (and are
# absent on Alpine and some minimal images).
if ! command -v useradd &>/dev/null || ! command -v usermod &>/dev/null; then
    case $PM in
        apt)       pkg_install passwd ;;
        dnf|yum)   pkg_install shadow-utils ;;
        zypper|pacman|apk) pkg_install shadow ;;
    esac
fi
command -v useradd &>/dev/null || die "useradd not found."
command -v sudo &>/dev/null || pkg_install sudo

# --- Create user ------------------------------------------------------------
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists, skipping creation."
else
    useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || useradd -m "$USERNAME"
    usermod -L "$USERNAME"   # lock password; key-only login
fi
getent group "$SUDO_GROUP" >/dev/null || groupadd "$SUDO_GROUP"
usermod -aG "$SUDO_GROUP" "$USERNAME"

if [[ $SUDO_NOPASSWD == yes ]]; then
    mkdir -p /etc/sudoers.d
    SUDOERS_FILE="/etc/sudoers.d/90-$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" >/dev/null || { rm -f "$SUDOERS_FILE"; die "invalid sudoers entry"; }
    grep -rqsE '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
        || warn "/etc/sudoers does not include /etc/sudoers.d; sudo may not work"
fi

# --- SSH key ----------------------------------------------------------------
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
GROUP_NAME="$(id -gn "$USERNAME")"
mkdir -p "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
grep -qxF "$PUBLIC_KEY" "$HOME_DIR/.ssh/authorized_keys" \
    || echo "$PUBLIC_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USERNAME:$GROUP_NAME" "$HOME_DIR/.ssh"
# Fix SELinux contexts so sshd can read the key
if command -v restorecon &>/dev/null; then
    restorecon -R "$HOME_DIR/.ssh" || true
fi
command -v sshd &>/dev/null || [[ -x /usr/sbin/sshd ]] \
    || warn "sshd not found; install and enable openssh-server to log in over SSH."

# --- Firewall ---------------------------------------------------------------
setup_ufw() {
    command -v ufw &>/dev/null || pkg_install ufw
    ufw allow "${SSH_PORT}/tcp"
    ufw --force enable
    [[ $PM == apk ]] && enable_service ufw
    return 0
}

setup_firewalld() {
    command -v firewall-cmd &>/dev/null || pkg_install firewalld
    enable_service firewalld
    local fw=firewall-cmd
    if ! firewall-cmd --state &>/dev/null; then
        warn "firewalld is not running; writing offline config (applies on next start)"
        fw=firewall-offline-cmd
    fi
    if [[ $SSH_PORT == 22 ]]; then
        $fw --permanent --add-service=ssh 2>/dev/null || $fw --add-service=ssh
    else
        $fw --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null || $fw --add-port="${SSH_PORT}/tcp"
        # Let SELinux allow sshd on the non-standard port
        if command -v getenforce &>/dev/null && [[ $(getenforce) == Enforcing ]]; then
            if command -v semanage &>/dev/null; then
                semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
                    || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" || true
            else
                warn "SELinux is enforcing: install policycoreutils-python-utils and run: semanage port -a -t ssh_port_t -p tcp $SSH_PORT"
            fi
        fi
    fi
    [[ $fw == firewall-cmd ]] && firewall-cmd --reload
    return 0
}

if [[ $SKIP_FIREWALL == yes ]]; then
    echo "Skipping firewall setup (SKIP_FIREWALL=yes)."
else
    case $PM in
        apt|pacman|apk) setup_ufw ;;
        dnf|yum|zypper) setup_firewalld ;;
    esac
fi

echo "Setup complete! User: $USERNAME"
echo "Test from another terminal BEFORE closing this session:"
echo "  ssh -p $SSH_PORT $USERNAME@<server-ip>"

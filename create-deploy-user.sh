#!/usr/bin/env bash
# Creates a locked-down "deploy" user for GitHub Actions to deploy over SSH.
#
# It generates a dedicated ed25519 key pair, authorizes the public key for the
# deploy user, and prints (and saves to a file) every GitHub secret and variable
# the workflow needs, plus a ready-to-paste workflow snippet.
#
# Works on Debian/Ubuntu, RHEL family, SUSE, Arch and Alpine.
#
# Usage (as root):
#   bash create-deploy-user.sh
#   SSH_HOST=deploy.example.com SSH_PORT=2222 DEPLOY_PATH=/srv/myapp bash create-deploy-user.sh
#
# Variables:
#   DEPLOY_USER    user to create                          (default: deploy)
#   SSH_HOST       hostname/IP GitHub will connect to      (default: auto-detected)
#   SSH_PORT       sshd port                               (default: 22)
#   DEPLOY_PATH    directory the deploy user owns          (default: /srv/apps)
#   DEPLOY_DOCKER  yes|no  add user to the docker group    (default: no)
#                  WARNING: docker group access is equivalent to root.
#   DEPLOY_SUDO_CMDS  comma-separated absolute commands the user may run via
#                  passwordless sudo, e.g. "/usr/bin/systemctl restart myapp"
#   OUTPUT_FILE    where to save the secrets               (default: /root/github-actions-deploy-secrets.txt)
#
# Re-running rotates the key: the old GitHub key is removed and a new one issued.

set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
DEPLOY_PATH="${DEPLOY_PATH:-/srv/apps}"
DEPLOY_DOCKER="${DEPLOY_DOCKER:-no}"
DEPLOY_SUDO_CMDS="${DEPLOY_SUDO_CMDS:-}"
OUTPUT_FILE="${OUTPUT_FILE:-/root/github-actions-deploy-secrets.txt}"
KEY_COMMENT="github-actions-deploy"

warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root (or with sudo)."
[[ $DEPLOY_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid DEPLOY_USER: $DEPLOY_USER"
[[ $SSH_PORT =~ ^[0-9]+$ ]] || die "Invalid SSH_PORT: $SSH_PORT"
[[ $DEPLOY_PATH == /* ]] || die "DEPLOY_PATH must be an absolute path."

# --- Detect distro ----------------------------------------------------------
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
IDS=" ${ID:-} ${ID_LIKE:-} "
case "$IDS" in
    *" debian "*|*" ubuntu "*)            PM=apt;    KEYGEN_PKG=openssh-client ;;
    *" rhel "*|*" fedora "*|*" centos "*) PM=dnf;    KEYGEN_PKG=openssh-clients ;;
    *" suse "*|*" opensuse "*|*" sles "*) PM=zypper; KEYGEN_PKG=openssh-clients ;;
    *" arch "*)                           PM=pacman; KEYGEN_PKG=openssh ;;
    *" alpine "*)                         PM=apk;    KEYGEN_PKG=openssh-keygen ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}" ;;
esac
if [[ $PM == dnf ]] && ! command -v dnf &>/dev/null; then PM=yum; fi
echo "Detected ${PRETTY_NAME:-$ID} (package manager: $PM)"

pkg_install() {
    case $PM in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) local rc=0
                zypper --non-interactive install "$@" || rc=$?
                case $rc in 0|102|103|106) return 0 ;; *) return "$rc" ;; esac ;;
        pacman) pacman -Syu --noconfirm --needed "$@" ;;
        apk)    apk add --no-cache "$@" ;;
    esac
}

# --- Prerequisites ----------------------------------------------------------
if ! command -v useradd &>/dev/null || ! command -v usermod &>/dev/null; then
    case $PM in
        apt)       pkg_install passwd ;;
        dnf|yum)   pkg_install shadow-utils ;;
        zypper|pacman|apk) pkg_install shadow ;;
    esac
fi
command -v useradd &>/dev/null || die "useradd not found."
command -v ssh-keygen &>/dev/null || pkg_install "$KEYGEN_PKG"
command -v ssh-keygen &>/dev/null || die "ssh-keygen not found."

# --- Create user ------------------------------------------------------------
if id "$DEPLOY_USER" &>/dev/null; then
    echo "User $DEPLOY_USER already exists; rotating its GitHub Actions key."
else
    useradd -m -s /bin/bash "$DEPLOY_USER" 2>/dev/null || useradd -m "$DEPLOY_USER"
    usermod -L "$DEPLOY_USER"   # lock password; key-only login
fi
HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
GROUP_NAME="$(id -gn "$DEPLOY_USER")"

# --- Deploy directory -------------------------------------------------------
mkdir -p "$DEPLOY_PATH"
chown "$DEPLOY_USER:$GROUP_NAME" "$DEPLOY_PATH"
chmod 750 "$DEPLOY_PATH"

# --- Optional privileges ----------------------------------------------------
if [[ $DEPLOY_DOCKER == yes ]]; then
    if getent group docker >/dev/null; then
        usermod -aG docker "$DEPLOY_USER"
        warn "$DEPLOY_USER is in the docker group, which is equivalent to root access."
    else
        warn "docker group not found; install Docker first, then: usermod -aG docker $DEPLOY_USER"
    fi
fi

if [[ -n $DEPLOY_SUDO_CMDS ]]; then
    command -v sudo &>/dev/null || pkg_install sudo
    mkdir -p /etc/sudoers.d
    SUDOERS_FILE="/etc/sudoers.d/91-$DEPLOY_USER"
    echo "$DEPLOY_USER ALL=(root) NOPASSWD: ${DEPLOY_SUDO_CMDS//,/, }" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" >/dev/null || { rm -f "$SUDOERS_FILE"; die "invalid DEPLOY_SUDO_CMDS"; }
fi

# --- Key pair ---------------------------------------------------------------
# The private key is generated in a temp dir, written only to the secrets file,
# and never left on disk anywhere else.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
chmod 700 "$TMP_DIR"
ssh-keygen -q -t ed25519 -N "" -C "$KEY_COMMENT" -f "$TMP_DIR/key"
PUB_KEY="$(cat "$TMP_DIR/key.pub")"

mkdir -p "$HOME_DIR/.ssh"
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH_KEYS"
# Drop any previous GitHub Actions key, then add the new one (restricted).
grep -vF " $KEY_COMMENT" "$AUTH_KEYS" > "$TMP_DIR/auth" || true
echo "no-port-forwarding,no-agent-forwarding,no-X11-forwarding $PUB_KEY" >> "$TMP_DIR/auth"
cat "$TMP_DIR/auth" > "$AUTH_KEYS"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$AUTH_KEYS"
chown -R "$DEPLOY_USER:$GROUP_NAME" "$HOME_DIR/.ssh"
if command -v restorecon &>/dev/null; then restorecon -R "$HOME_DIR/.ssh" || true; fi

# --- Gather GitHub values ---------------------------------------------------
if [[ -z $SSH_HOST ]]; then
    SSH_HOST="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n $SSH_HOST ]] || SSH_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n $SSH_HOST ]] || SSH_HOST="<server-ip-or-hostname>"
    warn "SSH_HOST auto-detected as $SSH_HOST. Re-run with SSH_HOST=... if that is not what GitHub should use."
fi

# Pin the server's host key (avoids disabling host key checking in the workflow).
HOST_KEY_FILE=/etc/ssh/ssh_host_ed25519_key.pub
KNOWN_HOSTS="<run: ssh-keyscan -p $SSH_PORT $SSH_HOST>"
if [[ -r $HOST_KEY_FILE ]]; then
    HK="$(awk '{print $1" "$2}' "$HOST_KEY_FILE")"
    if [[ $SSH_PORT == 22 ]]; then KNOWN_HOSTS="$SSH_HOST $HK"; else KNOWN_HOSTS="[$SSH_HOST]:$SSH_PORT $HK"; fi
else
    warn "$HOST_KEY_FILE not found (is openssh-server installed?). Fill in SSH_KNOWN_HOSTS with: ssh-keyscan -p $SSH_PORT $SSH_HOST"
fi
command -v sshd &>/dev/null || [[ -x /usr/sbin/sshd ]] \
    || warn "sshd not found; install and enable openssh-server so GitHub can connect."

# --- Write and print the secrets file --------------------------------------
umask 077
{
cat <<TXT
GitHub Actions deploy credentials for ${DEPLOY_USER}@${SSH_HOST}
Generated: $(date -u +"%Y-%m-%d %H:%M:%SZ")

*** KEEP THIS FILE PRIVATE. It contains a private key. ***
Copy the values into GitHub, then delete this file from the server:
  shred -u $OUTPUT_FILE   (or: rm -f $OUTPUT_FILE)

========================================================================
REPOSITORY SECRETS   (Settings > Secrets and variables > Actions > Secrets)
========================================================================

SSH_HOST:
${SSH_HOST}

SSH_KNOWN_HOSTS:
${KNOWN_HOSTS}

SSH_PRIVATE_KEY:
$(cat "$TMP_DIR/key")

========================================================================
REPOSITORY VARIABLES (Settings > Secrets and variables > Actions > Variables)
========================================================================

SSH_USER:
${DEPLOY_USER}

SSH_PORT:
${SSH_PORT}

DEPLOY_PATH:
${DEPLOY_PATH}

========================================================================
EXAMPLE WORKFLOW STEP
========================================================================

      - name: Configure SSH
        run: |
          mkdir -p ~/.ssh
          echo "\${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          echo "\${{ secrets.SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts

      - name: Deploy
        run: |
          rsync -az --delete -e "ssh -i ~/.ssh/deploy_key -p \${{ vars.SSH_PORT }}" \\
            ./ \${{ vars.SSH_USER }}@\${{ secrets.SSH_HOST }}:\${{ vars.DEPLOY_PATH }}/

With the GitHub CLI you can also set them from your machine, e.g.:
  gh secret set SSH_PRIVATE_KEY < private_key_file
  gh variable set SSH_USER --body "${DEPLOY_USER}"
TXT
} > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
echo
echo "Saved to: $OUTPUT_FILE (mode 600). Delete it once the values are in GitHub."

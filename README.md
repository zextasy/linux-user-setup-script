# linux-user-setup-script

Two bash scripts for setting up a fresh Linux server with SSH key access. They work on the popular
distro families and use the distro's own package manager and firewall.

| Script | Purpose | Instructions |
|---|---|---|
| [`user-initial-setup.sh`](user-initial-setup.sh) | Creates **your admin user**: a non-root user with `sudo`, your SSH public key, and a firewall that allows SSH. Run once on a new server. | [docs/user-initial-setup.md](docs/user-initial-setup.md) |
| [`create-deploy-user.sh`](create-deploy-user.sh) | Creates a locked-down **`deploy` user for GitHub Actions**: a dedicated SSH key, then prints and saves every GitHub secret and variable your workflow needs. | [docs/create-deploy-user.md](docs/create-deploy-user.md) |

## Typical order

1. On a new server, as root, run **`user-initial-setup.sh`** to create your own admin user and enable the firewall.
2. Log in as that user, then run **`create-deploy-user.sh`** (with `sudo`) to set up the account GitHub Actions deploys with.
3. Copy the printed secrets and variables into your GitHub repository, then delete the secrets file from the server.

## Quick start

```bash
# 1. Your admin user (as root)
USERNAME=sammy PUBLIC_KEY="ssh-ed25519 AAAA... you@example.com" bash user-initial-setup.sh

# 2. The GitHub Actions deploy user (as root, or with sudo)
SSH_HOST=deploy.example.com bash create-deploy-user.sh
```

Both scripts need to be run as root and are safe to re-run. See the instructions files for all options.

## Supported distros

| Family | Distros | Package manager | Firewall (`user-initial-setup.sh`) |
|---|---|---|---|
| Debian | Debian, Ubuntu, Mint, Pop!_OS, Raspberry Pi OS | `apt` | `ufw` |
| RHEL | RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora, Amazon Linux | `dnf` / `yum` | `firewalld` |
| SUSE | openSUSE Leap/Tumbleweed, SLES | `zypper` | `firewalld` |
| Arch | Arch, Manjaro, EndeavourOS | `pacman` | `ufw` |
| Alpine | Alpine | `apk` | `ufw` |

Distros are detected from `/etc/os-release` (`ID` / `ID_LIKE`), so derivatives work automatically.
The scripts need **bash**; on Alpine run `apk add bash` first.

## Security notes

- Both users have password login disabled; access is by SSH key only.
- `create-deploy-user.sh` writes a **private key** to a root-only file. Copy it into GitHub and delete the file.
- The deploy user has no sudo unless you opt in, and its key cannot forward ports.

## Testing

Both scripts were tested in containers (Ubuntu, Debian, Rocky, Alma, Fedora, Amazon Linux, openSUSE, Arch, Alpine) with real package installs. `create-deploy-user.sh` was verified with a real SSH login on all of them; `user-initial-setup.sh` on Ubuntu, Alma and Alpine. Not covered: real systemd hosts (starting firewall services), SELinux enforcement, and live GitHub Actions runs. Run on a throwaway VM before relying on them in production.

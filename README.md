# linux-user-setup-script

Initial server setup script that works on most popular Linux distros. It:

- creates a non-root user with a locked password (key-only login) and adds it to the admin group (`sudo` on Debian/Ubuntu, `wheel` elsewhere)
- installs your SSH public key (and fixes SELinux contexts where applicable)
- enables a firewall allowing SSH: `ufw` on Debian/Ubuntu, Arch and Alpine; `firewalld` on RHEL-family and SUSE
- installs any missing prerequisites (`sudo`, `ufw`/`firewalld`, `useradd` tooling) with the distro's package manager

The script is idempotent: re-running it won't duplicate keys or fail on an existing user.

## Supported distros

| Family | Distros | Package manager | Firewall |
|---|---|---|---|
| Debian | Debian, Ubuntu, Mint, Pop!_OS, Raspberry Pi OS | `apt` | `ufw` |
| RHEL | RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora, Amazon Linux | `dnf` / `yum` | `firewalld` |
| SUSE | openSUSE Leap/Tumbleweed, SLES | `zypper` | `firewalld` |
| Arch | Arch, Manjaro, EndeavourOS | `pacman` | `ufw` |
| Alpine | Alpine | `apk` | `ufw` |

Detection uses `/etc/os-release` (`ID` / `ID_LIKE`), so derivatives are picked up automatically.
The script needs **bash**; on Alpine run `apk add bash` first.

## 1. Create an SSH key (on your local machine)

```bash
ssh-keygen -t ed25519 -C "you@example.com"
```

Accept the default path (`~/.ssh/id_ed25519`) and set a passphrase. Print the public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Never share the private key (`id_ed25519` without `.pub`).

## 2. Run the script (on the server, as root)

Copy it over and run it, passing the username and public key:

```bash
scp user-initial-setup.sh root@<server-ip>:/root/
ssh root@<server-ip>
```

```bash
USERNAME=sammy PUBLIC_KEY="ssh-ed25519 AAAA... you@example.com" bash user-initial-setup.sh
```

Optional variables:

| Variable        | Default | Description                                                        |
|-----------------|---------|--------------------------------------------------------------------|
| `USERNAME`      | `sammy` | User to create                                                     |
| `PUBLIC_KEY`    | (none)  | Public key to authorize (required)                                 |
| `SSH_PORT`      | `22`    | SSH port to allow through the firewall (and SELinux on RHEL)       |
| `SUDO_NOPASSWD` | `yes`   | The user has no password, so sudo is passwordless. Use `no` and run `passwd <user>` if you prefer a password. |
| `SKIP_FIREWALL` | `no`    | Set to `yes` to leave the firewall untouched                       |

## 3. Log in as the new user

**Keep your root session open** and test from a second terminal:

```bash
ssh sammy@<server-ip>
# custom port / specific key:
ssh -i ~/.ssh/id_ed25519 -p 2222 sammy@<server-ip>
```

Optionally add a shortcut to `~/.ssh/config` on your local machine:

```
Host myserver
    HostName <server-ip>
    User sammy
    IdentityFile ~/.ssh/id_ed25519
```

Then connect with `ssh myserver`.

## 4. (Recommended) Harden SSH

Once key login works, disable root and password logins. Edit `/etc/ssh/sshd_config`
(or a file in `/etc/ssh/sshd_config.d/`):

```
PermitRootLogin no
PasswordAuthentication no
```

Validate and reload (the service is `ssh` on Debian/Ubuntu, `sshd` elsewhere):

```bash
sudo sshd -t
sudo systemctl reload ssh     # Debian/Ubuntu
sudo systemctl reload sshd    # RHEL, SUSE, Arch
sudo rc-service sshd reload   # Alpine
```

## Troubleshooting

- **Permission denied (publickey)**: check `~/.ssh` is `700`, `authorized_keys` is `600`, and both are owned by the user. On RHEL run `restorecon -R ~/.ssh`.
- **Locked out after firewall change**: use your provider's web console; make sure `SSH_PORT` matches your sshd port.
- **Custom port on RHEL (SELinux enforcing)**: the script runs `semanage port` for you; if it is missing, install `policycoreutils-python-utils`.
- **"sshd not found" warning**: install and enable OpenSSH (`openssh-server`, or `openssh` on Arch/SUSE/Alpine) before logging out.
- **Firewall not started warning** (containers, or no init system): the rules are written but take effect when the firewall service starts.

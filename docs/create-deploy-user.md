# Instructions: `create-deploy-user.sh`

Creates a locked-down **`deploy`** user that GitHub Actions uses to deploy applications over SSH.
It generates a dedicated SSH key pair, authorizes the public key, and then **prints and saves every
GitHub secret and variable** your workflow needs, plus an example workflow step.

Run it as root on a server that already has OpenSSH installed and running (for example after
[`user-initial-setup.sh`](user-initial-setup.md)).

## What it does

- creates `deploy` with password login disabled (key-only) and **no sudo access** by default
- creates the deploy directory (default `/srv/apps`), owned by `deploy`
- generates a new ed25519 key pair; the **private key is never left on the server**: it only exists in the output file
- authorizes the public key with `no-port-forwarding,no-agent-forwarding,no-X11-forwarding`
- captures the server's SSH host key so your workflow can verify the host instead of skipping host-key checks
- writes everything to `/root/github-actions-deploy-secrets.txt` (mode `600`) and prints it
- re-running **rotates the key**: the old GitHub key is removed and a new one is issued

## 1. Run the script (on the server, as root)

From the repository root on your local machine:

```bash
scp create-deploy-user.sh root@<server-ip>:/root/
ssh root@<server-ip>
```

```bash
SSH_HOST=deploy.example.com bash create-deploy-user.sh
```

If you log in as a sudo user instead of root: `sudo SSH_HOST=<host> bash create-deploy-user.sh`, then read the
output with `sudo cat /root/github-actions-deploy-secrets.txt`.

### Variables

| Variable           | Default                                   | Description |
|--------------------|-------------------------------------------|-------------|
| `DEPLOY_USER`      | `deploy`                                  | User to create |
| `SSH_HOST`         | auto-detected                             | Hostname or IP GitHub will connect to. Auto-detection asks `api.ipify.org` for the server's public IP and warns; **set this yourself** if you use a domain or don't want the lookup. |
| `SSH_PORT`         | `22`                                      | Port sshd listens on |
| `DEPLOY_PATH`      | `/srv/apps`                               | Directory owned by the deploy user |
| `DEPLOY_DOCKER`    | `no`                                      | `yes` adds the user to the `docker` group. **This is root-equivalent access.** Install Docker first, otherwise the group doesn't exist and the script only warns. |
| `DEPLOY_SUDO_CMDS` | (none)                                    | Comma-separated absolute commands the user may run via passwordless sudo, e.g. `"/usr/bin/systemctl restart myapp"` |
| `OUTPUT_FILE`      | `/root/github-actions-deploy-secrets.txt` | Where the secrets are saved |

Example with options:

```bash
SSH_HOST=deploy.example.com SSH_PORT=2222 DEPLOY_PATH=/srv/myapp \
DEPLOY_SUDO_CMDS="/usr/bin/systemctl restart myapp" \
bash create-deploy-user.sh
```

## 2. Add the values to GitHub

All GitHub names use the `VPS_` prefix. (The input variables above, like `SSH_HOST`, only configure the script; they are not GitHub names.)

The script output lists each value. In your repository go to
**Settings > Secrets and variables > Actions**.

**Secrets** (the *Secrets* tab):

| Name              | Contents |
|-------------------|----------|
| `VPS_SSH_HOST`        | Server hostname or IP |
| `VPS_SSH_KNOWN_HOSTS` | The server's host-key line (`[host]:port ssh-ed25519 AAAA...`) |
| `VPS_SSH_PRIVATE_KEY` | The full private key, including the `BEGIN`/`END` lines |

**Variables** (the *Variables* tab):

| Name          | Contents |
|---------------|----------|
| `VPS_SSH_USER`    | `deploy` (or your `DEPLOY_USER`) |
| `VPS_SSH_PORT`    | sshd port |
| `VPS_DEPLOY_PATH` | Directory the user owns |

Or with the GitHub CLI from your own machine (copy the key into a local file first):

```bash
gh secret set VPS_SSH_PRIVATE_KEY < private_key_file
gh secret set VPS_SSH_HOST --body "deploy.example.com"
gh secret set VPS_SSH_KNOWN_HOSTS < known_hosts_file
gh variable set VPS_SSH_USER --body "deploy"
gh variable set VPS_SSH_PORT --body "22"
gh variable set VPS_DEPLOY_PATH --body "/srv/apps"
```

## 3. Delete the secrets file

Once the values are in GitHub, remove the file: it contains the private key.

```bash
shred -u /root/github-actions-deploy-secrets.txt   # or: rm -f ...
```

## 4. Use it in a workflow

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.VPS_SSH_PRIVATE_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          echo "${{ secrets.VPS_SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts

      - name: Deploy
        run: |
          rsync -az --delete -e "ssh -i ~/.ssh/deploy_key -p ${{ vars.VPS_SSH_PORT }}" \
            ./ ${{ vars.VPS_SSH_USER }}@${{ secrets.VPS_SSH_HOST }}:${{ vars.VPS_DEPLOY_PATH }}/
```

The key is restricted, so the workflow can run commands and copy files, but cannot tunnel ports.

## Rotating the key

Run the script again. It replaces the old key in `authorized_keys` and writes a new secrets file. Update
`VPS_SSH_PRIVATE_KEY` (and `VPS_SSH_KNOWN_HOSTS` if the host key changed) in GitHub, then delete the file.

## Security notes

- The deploy user has **no sudo** unless you set `DEPLOY_SUDO_CMDS`. List exact commands, not wildcards.
- `DEPLOY_DOCKER=yes` lets the user start containers that can read or change anything on the host. Only use it for trusted repositories.
- Anyone who can edit your workflows can use the key. Use GitHub **environments** with required reviewers for production deploys.
- Keep the key's scope small: one server, one user, one purpose.

## Troubleshooting

- **`Permission denied (publickey)`**: confirm `VPS_SSH_PRIVATE_KEY` was pasted completely (including the trailing newline), and that `~deploy/.ssh` is `700` and `authorized_keys` is `600`, owned by `deploy`. On SELinux systems run `restorecon -R ~deploy/.ssh`.
- **`Host key verification failed`**: `VPS_SSH_KNOWN_HOSTS` must match the host and port GitHub connects to (`[host]:port` when the port isn't 22). Regenerate with `ssh-keyscan -p <port> <host>`.
- **`sshd not found` / `host_ed25519_key.pub not found`**: install and start OpenSSH (`openssh-server`, or `openssh` on Arch/SUSE/Alpine) and re-run; until then fill in `VPS_SSH_KNOWN_HOSTS` with `ssh-keyscan`.
- **Wrong `SSH_HOST`**: the auto-detected IP may be a NAT or proxy address. Re-run with `SSH_HOST=...`.
- **`docker group not found`**: install Docker, then `sudo usermod -aG docker deploy`.
- **Firewall**: the script does not open ports. Make sure sshd's port is allowed (see `user-initial-setup.sh`).

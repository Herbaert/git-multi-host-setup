# git-multi-host-setup

Automated setup for multiple git accounts across multiple hosts (GitHub, GitLab, Gitea, self-hosted, ...) with clean separation of SSH keys, git identity and GPG signing – driven purely by the **project directory** a repo lives in.

## What the script does

For every account defined in the accounts file, it automatically:

- generates a dedicated **SSH key** (ed25519)
- generates or reuses a dedicated **GPG key** (ed25519/cv25519, no passphrase, valid for 2 years)
- creates a matching project directory under `~/projects/<folder>`
- writes a dedicated `~/.gitconfig-<alias>` containing:
  - `user.name` / `user.email`
  - `core.sshCommand` → automatically uses the right SSH key
  - `user.signingkey`, `commit.gpgsign = true`, `tag.gpgsign = true`
- appends an `includeIf "gitdir:..."` entry to `~/.gitconfig` that loads the right config as soon as you are inside that directory

**No SSH host alias required.** Repos are cloned with the real host URL as usual (e.g. `git@github.com:org/repo.git`) – as long as they end up in the right project directory, the correct SSH key, commit identity and GPG signature apply automatically.

## Requirements

- `bash`
- `ssh-keygen` (package `openssh-client`)
- `gpg` (package `gnupg`)
- Git ≥ 2.13 (for `includeIf`)

## Usage

1. Copy the example file and fill in your real data:

   ```bash
   cp accounts.conf.example accounts.conf
   ```

   One line per account, format:

   ```
   alias|hostname|ssh_user|project_folder|git_name|git_email
   ```

   | Field | Meaning |
   |---|---|
   | `alias` | internal identifier for the key filename & git config (does not appear in the clone URL) |
   | `hostname` | real hostname, e.g. `github.com` |
   | `ssh_user` | usually `git` |
   | `project_folder` | relative path under `~/projects`, e.g. `github-work` |
   | `git_name` | name used in commits made in this directory |
   | `git_email` | e-mail used in commits made in this directory |

   Blank lines and lines starting with `#` are ignored.

   By default `accounts.conf` is expected in the same directory as the script. A
   different file can be passed via `./setup-git-hosts.sh /path/to/other.conf`
   or through the `ACCOUNTS_FILE` environment variable.

   `accounts.conf` is listed in `.gitignore` so your real data (e-mail addresses
   etc.) does not get committed to the repo by accident.

   Project directories are created under `~/projects` by default. Set
   `PROJECT_BASE` to use a different base directory:

   ```bash
   PROJECT_BASE=~/code ./setup-git-hosts.sh
   ```

2. Run it:

   ```bash
   chmod +x setup-git-hosts.sh
   ./setup-git-hosts.sh
   ```

3. Perform the steps printed at the end:
   - add the SSH public keys to the respective host
   - add the GPG public keys to the respective host (Settings → SSH and GPG keys)
   - clone repos into the matching directories

4. Verify:

   ```bash
   cd ~/projects/<folder>/repo
   git config user.email
   git config core.sshCommand
   git config user.signingkey
   git commit --allow-empty -m "test"
   git log --show-signature -1
   ```

## Idempotency

The script is safe to run repeatedly. Existing SSH keys, GPG keys, directories, git configs and `includeIf` entries are detected and skipped or updated instead of duplicated. New accounts can be added to `accounts.conf` at any time.

## Security note

The generated GPG keys are created **without a passphrase** (`%no-protection`) so that the script runs fully unattended. This means the private key sits unprotected in the GPG keyring (`~/.gnupg`) – anyone with access to the user account can sign with it.

To protect it afterwards:

```bash
gpg --edit-key <KEY-ID>
passwd
```

## License

MIT – see [LICENSE](./LICENSE).

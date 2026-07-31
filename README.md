# git-multi-host-setup

Automated setup for multiple git accounts across multiple hosts (GitHub, GitLab, Gitea, self-hosted, ...) with clean separation of SSH keys, git identity, GPG signing and HTTPS credentials – driven purely by the **project directory** a repo lives in.

## What the script does

For every account defined in the accounts file, it automatically:

- generates a dedicated **SSH key** (ed25519) – unless the account is HTTPS-only
- generates or reuses a dedicated **GPG key** (ed25519/cv25519, no passphrase, valid for 2 years)
- creates a matching project directory under `~/projects/<folder>`
- writes a dedicated `~/.gitconfig-<alias>` containing:
  - `user.name` / `user.email`
  - `user.signingkey`, `commit.gpgsign = true`, `tag.gpgsign = true`
  - `core.sshCommand` → automatically uses the right SSH key (SSH accounts)
  - `credential.https://<host>.username` → **only** the username (HTTPS accounts)
- appends an `includeIf "gitdir:..."` entry to `~/.gitconfig` that loads the right config as soon as you are inside that directory
- sets a global `credential.helper` (only if none is configured yet) so an HTTPS token typed once is remembered

**No SSH host alias required.** Repos are cloned with the real host URL as usual (e.g. `git@github.com:org/repo.git`) – as long as they end up in the right project directory, the correct SSH key, commit identity and GPG signature apply automatically.

**SSH, HTTPS or both.** Each account chooses its protocol; HTTPS-only accounts get no SSH key at all – see [SSH or HTTPS](#ssh-or-https).

## Requirements

- `bash`
- Git ≥ 2.13 (for `includeIf`)
- `gpg` (package `gnupg`)
- `ssh-keygen` (package `openssh-client`) – only for SSH accounts

## Usage

1. Copy the example file and fill in your real data:

   ```bash
   cp accounts.conf.example accounts.conf
   ```

   One line per account, format:

   ```
   alias|hostname|ssh_user|project_folder|git_name|git_email[|https_user]
   ```

   | Field | Meaning |
   |---|---|
   | `alias` | internal identifier for the key filename & git config (does not appear in the clone URL) |
   | `hostname` | real hostname, e.g. `github.com` |
   | `ssh_user` | usually `git`; leave **empty** to disable SSH for this account (HTTPS only) |
   | `project_folder` | relative path under `~/projects`, e.g. `github-work` |
   | `git_name` | name used in commits made in this directory |
   | `git_email` | e-mail used in commits made in this directory |
   | `https_user` | *optional*: your login name on that host, used for HTTPS remotes. Omit the field for SSH-only accounts. |

   Every account needs at least one of `ssh_user` / `https_user`; the script
   aborts if both are missing.

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

   | Environment variable | Default | Meaning |
   |---|---|---|
   | `PROJECT_BASE` | `~/projects` | base directory for the project folders |
   | `ACCOUNTS_FILE` | `./accounts.conf` | accounts file (same as the first argument) |
   | `CREDENTIAL_HELPER` | auto-detected | credential helper for HTTPS tokens, e.g. `'cache --timeout=3600'` |
   | `CREDENTIAL_CACHE_TIMEOUT` | `86400` | timeout in seconds, only used for the `cache` fallback |
   | `SETUP_CREDENTIAL_HELPER` | `1` | set to `0` to never touch the global `credential.helper` |
   | `DRY_RUN` | `0` | set to `1` to only show what would change, without writing anything |
   | `PRUNE` | `0` | set to `1` to also remove leftovers of accounts no longer in the accounts file |

2. Run it:

   ```bash
   chmod +x setup-git-hosts.sh
   ./setup-git-hosts.sh
   ```

3. Perform the steps printed at the end:
   - add the SSH public keys to the respective host
   - add the GPG public keys to the respective host (Settings → SSH and GPG keys)
   - create a personal access token per host if you want to use HTTPS
   - clone repos into the matching directories

4. Verify:

   ```bash
   cd ~/projects/<folder>/repo
   git config user.email
   git config user.signingkey
   git config core.sshCommand                          # SSH accounts only
   git config credential.https://github.com.username   # HTTPS accounts only
   git commit --allow-empty -m "test"
   git log --show-signature -1
   ```

## SSH or HTTPS

The project directory decides which identity is used, not the protocol. Each account picks its protocols itself:

| Account line | Effect |
|---|---|
| `alias\|github.com\|git\|folder\|Name\|mail\|handle` | SSH **and** HTTPS |
| `alias\|github.com\|git\|folder\|Name\|mail` | SSH only – no HTTPS username |
| `alias\|github.com\|\|folder\|Name\|mail\|handle` | **HTTPS only** – `ssh_user` empty, so no SSH key is generated and no `core.sshCommand` is written |

### SSH

```bash
git clone git@github.com:org/repo.git ~/projects/github-work/repo
```

The key comes from `core.sshCommand` in the per-account config.

### HTTPS

Set the 7th field (`https_user`) for the account, then clone with the username in the URL:

```bash
git clone https://your-handle@github.com/org/repo.git ~/projects/github-work/repo
```

What is stored where:

- **Username** → stored as `credential.https://<host>.username` in `~/.gitconfig-<alias>`, i.e. per project directory. Two accounts on the same host therefore stay apart.
- **Password / token** → never written by this script. Git asks for it on the first push/fetch and hands it to the credential helper, which returns it on every later request.

```
$ git push
Username for 'https://github.com': your-handle      # prefilled from the config
Password for 'https://your-handle@github.com':      # paste the token → asked only once
```

Use a **personal access token**, not your account password:

| Host | Where | Scope |
|---|---|---|
| GitHub | Settings → Developer settings → Personal access tokens | classic: `repo`, fine-grained: Contents read/write |
| GitLab | Settings → Access tokens | `write_repository` |
| Gitea | Settings → Applications → Generate token | repo write |

The helper is picked automatically: `osxkeychain` on macOS, `libsecret` or `manager` on Linux/Windows if present, otherwise `cache --timeout=86400` (in-memory only). It is written to the **global** config once, because the helper only decides *where* credentials are kept – the identity comes from the per-directory username. Override it with `CREDENTIAL_HELPER`, or keep your own with `SETUP_CREDENTIAL_HELPER=0`.

To replace a stored token, erase it and push again:

```bash
printf 'protocol=https\nhost=github.com\nusername=your-handle\n\n' | git credential reject
```

### Note on cloning

`includeIf "gitdir:..."` only matches once a repository exists, so during `git clone` itself the per-account config is not active yet. That is why the username goes into the clone URL (HTTPS) or the key is passed explicitly (SSH):

```bash
git -c core.sshCommand="ssh -i ~/.ssh/id_ed25519_github_work -o IdentitiesOnly=yes" \
    clone git@github.com:org/repo.git ~/projects/github-work/repo
```

Everything after the clone – fetch, push, commit, signing – is picked up automatically from the project directory. The script prints ready-to-use clone commands for both protocols per account.

### Switching an existing repo

```bash
git remote set-url origin https://your-handle@github.com/org/repo.git   # SSH → HTTPS
git remote set-url origin git@github.com:org/repo.git                   # HTTPS → SSH
```

## Idempotency & updates

The script is safe to run repeatedly and doubles as an **update mechanism**: edit `accounts.conf` and run it again, and it reconciles the files on disk with what the accounts file now says.

- **SSH/GPG keys, directories** – created if missing, left alone otherwise (a changed `git_email` does **not** regenerate the GPG key; delete the old one yourself if you really want a new one).
- **`~/.gitconfig-<alias>`** – compared setting by setting against what the account line now produces. Every difference is printed before it's applied, e.g.:
  ```
  ~ user.name: Old Name -> New Name
  + credential.https://github.com.username = new-handle
  - core.sshcommand (was: ssh -i ...)
  ```
- **`includeIf` entries** – if `project_folder` changes, the entry is moved to the new path instead of adding a second, contradicting one. The old directory is reported under "Needs your attention" if it still exists on disk (repos in it keep using the old config until moved).
- **Removed accounts** – deleting a line from `accounts.conf` does **not** delete anything by default, so the leftover `~/.gitconfig-<alias>` and `includeIf` entry are only reported for you to decide. Add `PRUNE=1` to remove them (SSH and GPG keys are never touched by prune – remove those by hand if no longer needed).

Preview any change before committing to it:

```bash
DRY_RUN=1 ./setup-git-hosts.sh              # show the diff, write nothing
DRY_RUN=1 PRUNE=1 ./setup-git-hosts.sh      # ...including what PRUNE would delete
```

The run ends with a summary line, e.g. `2 account(s) - 0 created, 1 updated, 1 unchanged, 0 includeIf added/moved, 0 leftover(s)`.

## Security note

The generated GPG keys are created **without a passphrase** (`%no-protection`) so that the script runs fully unattended. This means the private key sits unprotected in the GPG keyring (`~/.gnupg`) – anyone with access to the user account can sign with it.

To protect it afterwards:

```bash
gpg --edit-key <KEY-ID>
passwd
```

For HTTPS, no password or token ever ends up in a git config file – only the username does. The token is kept by the credential helper: in the system keychain/keyring (`osxkeychain`, `libsecret`, `manager`) or, with the `cache` fallback, in memory until the timeout expires. Avoid `credential.helper store`, which writes tokens in plain text to `~/.git-credentials`.

## License

MIT – see [LICENSE](./LICENSE).

# git-multi-host-setup

Automated setup for multiple git accounts across multiple hosts (GitHub, GitLab, Gitea, self-hosted, ...) with clean separation of SSH keys, git identity, GPG signing and HTTPS credentials – driven purely by the **project directory** a repo lives in.

## What the script does

For every account defined in the accounts file, it automatically:

- generates a dedicated **SSH key** (ed25519, or RSA per account, e.g. for Azure DevOps) – unless the account is HTTPS-only
- generates or reuses a dedicated **GPG key** (ed25519/cv25519, no passphrase, valid for 2 years)
- creates a matching project directory under `~/projects/<folder>`
- writes a dedicated `~/.gitconfig-<alias>` containing:
  - `user.name` / `user.email`
  - `user.signingkey`, `commit.gpgsign = true`, `tag.gpgsign = true`
  - `core.sshCommand` → automatically uses the right SSH key (SSH accounts)
  - `credential.https://<host>.username` → **only** the username (HTTPS accounts)
  - any extra git settings listed under the account (see [Extra git settings](#extra-git-settings))
- appends an `includeIf "gitdir:..."` entry to `~/.gitconfig` that loads the right config as soon as you are inside that directory
- sets a global `credential.helper` (only if none is configured yet) so an HTTPS token typed once is remembered

**No SSH host alias required.** Repos are cloned with the real host URL as usual (e.g. `git@github.com:org/repo.git`) – as long as they end up in the right project directory, the correct SSH key, commit identity and GPG signature apply automatically.

**SSH, HTTPS or both.** Each account chooses its protocol; HTTPS-only accounts get no SSH key at all – see [SSH or HTTPS](#ssh-or-https).

## Requirements

Supported on macOS and Linux. Windows (Git Bash/MSYS) may work but is not tested.

- bash ≥ 5. macOS ships bash 3.2, install a current one with `brew install bash`.
- Git ≥ 2.13 (for `includeIf`)
- `gpg` (package `gnupg`)
- `ssh-keygen` (package `openssh-client`) – only for SSH accounts

## Usage

1. Copy the example file and fill in your real data:

   ```bash
   cp accounts.conf.example accounts.conf
   ```

   The file uses the same syntax as `~/.gitconfig`, one section per account:

   ```ini
   [defaults]
       name = Your Name
       sshUser = git

   [account "github-work"]
       host = github.com
       folder = github-work
       email = work@company.example
       httpsUser = your-gh-handle
   ```

   | Key | Meaning |
   |---|---|
   | `[account "<alias>"]` | one section per account. The alias is the internal identifier for the key filename & git config (does not appear in the clone URL) |
   | `host` | real hostname, e.g. `github.com`. For Azure DevOps either `ssh.dev.azure.com` or `dev.azure.com` – SSH then uses the former, HTTPS the latter |
   | `folder` | relative path under `~/projects`, e.g. `github-work` |
   | `name` | name used in commits made in this directory |
   | `email` | e-mail used in commits made in this directory |
   | `sshUser` | *optional*: usually `git`. Not set or empty disables SSH for this account (HTTPS only) |
   | `httpsUser` | *optional*: your login name on that host, used for HTTPS remotes |
   | `sshKeyType` | *optional*: `ed25519` (default) or `rsa` (4096 bit, key file `~/.ssh/id_rsa_<alias>`). Use `rsa` for hosts that do not accept ed25519, e.g. Azure DevOps |
   | `config` | *optional, repeatable*: `section.key=value`, an extra git setting for this account, see [Extra git settings](#extra-git-settings) |

   `[defaults]` takes the same keys except `folder`. An account's own value
   wins; an empty `sshUser =` in an account turns a default SSH user off again.

   Every account needs at least one of `sshUser` / `httpsUser`; the script
   aborts if both are missing.

   Comments start with `#` or `;`. Values are trimmed, and `work`, `work/` and
   `./work` name the same folder.

   The script aborts before writing anything on invalid syntax, on an unknown
   section or key, on a missing required key, on an `sshKeyType` other than
   `ed25519` or `rsa`, on an alias with characters other than letters, digits,
   `.`, `_`, `-`, and on two accounts sharing a `folder` or an SSH key file
   (`acme-dev` and `acme_dev` both map to `~/.ssh/id_ed25519_acme_dev`).

   The older format with one `|`-separated line per account still works, see
   [Line format](#line-format).

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
   | `GPG_PASSPHRASE` | `0` | set to `1` to protect newly created GPG keys with a passphrase (gpg asks, needs a terminal at least 14 rows high) |
   | `DRY_RUN` | `0` | set to `1` to only show what would change, without writing anything |
   | `PRUNE` | `0` | set to `1` to also remove leftovers of accounts no longer in the accounts file (see [Removed accounts](#idempotency--updates)) |

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

| Account settings | Effect |
|---|---|
| `sshUser = git`, `httpsUser = handle` | SSH **and** HTTPS |
| `sshUser = git` | SSH only – no HTTPS username |
| `httpsUser = handle`, no or empty `sshUser` | **HTTPS only** – no SSH key is generated and no `core.sshCommand` is written |
| `sshUser = git`, `sshKeyType = rsa` | SSH with an **RSA** key instead of ed25519 |
| `host = ssh.dev.azure.com`, `sshUser = git`, `httpsUser = login`, `sshKeyType = rsa` | Azure DevOps with SSH (RSA) **and** HTTPS – the username is stored for `https://dev.azure.com` |

### SSH

```bash
git clone git@github.com:org/repo.git ~/projects/github-work/repo
```

The key comes from `core.sshCommand` in the per-account config.

### HTTPS

Set `httpsUser` for the account, then clone with the username in the URL:

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
| Azure DevOps | User settings → Personal access tokens | Code: Read & write |

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

## Extra git settings

The per-account config is regenerated on every run, so settings added to it by hand would be lost. Put them into `accounts.conf` instead, as `config = section.key=value` in the account's section:

```ini
[account "azure-work"]
    host = ssh.dev.azure.com
    folder = azure-work
    email = work@company.example
    httpsUser = your-login
    sshKeyType = rsa
    config = credential.msauthUseBroker=false
    config = credential.msauthFlow=system
```

This writes

```ini
[credential]
	msauthUseBroker = false
	msauthFlow = system
```

into `~/.gitconfig-azure-work`, so it applies to every repo under that project folder. Like every other setting there, changes show up in the diff on the next run.

- `config` in `[defaults]` applies to every account, before the account's own values.
- Use the dotted form `git config` takes: `credential.msauthFlow`, or with a subsection `credential.https://dev.azure.com.msauthFlow`.
- A key given more than once gets every value, e.g. several `url.<base>.insteadOf`.
- Keys the script writes itself (`user.name`, `user.email`, `user.signingkey`, `core.sshCommand`, `commit.gpgsign`, `tag.gpgsign`, `credential.<url>.username`) are rejected – change those through the account's own keys.
- `includeIf` does not apply during `git clone`, so the printed HTTPS clone command passes `credential.*` settings with `-c`.

## Idempotency & updates

The script is safe to run repeatedly and doubles as an **update mechanism**: edit `accounts.conf` and run it again, and it reconciles the files on disk with what the accounts file now says.

- **SSH/GPG keys, directories** – created if missing, left alone otherwise (a changed `git_email` does **not** regenerate the GPG key; delete the old one yourself if you really want a new one). Switching `ssh_key_type` creates a new key file and points `core.sshCommand` at it; the old key stays. A GPG key must match the e-mail exactly. An expired key is extended by 2 years and keeps its fingerprint, so you only re-upload the public key. If that fails, the run prints the command instead of creating a new key.
- **`~/.gitconfig-<alias>`** – compared setting by setting against what the account now produces. Every difference is printed before it's applied, e.g.:
  ```
  ~ user.name: Old Name -> New Name
  + credential.https://github.com.username = new-handle
  - core.sshcommand (was: ssh -i ...)
  ```
- **`includeIf` entries** – if `folder` changes, the entry is moved to the new path instead of adding a second, contradicting one. The old directory is reported under "Needs your attention" if it still exists on disk (repos in it keep using the old config until moved).
- **Removed accounts** – deleting an account from `accounts.conf` does **not** delete anything by default, so the leftover `~/.gitconfig-<alias>` and `includeIf` entry are only reported for you to decide. Add `PRUNE=1` to remove them (SSH and GPG keys are never touched by prune – remove those by hand if no longer needed).

  `PRUNE` only removes files whose first line is the script's marker for that alias, plus their `includeIf` entries. Hand-written configs and backups such as `~/.gitconfig-work.bak` stay and are counted as *unmanaged*. Configs from older versions get the marker on the next run.

Preview any change before committing to it:

```bash
DRY_RUN=1 ./setup-git-hosts.sh              # show the diff, write nothing
DRY_RUN=1 PRUNE=1 ./setup-git-hosts.sh      # ...including what PRUNE would delete
```

The run ends with a summary line, e.g. `2 account(s) - 0 created, 1 updated, 1 unchanged, 0 includeIf added/moved, 0 leftover(s)`.

## Security note

The generated GPG keys are created **without a passphrase** (`%no-protection`) so that the script runs fully unattended. This means the private key sits unprotected in the GPG keyring (`~/.gnupg`) – anyone with access to the user account can sign with it.

Run with `GPG_PASSPHRASE=1` to have gpg ask for a passphrase when it creates a key. To protect an existing key:

```bash
gpg --edit-key <KEY-ID>
passwd
```

For HTTPS, no password or token ever ends up in a git config file – only the username does. The token is kept by the credential helper: in the system keychain/keyring (`osxkeychain`, `libsecret`, `manager`) or, with the `cache` fallback, in memory until the timeout expires. Avoid `credential.helper store`, which writes tokens in plain text to `~/.git-credentials`.


## Line format

Before the git-config format, `accounts.conf` had one line per account. Such files are still read; a file whose first entry is a `[section]` header is read as git-config, anything else as lines:

```
alias|hostname|ssh_user|project_folder|git_name|git_email[|https_user[|ssh_key_type]]
    section.key = value
```

The fields match `host`, `sshUser`, `folder`, `name`, `email`, `httpsUser` and `sshKeyType` above; optional fields at the end can be left out, empty `ssh_user` means HTTPS only. Indented `section.key = value` lines below an account are its extra git settings. Both formats produce the same account configs, so switching only means rewriting `accounts.conf`.

### Git config in ~/.config/git

If your default `user.email` is set in `~/.config/git/config` (or `$XDG_CONFIG_HOME/git/config`) and `~/.gitconfig` has no `[user]` settings, the script leaves `~/.gitconfig` alone and keeps everything next to your config instead:

- `~/.config/git/host-<alias>.conf` instead of `~/.gitconfig-<alias>`
- the `includeIf` entries in `~/.config/git/hosts.conf`
- these lines appended once to the end of `~/.config/git/config`, after your default identity so the account configs win:

  ```ini
  [include]
      path = ~/.config/git/hosts.conf
  ```

## License

MIT – see [LICENSE](./LICENSE).

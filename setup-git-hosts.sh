#!/usr/bin/env bash
#
# setup-git-hosts.sh
#
# Automatically creates:
#   - an SSH key per configured account
#   - a GPG key per configured account (without passphrase, see warning below)
#   - directory-specific ~/.gitconfig-<alias> files with core.sshCommand,
#     GPG signing (user.signingkey, commit.gpgsign, tag.gpgsign) and - if an
#     HTTPS username is configured - credential.<url>.username
#   - includeIf entries in ~/.gitconfig
#   - a global credential.helper (only if none is configured yet), so that
#     HTTPS tokens are cached after the first prompt
#   - project directories under $PROJECT_BASE (default ~/projects), if missing
#
# Advantage of the SSH approach: you clone with the real host URL as usual
# (e.g. git@github.com:org/repo.git) - as long as the repo ends up in the
# right project directory, the correct key is used automatically.
#
# HTTPS: only the *username* is stored per account (never a password or
# token). Git asks for the password/token on the first push/fetch and the
# credential helper keeps it from then on.
#
# Protocols are chosen per account:
#   - SSH + HTTPS  -> ssh_user and https_user both set
#   - SSH only     -> https_user left out (7th field omitted/empty)
#   - HTTPS only   -> ssh_user left empty, e.g. "alias|github.com||folder|..."
#                     no SSH key is generated and no core.sshCommand written
# HTTPS_ONLY=1 forces HTTPS-only for every account in one go.
#
# GPG WARNING: the generated GPG keys are created WITHOUT a passphrase
# (%no-protection) so that the script can run fully unattended. This means
# the private key sits unprotected in your GPG keyring (~/.gnupg). Anyone
# with access to your user account can sign with it.
# To protect it afterwards:
#   gpg --edit-key <KEY-ID>
#   passwd
#
# IMPORTANT: accounts are loaded from an external file (default:
# accounts.conf in the same directory as this script; can be overridden via
# the first argument or $ACCOUNTS_FILE). See accounts.conf.example for the
# format.
#
# Usage:
#   chmod +x setup-git-hosts.sh
#   ./setup-git-hosts.sh                  # uses ./accounts.conf
#   ./setup-git-hosts.sh /path/to/accs    # uses a custom file
#   PROJECT_BASE=~/code ./setup-git-hosts.sh   # different base directory
#
# Environment variables:
#   PROJECT_BASE=~/code             base directory for project folders
#   ACCOUNTS_FILE=/path/accounts    accounts file (same as first argument)
#   HTTPS_ONLY=1                    no SSH at all: skip key generation and
#                                   core.sshCommand for every account
#                                   (requires an https_user per account)
#   CREDENTIAL_HELPER='cache --timeout=3600'
#                                   override the auto-detected credential
#                                   helper (default: osxkeychain on macOS,
#                                   libsecret/manager on Linux/Windows,
#                                   otherwise 'cache')
#   CREDENTIAL_CACHE_TIMEOUT=86400  timeout for the 'cache' fallback only
#   SETUP_CREDENTIAL_HELPER=0       never touch global credential.helper
#
# Afterwards you have to:
#   - add the generated SSH *.pub keys to the respective hosts
#   - add the generated GPG public keys to the respective hosts
#     (e.g. GitHub/GitLab Settings -> SSH and GPG keys)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNTS_FILE="${1:-${ACCOUNTS_FILE:-$SCRIPT_DIR/accounts.conf}}"

if [ ! -f "$ACCOUNTS_FILE" ]; then
  echo "ERROR: accounts file not found: $ACCOUNTS_FILE" >&2
  echo "Create an accounts.conf (see accounts.conf.example) or pass the path as an argument." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Format of each line in the accounts file:
#   alias|hostname|ssh_user|project_folder|git_name|git_email[|https_user]
#
# alias          -> internal identifier for the key filename & git config,
#                   e.g. github-work (does NOT appear in the clone URL)
# hostname       -> real hostname, e.g. github.com (used when cloning)
# ssh_user       -> usually "git"; leave EMPTY to disable SSH for this
#                   account (HTTPS only - no key is generated, no
#                   core.sshCommand is written)
# project_folder -> relative path under the project base directory
#                   ($PROJECT_BASE, default ~/projects), e.g. github-work
# git_name       -> name used in commits made in this directory
# git_email      -> e-mail used in commits made in this directory
# https_user     -> OPTIONAL: account/login name on that host, used for HTTPS
#                   remotes. Only the username is stored; the password/token
#                   is asked by git on the first push/fetch and then cached
#                   by the credential helper. Leave the field out (or empty)
#                   if you only ever use SSH.
#
# Each account needs at least one of ssh_user / https_user.
#
# Blank lines and lines starting with '#' are ignored.
# ---------------------------------------------------------------------------
ACCOUNTS=()
while IFS= read -r line || [ -n "$line" ]; do
  # Strip surrounding whitespace
  trimmed="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # Skip blank lines and comments
  [ -z "$trimmed" ] && continue
  case "$trimmed" in
    \#*) continue ;;
  esac
  field_count="$(awk -F'|' '{print NF}' <<< "$trimmed")"
  if [ "$field_count" -lt 6 ] || [ "$field_count" -gt 7 ]; then
    echo "ERROR: invalid line in $ACCOUNTS_FILE" >&2
    echo "  expected 6 or 7 '|'-separated fields, got $field_count:" >&2
    echo "  $trimmed" >&2
    exit 1
  fi
  ACCOUNTS+=("$trimmed")
done < "$ACCOUNTS_FILE"

if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  echo "ERROR: no accounts found in $ACCOUNTS_FILE." >&2
  exit 1
fi

PROJECT_BASE="${PROJECT_BASE:-$HOME/projects}"
SSH_DIR="$HOME/.ssh"
GITCONFIG_GLOBAL="$HOME/.gitconfig"

touch "$GITCONFIG_GLOBAL"

if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: 'gpg' not found. Please install GnuPG (e.g. 'apt install gnupg' or 'brew install gnupg') and run again." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: 'git' not found. Please install git and run again." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Credential helper for HTTPS remotes.
#
# The helper is what makes "type the token once" work: git asks for the
# password/token on the first HTTPS push/fetch and hands it to the helper,
# which returns it on every later request. Only the username lives in the
# git config - the token itself is kept by the helper (keychain/keyring or,
# with the 'cache' fallback, in memory for a limited time).
# ---------------------------------------------------------------------------
detect_credential_helper() {
  if [ -n "${CREDENTIAL_HELPER:-}" ]; then
    printf '%s' "$CREDENTIAL_HELPER"
    return
  fi
  case "$(uname -s)" in
    Darwin)
      printf 'osxkeychain'
      return
      ;;
    MINGW*|MSYS*|CYGWIN*)
      printf 'manager'
      return
      ;;
  esac
  if command -v git-credential-libsecret >/dev/null 2>&1 \
     || [ -x /usr/lib/git-core/git-credential-libsecret ] \
     || [ -x /usr/libexec/git-core/git-credential-libsecret ]; then
    printf 'libsecret'
    return
  fi
  if command -v git-credential-manager >/dev/null 2>&1; then
    printf 'manager'
    return
  fi
  printf 'cache --timeout=%s' "${CREDENTIAL_CACHE_TIMEOUT:-86400}"
}

CRED_HELPER="$(detect_credential_helper)"

# HTTPS_ONLY=1 disables SSH for *all* accounts, no matter what the accounts
# file says. Per account, SSH is disabled by leaving the ssh_user field empty.
HTTPS_ONLY="${HTTPS_ONLY:-0}"

# Validate the protocol combination and count how many accounts use SSH /
# HTTPS, so that SSH-only and HTTPS-only setups stay free of the other half.
SSH_ACCOUNTS=0
HTTPS_ACCOUNTS=0
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r e_alias e_hostname e_ssh_user e_folder e_name e_email e_https_user <<< "$entry"
  e_https_user="${e_https_user:-}"
  if [ "$HTTPS_ONLY" = "1" ]; then
    e_ssh_user=""
  fi
  if [ -z "$e_ssh_user" ] && [ -z "$e_https_user" ]; then
    echo "ERROR: account '$e_alias' has neither an ssh_user nor an https_user." >&2
    echo "  Set ssh_user (usually 'git') for SSH, https_user for HTTPS, or both." >&2
    if [ "$HTTPS_ONLY" = "1" ]; then
      echo "  Note: HTTPS_ONLY=1 disables SSH, so an https_user is required." >&2
    fi
    exit 1
  fi
  if [ -n "$e_ssh_user" ]; then
    SSH_ACCOUNTS=$((SSH_ACCOUNTS + 1))
  fi
  if [ -n "$e_https_user" ]; then
    HTTPS_ACCOUNTS=$((HTTPS_ACCOUNTS + 1))
  fi
done

# Only touch ~/.ssh if at least one account actually uses SSH.
if [ "$SSH_ACCOUNTS" -gt 0 ]; then
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
fi

echo "== Git multi-host setup (SSH / HTTPS + GPG) =="
if [ "$HTTPS_ONLY" = "1" ]; then
  echo "   HTTPS_ONLY=1: no SSH keys are generated or configured."
fi
echo

for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$entry"
  https_user="${https_user:-}"
  if [ "$HTTPS_ONLY" = "1" ]; then
    ssh_user=""
  fi

  key_path="$SSH_DIR/id_ed25519_${alias//-/_}"
  project_path="$PROJECT_BASE/$folder"
  gitconfig_path="$HOME/.gitconfig-$alias"

  echo "--- Account: $alias ---"

  # 1. Create the SSH key unless it already exists (skipped for HTTPS-only
  #    accounts - an existing key file is left alone, just not referenced)
  if [ -z "$ssh_user" ]; then
    echo "  SSH disabled for this account (HTTPS only)"
  elif [ -f "$key_path" ]; then
    echo "  SSH key already exists: $key_path (skipped)"
  else
    ssh-keygen -t ed25519 -C "$email" -f "$key_path" -N ""
    echo "  SSH key created: $key_path"
  fi

  # 2. Create a GPG key unless one already exists for this e-mail
  existing_fpr="$(gpg --list-secret-keys --with-colons --fingerprint "$email" 2>/dev/null \
                    | awk -F: '/^fpr:/ {print $10; exit}' || true)"

  if [ -n "$existing_fpr" ]; then
    gpg_fpr="$existing_fpr"
    echo "  GPG key already exists for $email (skipped): $gpg_fpr"
  else
    gpg_batch_file="$(mktemp)"
    cat > "$gpg_batch_file" <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Subkey-Type: ecdh
Subkey-Curve: cv25519
Subkey-Usage: encrypt
Name-Real: $name
Name-Email: $email
Expire-Date: 2y
%commit
EOF
    gpg --batch --generate-key "$gpg_batch_file" >/dev/null 2>&1
    rm -f "$gpg_batch_file"

    gpg_fpr="$(gpg --list-secret-keys --with-colons --fingerprint "$email" 2>/dev/null \
                 | awk -F: '/^fpr:/ {print $10; exit}' || true)"
    echo "  GPG key created for $email: $gpg_fpr"
  fi

  # 3. Create the project directory
  mkdir -p "$project_path"
  echo "  Directory ensured: $project_path"

  # 4. Write the directory-specific git config: identity + GPG signing, plus
  #    core.sshCommand and/or the HTTPS username depending on the account.
  cat > "$gitconfig_path" <<EOF
[user]
    name = $name
    email = $email
    signingkey = $gpg_fpr
EOF

  if [ -n "$ssh_user" ]; then
    cat >> "$gitconfig_path" <<EOF
[core]
    sshCommand = "ssh -i $key_path -o IdentitiesOnly=yes"
EOF
  fi

  cat >> "$gitconfig_path" <<EOF
[commit]
    gpgsign = true
[tag]
    gpgsign = true
EOF

  # 4b. HTTPS: store ONLY the username for this host. No password/token is
  #     ever written here - git asks for it once and the credential helper
  #     keeps it afterwards.
  if [ -n "$https_user" ]; then
    cat >> "$gitconfig_path" <<EOF
[credential "https://$hostname"]
    username = $https_user
EOF
    echo "  HTTPS username for $hostname: $https_user (token will be asked once)"
  fi

  echo "  Git config created: $gitconfig_path"

  # 5. Append the includeIf entry to ~/.gitconfig unless it is already there
  includeif_marker="gitdir:$project_path/"
  if grep -qF "$includeif_marker" "$GITCONFIG_GLOBAL" 2>/dev/null; then
    echo "  includeIf entry already exists (skipped)"
  else
    {
      echo ""
      echo "[includeIf \"gitdir:$project_path/\"]"
      echo "    path = $gitconfig_path"
    } >> "$GITCONFIG_GLOBAL"
    echo "  includeIf entry appended to ~/.gitconfig"
  fi

  echo
done

# ---------------------------------------------------------------------------
# Global credential.helper - deliberately NOT per account: the helper only
# says *where* credentials are kept, it holds no identity. The identity comes
# from credential.<url>.username in the per-directory config, so two accounts
# on the same host still get separate entries in the keychain/keyring.
# ---------------------------------------------------------------------------
CRED_HELPER_ACTIVE=""
if [ "$HTTPS_ACCOUNTS" -gt 0 ]; then
  existing_helper="$(git config --global --get-all credential.helper 2>/dev/null | head -n 1 || true)"
  if [ -n "$existing_helper" ]; then
    CRED_HELPER_ACTIVE="$existing_helper"
    echo "credential.helper already configured globally: $existing_helper (skipped)"
  elif [ "${SETUP_CREDENTIAL_HELPER:-1}" = "0" ]; then
    echo "credential.helper not configured (SETUP_CREDENTIAL_HELPER=0):"
    echo "  HTTPS tokens will be asked for on EVERY push until you set one, e.g.:"
    echo "  git config --global credential.helper '$CRED_HELPER'"
  else
    git config --global credential.helper "$CRED_HELPER"
    CRED_HELPER_ACTIVE="$CRED_HELPER"
    echo "credential.helper set globally: $CRED_HELPER"
  fi
  echo
fi

# Determine the system clipboard tool so that the hints below contain
# ready-to-copy commands (macOS: pbcopy, Wayland: wl-copy, X11: xclip).
if command -v pbcopy >/dev/null 2>&1; then
  CLIP_CMD="pbcopy"
elif command -v wl-copy >/dev/null 2>&1; then
  CLIP_CMD="wl-copy"
elif command -v xclip >/dev/null 2>&1; then
  CLIP_CMD="xclip -selection clipboard"
else
  CLIP_CMD=""
fi

echo "== Done =="
echo
echo "Next steps:"

# The step numbers depend on which protocols are actually in use.
STEP=0
step() {
  STEP=$((STEP + 1))
  echo "$STEP. $1"
}

if [ "$SSH_ACCOUNTS" -gt 0 ]; then
  step "Add the SSH public keys to the respective hosts (Settings -> SSH keys):"
  for entry in "${ACCOUNTS[@]}"; do
    IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$entry"
    if [ "$HTTPS_ONLY" = "1" ] || [ -z "$ssh_user" ]; then
      continue
    fi
    key_path="$SSH_DIR/id_ed25519_${alias//-/_}.pub"
    echo "   - $alias ($hostname): $key_path"
    echo "       show:  cat $key_path"
    if [ -n "$CLIP_CMD" ]; then
      echo "       copy:  $CLIP_CMD < $key_path"
    fi
  done
  echo
fi
step "Add the GPG public keys to the respective hosts (Settings -> GPG keys):"
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$entry"
  https_user="${https_user:-}"
  fpr="$(gpg --list-secret-keys --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' || true)"
  echo "   - $alias ($email):"
  echo "       show:  gpg --armor --export $fpr"
  if [ -n "$CLIP_CMD" ]; then
    echo "       copy:  gpg --armor --export $fpr | $CLIP_CMD"
  fi
done
echo
if [ -n "$CLIP_CMD" ]; then
  echo "   (Clipboard tool detected: $CLIP_CMD - alternatives: macOS 'pbcopy',"
  echo "    Linux/Wayland 'wl-copy', Linux/X11 'xclip -selection clipboard')"
else
  echo "   (No clipboard tool found. To install one:"
  echo "    macOS 'pbcopy' (preinstalled), Linux/Wayland 'wl-clipboard', Linux/X11 'xclip'."
  echo "    Then e.g.: xclip -selection clipboard < <pubkey-file>)"
fi
echo
echo "   Note: only share the .pub files or the output of 'gpg --armor --export'."
echo "   'gpg --armor --export-secret-keys' exports the PRIVATE key -"
echo "   that one stays local (see the passphrase warning at the top of this script)."
echo
if [ "$SSH_ACCOUNTS" -gt 0 ]; then
  step "Test the SSH connection, e.g.:"
  for entry in "${ACCOUNTS[@]}"; do
    IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$entry"
    if [ "$HTTPS_ONLY" = "1" ] || [ -z "$ssh_user" ]; then
      continue
    fi
    key_path="$SSH_DIR/id_ed25519_${alias//-/_}"
    echo "   ssh -i $key_path -T $ssh_user@$hostname"
  done
  echo
fi
step "Clone repos with the real host URL as usual (no alias needed)."
echo "   Note: includeIf entries only match once a repo exists, so during the"
echo "   clone itself the per-account config is not active yet - that is why"
echo "   the SSH key / HTTPS username is passed explicitly below. Everything"
echo "   after the clone (fetch, push, commit) picks it up automatically."
echo
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$entry"
  https_user="${https_user:-}"
  if [ "$HTTPS_ONLY" = "1" ]; then
    ssh_user=""
  fi
  key_path="$SSH_DIR/id_ed25519_${alias//-/_}"
  echo "   - $alias -> $PROJECT_BASE/$folder/repo"
  if [ -n "$ssh_user" ]; then
    echo "       SSH:    git -c core.sshCommand=\"ssh -i $key_path -o IdentitiesOnly=yes\" \\"
    echo "                   clone $ssh_user@$hostname:org/repo.git $PROJECT_BASE/$folder/repo"
  fi
  if [ -n "$https_user" ]; then
    echo "       HTTPS:  git clone https://$https_user@$hostname/org/repo.git $PROJECT_BASE/$folder/repo"
  elif [ "$HTTPS_ONLY" != "1" ]; then
    echo "       HTTPS:  not configured (add a 7th field 'https_user' in $(basename "$ACCOUNTS_FILE"))"
  fi
done
echo
if [ "$HTTPS_ACCOUNTS" -gt 0 ]; then
  step "HTTPS credentials:"
  echo "   - Only the username is stored (credential.https://<host>.username in"
  echo "     ~/.gitconfig-<alias>). No password or token is written to any file"
  echo "     by this script."
  echo "   - On the first push/fetch git asks for the password. Use a personal"
  echo "     access token there, not your account password:"
  echo "       GitHub: Settings -> Developer settings -> Personal access tokens"
  echo "               (classic: scope 'repo', or a fine-grained token with"
  echo "                Contents: read/write)"
  echo "       GitLab: Settings -> Access tokens (scope 'write_repository')"
  echo "       Gitea:  Settings -> Applications -> Generate token"
  if [ -n "$CRED_HELPER_ACTIVE" ]; then
    echo "   - The token is then kept by the credential helper '$CRED_HELPER_ACTIVE',"
    echo "     so you only type it once per account."
  fi
  echo "   - Inside a project directory, check the username that will be used:"
  echo "       git config credential.https://<host>.username"
  echo "   - Test access without cloning (asks for the token once):"
  echo "       git ls-remote https://<user>@<host>/org/repo.git"
  echo "   - To replace a stored token, just erase it and push again:"
  echo "       printf 'protocol=https\\nhost=<host>\\nusername=<user>\\n\\n' | git credential reject"
  echo
fi
step "Inside a project directory, verify that identity and signing are active:"
echo "   cd $PROJECT_BASE/<folder>/repo"
echo "   git config user.email"
echo "   git config user.signingkey"
echo "   git config commit.gpgsign"
if [ "$SSH_ACCOUNTS" -gt 0 ]; then
  echo "   git config core.sshCommand                          # SSH accounts"
fi
if [ "$HTTPS_ACCOUNTS" -gt 0 ]; then
  echo "   git config credential.https://<host>.username       # HTTPS accounts"
fi
echo
step "Verify a signed test commit:"
echo "   git commit --allow-empty -m 'test signed commit'"
echo "   git log --show-signature -1"

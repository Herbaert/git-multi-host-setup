#!/usr/bin/env bash
#
# setup-git-hosts.sh
#
# Automatically creates:
#   - an SSH key per configured account
#   - a GPG key per configured account (without passphrase, see warning below)
#   - directory-specific ~/.gitconfig-<alias> files with core.sshCommand
#     and GPG signing (user.signingkey, commit.gpgsign, tag.gpgsign)
#   - includeIf entries in ~/.gitconfig
#   - project directories under $PROJECT_BASE (default ~/projects), if missing
#
# Advantage of the SSH approach: you clone with the real host URL as usual
# (e.g. git@github.com:org/repo.git) - as long as the repo ends up in the
# right project directory, the correct key is used automatically.
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
#   alias|hostname|ssh_user|project_folder|git_name|git_email
#
# alias          -> internal identifier for the key filename & git config,
#                   e.g. github-work (does NOT appear in the clone URL)
# hostname       -> real hostname, e.g. github.com (used when cloning)
# ssh_user       -> usually "git" (currently informational only, no longer
#                   needed for the SSH config)
# project_folder -> relative path under the project base directory
#                   ($PROJECT_BASE, default ~/projects), e.g. github-work
# git_name       -> name used in commits made in this directory
# git_email      -> e-mail used in commits made in this directory
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
  ACCOUNTS+=("$trimmed")
done < "$ACCOUNTS_FILE"

if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  echo "ERROR: no accounts found in $ACCOUNTS_FILE." >&2
  exit 1
fi

PROJECT_BASE="${PROJECT_BASE:-$HOME/projects}"
SSH_DIR="$HOME/.ssh"
GITCONFIG_GLOBAL="$HOME/.gitconfig"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$GITCONFIG_GLOBAL"

if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: 'gpg' not found. Please install GnuPG (e.g. 'apt install gnupg' or 'brew install gnupg') and run again." >&2
  exit 1
fi

echo "== Git/SSH/GPG multi-host setup =="
echo

for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email <<< "$entry"

  key_path="$SSH_DIR/id_ed25519_${alias//-/_}"
  project_path="$PROJECT_BASE/$folder"
  gitconfig_path="$HOME/.gitconfig-$alias"

  echo "--- Account: $alias ---"

  # 1. Create the SSH key unless it already exists
  if [ -f "$key_path" ]; then
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

  # 4. Write the directory-specific git config (incl. core.sshCommand + GPG signing)
  cat > "$gitconfig_path" <<EOF
[user]
    name = $name
    email = $email
    signingkey = $gpg_fpr
[core]
    sshCommand = "ssh -i $key_path -o IdentitiesOnly=yes"
[commit]
    gpgsign = true
[tag]
    gpgsign = true
EOF
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
echo "1. Add the SSH public keys to the respective hosts (Settings -> SSH keys):"
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email <<< "$entry"
  key_path="$SSH_DIR/id_ed25519_${alias//-/_}.pub"
  echo "   - $alias ($hostname): $key_path"
  echo "       show:  cat $key_path"
  if [ -n "$CLIP_CMD" ]; then
    echo "       copy:  $CLIP_CMD < $key_path"
  fi
done
echo
echo "2. Add the GPG public keys to the respective hosts (Settings -> GPG keys):"
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email <<< "$entry"
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
echo "3. Test the SSH connection, e.g.:"
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email <<< "$entry"
  key_path="$SSH_DIR/id_ed25519_${alias//-/_}"
  echo "   ssh -i $key_path -T $ssh_user@$hostname"
done
echo
echo "4. Clone repos with the real host URL as usual (no alias needed),"
echo "   e.g.:"
for entry in "${ACCOUNTS[@]}"; do
  IFS='|' read -r alias hostname ssh_user folder name email <<< "$entry"
  echo "   git clone $ssh_user@$hostname:org/repo.git $PROJECT_BASE/$folder/repo"
done
echo
echo "5. Inside a project directory, verify that identity, SSH key and signing are active:"
echo "   cd $PROJECT_BASE/<folder>/repo"
echo "   git config user.email"
echo "   git config core.sshCommand"
echo "   git config user.signingkey"
echo "   git config commit.gpgsign"
echo
echo "6. Verify a signed test commit:"
echo "   git commit --allow-empty -m 'test signed commit'"
echo "   git log --show-signature -1"

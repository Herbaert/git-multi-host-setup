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
#
# GPG WARNING: the generated GPG keys are created WITHOUT a passphrase
# (%no-protection) so that the script can run fully unattended. This means
# the private key sits unprotected in your GPG keyring (~/.gnupg). Anyone
# with access to your user account can sign with it.
# Run with GPG_PASSPHRASE=1 to be asked for one instead.
# To protect it afterwards:
#   gpg --edit-key <KEY-ID>
#   passwd
#
# IMPORTANT: accounts are loaded from an external file (default:
# accounts.conf in the same directory as this script; can be overridden via
# the first argument or $ACCOUNTS_FILE). See accounts.conf.example for the
# format.
#
# Re-running it after editing the accounts file performs an UPDATE: the
# script compares the current state (~/.gitconfig-<alias> files and the
# includeIf entries in ~/.gitconfig) against the accounts file and reports
# every difference it applies - changed e-mail, renamed project folder,
# added/removed HTTPS username, accounts that disappeared from the file.
# Use DRY_RUN=1 to see the diff without changing anything.
#
# Usage:
#   chmod +x setup-git-hosts.sh
#   ./setup-git-hosts.sh                  # uses ./accounts.conf
#   ./setup-git-hosts.sh /path/to/accs    # uses a custom file
#   PROJECT_BASE=~/code ./setup-git-hosts.sh   # different base directory
#   DRY_RUN=1 ./setup-git-hosts.sh        # only show what would change
#
# Environment variables:
#   PROJECT_BASE=~/code             base directory for project folders
#   ACCOUNTS_FILE=/path/accounts    accounts file (same as first argument)
#   DRY_RUN=1                       change nothing, only report the diff
#                                   between current state and accounts file
#   PRUNE=1                         also remove leftovers of accounts that
#                                   are no longer in the accounts file
#                                   (git configs + includeIf entries; SSH
#                                   and GPG keys are never deleted).
#                                   Hand-written ~/.gitconfig-* files stay.
#   CREDENTIAL_HELPER='cache --timeout=3600'
#                                   override the auto-detected credential
#                                   helper (default: osxkeychain on macOS,
#                                   libsecret/manager on Linux/Windows,
#                                   otherwise 'cache')
#   CREDENTIAL_CACHE_TIMEOUT=86400  timeout for the 'cache' fallback only
#   SETUP_CREDENTIAL_HELPER=0       never touch global credential.helper
#   GPG_PASSPHRASE=1                protect newly created GPG keys with a
#                                   passphrase (asked by gpg, needs a terminal)
#
# Afterwards you have to:
#   - add the generated SSH *.pub keys to the respective hosts
#   - add the generated GPG public keys to the respective hosts
#     (e.g. GitHub/GitLab Settings -> SSH and GPG keys)

set -euo pipefail

# Rendered configs hold name, e-mail and fingerprint, so temp files must not
# outlive an aborted run.
TMP_FILES=()
trap 'rm -f ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNTS_FILE="${1:-${ACCOUNTS_FILE:-$SCRIPT_DIR/accounts.conf}}"

if [ ! -f "$ACCOUNTS_FILE" ]; then
  echo "ERROR: accounts file not found: $ACCOUNTS_FILE" >&2
  echo "Create an accounts.conf (see accounts.conf.example) or pass the path as an argument." >&2
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"
PRUNE="${PRUNE:-0}"

PROJECT_BASE="${PROJECT_BASE:-$HOME/projects}"
SSH_DIR="$HOME/.ssh"
GITCONFIG_GLOBAL="$HOME/.gitconfig"

# Single choke point for writes, so a dry run cannot write by accident.
apply() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  WOULD run: $*"
    return 0
  fi
  "$@"
}

# git matches gitdir against the resolved path, so symlinks must be resolved here.
real_path() {
  local dir="$1" rest=""
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    dir="$(dirname "$dir")"
  done
  printf '%s%s' "$(cd "$dir" && pwd -P)" "$rest"
}

# '-' becomes '_', so the accounts check rejects aliases that collide here.
ssh_key_path() {
  printf '%s' "$SSH_DIR/id_ed25519_${1//-/_}"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Sets globals on purpose. Each field is trimmed because " github.com" would
# only fail at push time.
parse_entry() {
  IFS='|' read -r alias hostname ssh_user folder name email https_user <<< "$1"
  alias="$(trim "$alias")"
  hostname="$(trim "$hostname")"
  ssh_user="$(trim "$ssh_user")"
  folder="$(trim "$folder")"
  # "work", "work/" and "./work" are one folder, and gitdir must never end in "//".
  while [[ "$folder" == ./* ]]; do folder="${folder#./}"; done
  while [[ "$folder" == *//* ]]; do folder="${folder//\/\//\/}"; done
  while [[ "$folder" == */ ]]; do folder="${folder%/}"; done
  name="$(trim "$name")"
  email="$(trim "$email")"
  https_user="$(trim "${https_user:-}")"
}

# gpg_fpr_for_email <email> [usable|expired]
# The angle brackets force an exact match. A bare address also matches other user IDs.
gpg_fpr_for_email() {
  gpg --list-secret-keys --with-colons --fingerprint "<$1>" 2>/dev/null \
    | awk -F: -v want="${2:-usable}" '
        $1 == "sec" {
          if (want == "expired") pick = ($2 == "e")
          else pick = ($2 != "e" && $2 != "r" && $2 != "i" && $2 != "d")
          next
        }
        $1 == "fpr" && pick { print $10; exit }
      ' || true
}

# pinentry-curses needs 14 rows and below that fails with "Screen or window too
# small". pinentry-mac opens its own window.
pinentry_fits() {
  local rows
  grep -qs '^[[:space:]]*pinentry-program.*pinentry-mac' "${GNUPGHOME:-$HOME/.gnupg}/gpg-agent.conf" && return 0
  rows="$(stty size 2>/dev/null)"
  [ "${rows%% *}" -ge 14 ] 2>/dev/null
}

# extend_key <fpr> [interactive]
extend_key() {
  local opts=(--batch --pinentry-mode loopback --passphrase '') err=/dev/null
  if [ "${2:-}" = "interactive" ]; then
    opts=()
    err=/dev/stderr
    echo "  GPG key $1 is protected - gpg will ask for its passphrase"
  fi
  gpg ${opts[@]+"${opts[@]}"} --quick-set-expire "$1" 2y >/dev/null 2>"$err" \
    && gpg ${opts[@]+"${opts[@]}"} --quick-set-expire "$1" 2y '*' >/dev/null 2>"$err"
}

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
SEEN_ALIASES=()
SEEN_FOLDERS=()
SEEN_KEYS=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  # Strip surrounding whitespace
  trimmed="$(trim "$line")"
  # Skip blank lines and comments
  [ -z "$trimmed" ] && continue
  case "$trimmed" in
    \#*) continue ;;
  esac
  field_count="$(awk -F'|' '{print NF}' <<< "$trimmed")"
  if [ "$field_count" -lt 6 ] || [ "$field_count" -gt 7 ]; then
    echo "ERROR: invalid line $lineno in $ACCOUNTS_FILE" >&2
    echo "  expected 6 or 7 '|'-separated fields, got $field_count:" >&2
    echo "  $trimmed" >&2
    exit 1
  fi
  parse_entry "$trimmed"

  missing=""
  [ -n "$alias" ]    || missing+=" alias"
  [ -n "$hostname" ] || missing+=" hostname"
  [ -n "$folder" ]   || missing+=" project_folder"
  [ -n "$name" ]     || missing+=" git_name"
  [ -n "$email" ]    || missing+=" git_email"
  if [ -n "$missing" ]; then
    echo "ERROR: line $lineno in $ACCOUNTS_FILE has empty required field(s):$missing" >&2
    echo "  $trimmed" >&2
    exit 1
  fi
  case "$alias" in
    *[!A-Za-z0-9._-]*|.*)
      echo "ERROR: line $lineno in $ACCOUNTS_FILE has an unusable alias '$alias'." >&2
      echo "  The alias becomes a filename (~/.gitconfig-<alias>); allowed are" >&2
      echo "  letters, digits, '.', '_' and '-', and it must not start with '.'." >&2
      exit 1
      ;;
  esac
  if contains "$alias" ${SEEN_ALIASES[@]+"${SEEN_ALIASES[@]}"}; then
    echo "ERROR: line $lineno in $ACCOUNTS_FILE reuses the alias '$alias'." >&2
    echo "  Both accounts would share ~/.gitconfig-$alias and overwrite each other." >&2
    exit 1
  fi
  if contains "$folder" ${SEEN_FOLDERS[@]+"${SEEN_FOLDERS[@]}"}; then
    echo "ERROR: line $lineno in $ACCOUNTS_FILE reuses the project_folder '$folder'." >&2
    echo "  A project directory can only map to one account - give '$alias' its own folder." >&2
    exit 1
  fi
  key_file="$(ssh_key_path "$alias")"
  for i in ${SEEN_KEYS[@]+"${!SEEN_KEYS[@]}"}; do
    if [ "${SEEN_KEYS[i]}" = "$key_file" ]; then
      echo "ERROR: line $lineno in $ACCOUNTS_FILE: alias '$alias' and alias '${SEEN_ALIASES[i]}'" >&2
      echo "  map to the same SSH key file $key_file ('-' becomes '_')," >&2
      echo "  so the second account would silently reuse the first one's key." >&2
      exit 1
    fi
  done
  SEEN_ALIASES+=("$alias")
  SEEN_FOLDERS+=("$folder")
  SEEN_KEYS+=("$key_file")

  ACCOUNTS+=("$trimmed")
done < "$ACCOUNTS_FILE"

if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  echo "ERROR: no accounts found in $ACCOUNTS_FILE." >&2
  exit 1
fi

# PRUNE deletes only files starting with this line. It names the alias, so a
# copied backup such as .gitconfig-work.bak does not match its own filename.
config_marker() {
  printf '# managed by setup-git-hosts.sh (alias: %s) - do not edit, it is regenerated' "$1"
}

has_marker() {   # has_marker <file> <alias>
  [ -f "$1" ] && [ "$(head -n 1 "$1")" = "$(config_marker "$2")" ]
}

is_managed_config() {
  local suffix="${1##*/.gitconfig-}"
  has_marker "$1" "$suffix"
}

# Built before the main loop, which must not flag a folder another current
# account is handing over in the same run.
KNOWN_CONFIGS=()
for entry in "${ACCOUNTS[@]}"; do
  parse_entry "$entry"
  KNOWN_CONFIGS+=("$HOME/.gitconfig-$alias")
done

is_known_config() {
  contains "$1" ${KNOWN_CONFIGS[@]+"${KNOWN_CONFIGS[@]}"}
}

if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: 'gpg' not found. Please install GnuPG (e.g. 'apt install gnupg' or 'brew install gnupg') and run again." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: 'git' not found. Please install git and run again." >&2
  exit 1
fi

# pinentry cannot find the terminal on its own.
if [ -t 0 ]; then
  GPG_TTY="$(tty)"
  export GPG_TTY
fi

GPG_PASSPHRASE="${GPG_PASSPHRASE:-0}"
GPG_PROTECTION="%no-protection"
if [ "$GPG_PASSPHRASE" = "1" ]; then
  GPG_PROTECTION=""
  if [ ! -t 0 ] && [ "$DRY_RUN" != "1" ]; then
    echo "ERROR: GPG_PASSPHRASE=1 needs a terminal, gpg asks for the passphrase there." >&2
    exit 1
  fi
  if [ -t 0 ] && [ "$DRY_RUN" != "1" ] && ! pinentry_fits; then
    echo "ERROR: the terminal is too small for gpg's passphrase dialog." >&2
    echo "  Make it at least 14 rows high and run again." >&2
    exit 1
  fi
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

# ---------------------------------------------------------------------------
# Update detection
#
# The accounts file is the desired state, the files on disk are the current
# state. Every account is rendered into a temporary config first, compared
# against what is already there, and the differences are reported key by key
# before they are applied (or, with DRY_RUN=1, instead of applying them).
# ---------------------------------------------------------------------------
CREATED=0
UPDATED=0
UNCHANGED=0
REMAPPED=0        # includeIf entries added or moved to another project folder
CHANGE_HINTS=()   # collected notes about things the script does not fix itself

# All keys of a git config file, one per line (git normalises them to
# lowercase, e.g. credential.https://github.com.username).
config_keys() {
  [ -f "$1" ] || return 0
  git config --file "$1" --list 2>/dev/null | cut -d= -f1 | sort -u
}

# Print every key whose value differs between two config files.
# Returns 0 if the files are equivalent, 1 if anything differs.
report_config_diff() {
  local old="$1" new="$2" indent="$3"
  local changed=0 key old_val new_val

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    old_val="$(git config --file "$old" --get "$key" 2>/dev/null || true)"
    new_val="$(git config --file "$new" --get "$key" 2>/dev/null || true)"
    [ "$old_val" = "$new_val" ] && continue
    changed=1
    if [ -z "$old_val" ]; then
      echo "$indent+ $key = $new_val"
    elif [ -z "$new_val" ]; then
      echo "$indent- $key (was: $old_val)"
    else
      echo "$indent~ $key: $old_val -> $new_val"
    fi
  done < <( { config_keys "$old"; config_keys "$new"; } | sort -u )

  return $changed
}

# Every includeIf entry as "<gitdir>\t<config path>". -z because gitdirs may
# contain spaces, which break the key/value split.
includeif_entries() {
  local record key value
  while IFS= read -r -d '' record; do
    [ -z "$record" ] && continue
    key="${record%%$'\n'*}"
    value="${record#*$'\n'}"
    key="${key#includeif.gitdir:}"
    printf '%s\t%s\n' "${key%.path}" "$value"
  done < <(git config --file "$GITCONFIG_GLOBAL" --get-regexp -z '^includeif\.gitdir:' 2>/dev/null || true)
}

# includeif_lookup gitdirs-for <config path> | configs-for <gitdir>
# Re-reads ~/.gitconfig on every call because the main loop modifies it.
includeif_lookup() {
  local mode="$1" want="$2" entry gitdir cfg
  while IFS= read -r entry; do
    gitdir="${entry%%$'\t'*}"
    cfg="${entry#*$'\t'}"
    case "$mode" in
      gitdirs-for) [ "$cfg" = "$want" ]    && printf '%s\n' "$gitdir" ;;
      configs-for) [ "$gitdir" = "$want" ] && printf '%s\n' "$cfg" ;;
    esac
  done < <(includeif_entries)
  return 0
}

# Hand-rolled because --fixed-value needs git 2.30.
regex_escape() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '.'|'['|']'|\\|'('|')'|'*'|'+'|'?'|'{'|'}'|'|'|'^'|'$') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Removes only the entry for this config. --remove-section would also drop
# another account's entry for the same gitdir.
remove_includeif() {
  local gitdir="$1" cfg_path="$2"
  git config --file "$GITCONFIG_GLOBAL" --unset-all \
    "includeIf.gitdir:$gitdir.path" "^$(regex_escape "$cfg_path")\$" 2>/dev/null || true
}

# Validate the protocol combination and count how many accounts use SSH /
# HTTPS, so that SSH-only and HTTPS-only setups stay free of the other half.
SSH_ACCOUNTS=0
HTTPS_ACCOUNTS=0
for entry in "${ACCOUNTS[@]}"; do
  parse_entry "$entry"
  if [ -z "$ssh_user" ] && [ -z "$https_user" ]; then
    echo "ERROR: account '$alias' has neither an ssh_user nor an https_user." >&2
    echo "  Set ssh_user (usually 'git') for SSH, https_user for HTTPS, or both." >&2
    exit 1
  fi
  if [ -n "$ssh_user" ]; then
    SSH_ACCOUNTS=$((SSH_ACCOUNTS + 1))
  fi
  if [ -n "$https_user" ]; then
    HTTPS_ACCOUNTS=$((HTTPS_ACCOUNTS + 1))
  fi
done

echo "== Git multi-host setup (SSH / HTTPS + GPG) =="
if [ "$DRY_RUN" = "1" ]; then
  echo "   DRY_RUN=1: nothing is written, only the pending changes are shown."
fi
echo "   Accounts file: $ACCOUNTS_FILE"

# Guarded so a dry run lists only pending writes. Creating ~/.gitconfig on an
# XDG-only setup would redirect every future global write.
[ -e "$GITCONFIG_GLOBAL" ] || apply touch "$GITCONFIG_GLOBAL"

# Only touch ~/.ssh if at least one account actually uses SSH.
if [ "$SSH_ACCOUNTS" -gt 0 ]; then
  [ -d "$SSH_DIR" ] || apply mkdir -p "$SSH_DIR"
  if [ -z "$(find "$SSH_DIR" -maxdepth 0 -perm 700 2>/dev/null)" ]; then
    apply chmod 700 "$SSH_DIR"
  fi
fi
echo

ACCOUNT_FPRS=()   # GPG fingerprint per account, same order as ACCOUNTS

for entry in "${ACCOUNTS[@]}"; do
  parse_entry "$entry"

  key_path="$(ssh_key_path "$alias")"
  project_path="$(real_path "$PROJECT_BASE/$folder")"
  gitconfig_path="$HOME/.gitconfig-$alias"

  echo "--- Account: $alias ---"

  # 1. Create the SSH key unless it already exists (skipped for HTTPS-only
  #    accounts - an existing key file is left alone, just not referenced)
  if [ -z "$ssh_user" ]; then
    echo "  SSH disabled for this account (HTTPS only)"
  elif [ -f "$key_path" ]; then
    echo "  SSH key already exists: $key_path (skipped)"
  elif [ "$DRY_RUN" = "1" ]; then
    echo "  SSH key WOULD BE created: $key_path"
  else
    ssh-keygen -t ed25519 -C "$email" -f "$key_path" -N ""
    echo "  SSH key created: $key_path"
  fi

  # 2. Reuse a usable GPG key, extend an expired one, otherwise create one.
  existing_fpr="$(gpg_fpr_for_email "$email")"
  expired_fpr=""
  [ -n "$existing_fpr" ] || expired_fpr="$(gpg_fpr_for_email "$email" expired)"
  show_fpr="$existing_fpr"   # what "Next steps" prints; empty = no key yet

  if [ -n "$existing_fpr" ]; then
    gpg_fpr="$existing_fpr"
    echo "  GPG key already exists for $email (skipped): $gpg_fpr"
  elif [ -n "$expired_fpr" ]; then
    # Extending keeps the fingerprint the forge already knows. A new key would
    # make every commit show as "Unverified". Revoked keys get a new key below.
    gpg_fpr="$expired_fpr"
    show_fpr="$expired_fpr"
    extend_cmd="gpg --quick-set-expire $expired_fpr 2y && gpg --quick-set-expire $expired_fpr 2y '*'"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  GPG key for $email is EXPIRED and WOULD BE extended by 2 years: $gpg_fpr"
    elif { extend_key "$expired_fpr" \
           || { [ -t 0 ] && pinentry_fits && extend_key "$expired_fpr" interactive; }; } \
         && [ "$(gpg_fpr_for_email "$email")" = "$expired_fpr" ]; then
      echo "  GPG key for $email was expired - extended by 2 years: $gpg_fpr"
      CHANGE_HINTS+=("$alias: GPG key $gpg_fpr was extended - re-upload its public key to $hostname, the copy there still shows the old expiry")
    else
      # Rotating to a new key is the user's call.
      echo "  GPG key for $email is EXPIRED and could not be extended automatically: $gpg_fpr"
      if [ -t 0 ] && ! pinentry_fits; then
        echo "  (the terminal is too small for gpg's passphrase dialog, it needs 14 rows)"
      fi
      CHANGE_HINTS+=("$alias: GPG key $gpg_fpr has expired, commits cannot be signed - extend it with: $extend_cmd (then re-upload the public key to $hostname)")
    fi
  elif [ "$DRY_RUN" = "1" ]; then
    gpg_fpr="<new key for $email>"
    echo "  GPG key WOULD BE created for $email"
  else
    gpg_batch_file="$(mktemp)"; TMP_FILES+=("$gpg_batch_file")
    gpg_err_file="$(mktemp)"; TMP_FILES+=("$gpg_err_file")
    cat > "$gpg_batch_file" <<EOF
$GPG_PROTECTION
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
    if ! gpg --batch --generate-key "$gpg_batch_file" >/dev/null 2>"$gpg_err_file"; then
      echo "ERROR: gpg could not create a key for $email:" >&2
      sed 's/^/  /' "$gpg_err_file" >&2
      rm -f "$gpg_batch_file" "$gpg_err_file"
      exit 1
    fi
    rm -f "$gpg_batch_file" "$gpg_err_file"

    # gpg can exit 0 without creating a key. An empty signingkey would break every
    # commit and read as "unchanged" on the next run.
    gpg_fpr="$(gpg_fpr_for_email "$email")"
    if [ -z "$gpg_fpr" ]; then
      echo "ERROR: gpg reported success but no usable secret key exists for $email." >&2
      echo "  Check that gpg-agent can start ('gpg --batch --generate-key' by hand)" >&2
      echo "  and run again. $gitconfig_path was left untouched." >&2
      exit 1
    fi
    echo "  GPG key created for $email: $gpg_fpr"
    show_fpr="$gpg_fpr"
  fi
  ACCOUNT_FPRS+=("$show_fpr")

  # 3. Create the project directory
  if [ -d "$project_path" ]; then
    echo "  Directory ensured: $project_path"
  elif [ "$DRY_RUN" = "1" ]; then
    echo "  Directory WOULD BE created: $project_path"
  else
    mkdir -p "$project_path"
    echo "  Directory created: $project_path"
  fi

  # 4. Render the desired directory-specific git config (identity + GPG
  #    signing, plus core.sshCommand and/or the HTTPS username) into a
  #    temporary file, so it can be compared against what is already there.
  desired_cfg="$(mktemp)"; TMP_FILES+=("$desired_cfg")
  cat > "$desired_cfg" <<EOF
$(config_marker "$alias")
[user]
    name = $name
    email = $email
    signingkey = $gpg_fpr
EOF

  if [ -n "$ssh_user" ]; then
    cat >> "$desired_cfg" <<EOF
[core]
    sshCommand = "ssh -i $key_path -o IdentitiesOnly=yes"
EOF
  fi

  cat >> "$desired_cfg" <<EOF
[commit]
    gpgsign = true
[tag]
    gpgsign = true
EOF

  # 4b. HTTPS: store ONLY the username for this host. No password/token is
  #     ever written here - git asks for it once and the credential helper
  #     keeps it afterwards.
  if [ -n "$https_user" ]; then
    cat >> "$desired_cfg" <<EOF
[credential "https://$hostname"]
    username = $https_user
EOF
  fi

  # 4c. Compare current against desired and report every difference.
  if [ ! -f "$gitconfig_path" ]; then
    CREATED=$((CREATED + 1))
    if [ "$DRY_RUN" = "1" ]; then
      echo "  Git config WOULD BE created: $gitconfig_path"
    else
      cat "$desired_cfg" > "$gitconfig_path"
      echo "  Git config created: $gitconfig_path"
    fi
    report_config_diff /dev/null "$desired_cfg" "      " || true
  elif report_config_diff "$gitconfig_path" "$desired_cfg" "      "; then
    UNCHANGED=$((UNCHANGED + 1))
    # The marker is invisible to the value diff, so older configs would never get it.
    if has_marker "$gitconfig_path" "$alias"; then
      echo "  Git config unchanged: $gitconfig_path"
    elif [ "$DRY_RUN" = "1" ]; then
      echo "  Git config unchanged, marker line WOULD BE added: $gitconfig_path"
    else
      cat "$desired_cfg" > "$gitconfig_path"
      echo "  Git config unchanged (marker line added): $gitconfig_path"
    fi
  else
    UPDATED=$((UPDATED + 1))
    if [ "$DRY_RUN" = "1" ]; then
      echo "  Git config WOULD BE updated (changes above): $gitconfig_path"
    else
      cat "$desired_cfg" > "$gitconfig_path"
      echo "  Git config updated (changes above): $gitconfig_path"
    fi
  fi
  rm -f "$desired_cfg"

  # 5. Map the project directory to that config via includeIf. If the config
  #    is already mapped to a *different* gitdir, the project folder was
  #    renamed in the accounts file - move the entry instead of adding a
  #    second one that would still match the old directory.
  desired_gitdir="$project_path/"
  mapped_gitdirs=()
  while IFS= read -r g; do
    [ -n "$g" ] && mapped_gitdirs+=("$g")
  done < <(includeif_lookup gitdirs-for "$gitconfig_path")

  already_mapped=0
  for g in ${mapped_gitdirs[@]+"${mapped_gitdirs[@]}"}; do
    [ "$g" = "$desired_gitdir" ] && already_mapped=1
  done

  # A current account's entry is a handover that its own pass removes later.
  # Anything else is a leftover worth reporting.
  while IFS= read -r other_cfg; do
    [ -z "$other_cfg" ] && continue
    [ "$other_cfg" = "$gitconfig_path" ] && continue
    is_known_config "$other_cfg" && continue
    if is_managed_config "$other_cfg" || [ ! -e "$other_cfg" ]; then
      fix="run with PRUNE=1"
    else
      fix="remove that [includeIf] section from ~/.gitconfig by hand"
    fi
    CHANGE_HINTS+=("$alias: $desired_gitdir is also mapped to $other_cfg - $fix so the right config always wins")
  done < <(includeif_lookup configs-for "$desired_gitdir")

  if [ "$already_mapped" = "1" ]; then
    echo "  includeIf entry already exists (skipped)"
  elif [ "$DRY_RUN" = "1" ]; then
    REMAPPED=$((REMAPPED + 1))
    echo "  includeIf entry WOULD BE added: gitdir:$desired_gitdir"
  else
    {
      echo ""
      echo "[includeIf \"gitdir:$desired_gitdir\"]"
      echo "    path = $gitconfig_path"
    } >> "$GITCONFIG_GLOBAL"
    REMAPPED=$((REMAPPED + 1))
    echo "  includeIf entry appended to ~/.gitconfig: gitdir:$desired_gitdir"
  fi

  # Any other gitdir pointing at this config is stale (renamed folder or a
  # duplicate from an earlier run) and would keep matching the old path.
  for g in ${mapped_gitdirs[@]+"${mapped_gitdirs[@]}"}; do
    [ "$g" = "$desired_gitdir" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      echo "  stale includeIf entry WOULD BE removed: gitdir:$g"
    else
      remove_includeif "$g" "$gitconfig_path"
      echo "  stale includeIf entry removed: gitdir:$g"
    fi
    if [ -d "${g%/}" ] && ! [ "${g%/}" -ef "$project_path" ]; then
      CHANGE_HINTS+=("$alias: old project directory ${g%/} still exists - move its repos to $project_path or delete it")
    fi
  done

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
  elif [ "$DRY_RUN" = "1" ]; then
    CRED_HELPER_ACTIVE="$CRED_HELPER"
    echo "credential.helper WOULD BE set globally: $CRED_HELPER"
  else
    git config --global credential.helper "$CRED_HELPER"
    CRED_HELPER_ACTIVE="$CRED_HELPER"
    echo "credential.helper set globally: $CRED_HELPER"
  fi
  echo
fi

# ---------------------------------------------------------------------------
# Leftovers: configs and includeIf entries of accounts that are no longer in
# the accounts file. They are only reported unless PRUNE=1 is set, because
# removing config the user may still need is not something to do silently.
# SSH and GPG keys are never deleted here.
# ---------------------------------------------------------------------------
# Only what this script wrote is removed. Everything else is reported as unmanaged.
ORPHANS=0
UNMANAGED=0
# Unmanaged files are deliberate, so list them only when cleaning up.
LIST_UNMANAGED=0
if [ "$DRY_RUN" = "1" ] || [ "$PRUNE" = "1" ]; then
  LIST_UNMANAGED=1
fi

# a) includeIf entries pointing at a config that no account owns any more.
#    Kept when the target is a user file, since removing it would unwire its repos.
while IFS= read -r ii_entry; do
  ii_gitdir="${ii_entry%%$'\t'*}"
  ii_path="${ii_entry#*$'\t'}"
  is_known_config "$ii_path" && continue
  if [ -e "$ii_path" ] && ! is_managed_config "$ii_path"; then
    UNMANAGED=$((UNMANAGED + 1))
    if [ "$LIST_UNMANAGED" = "1" ]; then
      echo "includeIf entry for an unmanaged config, not touched: gitdir:$ii_gitdir -> $ii_path"
    fi
    continue
  fi
  ORPHANS=$((ORPHANS + 1))
  if [ "$PRUNE" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    remove_includeif "$ii_gitdir" "$ii_path"
    echo "Removed orphaned includeIf entry: gitdir:$ii_gitdir -> $ii_path"
  elif [ "$PRUNE" = "1" ]; then
    echo "Orphaned includeIf entry WOULD BE removed: gitdir:$ii_gitdir -> $ii_path"
  else
    echo "Orphaned includeIf entry in ~/.gitconfig: gitdir:$ii_gitdir -> $ii_path"
  fi
done < <(includeif_entries)

# b) ~/.gitconfig-<alias> files without a matching account
for cfg in "$HOME"/.gitconfig-*; do
  [ -f "$cfg" ] || continue
  is_known_config "$cfg" && continue
  if ! is_managed_config "$cfg"; then
    UNMANAGED=$((UNMANAGED + 1))
    if [ "$LIST_UNMANAGED" = "1" ]; then
      echo "Unmanaged git config, not touched: $cfg"
    fi
    continue
  fi
  ORPHANS=$((ORPHANS + 1))
  if [ "$PRUNE" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    rm -f "$cfg"
    echo "Removed orphaned git config: $cfg"
  elif [ "$PRUNE" = "1" ]; then
    echo "Orphaned git config WOULD BE removed: $cfg"
  else
    echo "Orphaned git config (no account in $(basename "$ACCOUNTS_FILE")): $cfg"
  fi
done

if [ "$ORPHANS" -gt 0 ] && [ "$PRUNE" != "1" ]; then
  echo "  -> left untouched; run with PRUNE=1 to remove them"
  echo "     (SSH and GPG keys are never deleted, remove those by hand)"
fi
if [ "$UNMANAGED" -gt 0 ] && [ "$LIST_UNMANAGED" = "1" ]; then
  echo "  -> unmanaged = not written by this script. PRUNE never removes those."
fi
if [ "$ORPHANS" -gt 0 ] || { [ "$UNMANAGED" -gt 0 ] && [ "$LIST_UNMANAGED" = "1" ]; }; then
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

if [ "$DRY_RUN" = "1" ]; then
  echo "== Dry run - nothing was written =="
else
  echo "== Done =="
fi
orphan_note=""
if [ "$ORPHANS" -gt 0 ] && [ "$PRUNE" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    orphan_note=" (would be pruned)"
  else
    orphan_note=" (pruned)"
  fi
fi
echo "Summary: ${#ACCOUNTS[@]} account(s) in $(basename "$ACCOUNTS_FILE") - \
$CREATED created, $UPDATED updated, $UNCHANGED unchanged, $REMAPPED includeIf added/moved, \
$ORPHANS leftover(s)$orphan_note, $UNMANAGED unmanaged (not touched)"
if [ "${#CHANGE_HINTS[@]}" -gt 0 ]; then
  echo
  echo "Needs your attention:"
  for hint in "${CHANGE_HINTS[@]}"; do
    echo "   - $hint"
  done
fi
if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "Re-run without DRY_RUN=1 to apply the changes above."
fi
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
    parse_entry "$entry"
    if [ -z "$ssh_user" ]; then
      continue
    fi
    key_path="$(ssh_key_path "$alias").pub"
    echo "   - $alias ($hostname): $key_path"
    echo "       show:  cat $key_path"
    if [ -n "$CLIP_CMD" ]; then
      echo "       copy:  $CLIP_CMD < $key_path"
    fi
  done
  echo
fi
step "Add the GPG public keys to the respective hosts (Settings -> GPG keys):"
for i in "${!ACCOUNTS[@]}"; do
  parse_entry "${ACCOUNTS[i]}"
  # The fingerprint that was actually written into the config.
  fpr="${ACCOUNT_FPRS[i]}"
  echo "   - $alias ($email):"
  if [ -n "$fpr" ]; then
    echo "       show:  gpg --armor --export $fpr"
    if [ -n "$CLIP_CMD" ]; then
      echo "       copy:  gpg --armor --export $fpr | $CLIP_CMD"
    fi
  else
    # A bare 'gpg --armor --export' would export the whole keyring.
    echo "       (no key yet - re-run without DRY_RUN=1 to create it)"
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
    parse_entry "$entry"
    if [ -z "$ssh_user" ]; then
      continue
    fi
    key_path="$(ssh_key_path "$alias")"
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
  parse_entry "$entry"
  key_path="$(ssh_key_path "$alias")"
  echo "   - $alias -> $PROJECT_BASE/$folder/repo"
  if [ -n "$ssh_user" ]; then
    echo "       SSH:    git -c core.sshCommand=\"ssh -i $key_path -o IdentitiesOnly=yes\" \\"
    echo "                   clone $ssh_user@$hostname:org/repo.git $PROJECT_BASE/$folder/repo"
  fi
  if [ -n "$https_user" ]; then
    echo "       HTTPS:  git clone https://$https_user@$hostname/org/repo.git $PROJECT_BASE/$folder/repo"
  else
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
  # printf because some shells' echo would expand the \n.
  printf '%s\n' "       printf 'protocol=https\\nhost=<host>\\nusername=<user>\\n\\n' | git credential reject"
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

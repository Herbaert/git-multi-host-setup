#!/usr/bin/env bash
# Scenario tests for setup-git-hosts.sh, each in its own sandbox HOME.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

key_count() { gpg --list-secret-keys --with-colons 2>/dev/null | count '^sec:'; }
key_validity() { gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/{print $2; exit}'; }
key_fpr() { gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'; }
exists() { [ -e "$1" ] && echo yes || echo no; }

# --- accounts file -----------------------------------------------------------
t_trim() { new_sandbox
  printf 'a | github.com | git | f | A Name | a@x.io | handle\n' > "$ACC"; run >/dev/null
  git config --file "$HOME/.gitconfig-a" --get 'credential.https://github.com.username'; }

t_dup_alias() { new_sandbox
  printf 'w|github.com|git|fa|A|a@x.io\nw|gitlab.com|git|fb|B|b@x.io\n' > "$ACC"; run; }

t_dup_folder() { new_sandbox
  printf 'one|github.com|git|shared|A|a@x.io\ntwo|gitlab.com|git|shared/|B|b@x.io\n' > "$ACC"; run; }

t_folder_spelling() { new_sandbox
  printf 'a|github.com|git|./work/|A|a@x.io\n' > "$ACC"; run >/dev/null
  includeifs | count '//\.path'; }

t_key_collision() { new_sandbox
  printf 'acme-dev|github.com|git|f1|A|a@x.io\nacme_dev|gitlab.com|git|f2|B|b@x.io\n' > "$ACC"; run; }

t_empty_fields() { new_sandbox
  printf '|github.com|git|f|N||h\n' > "$ACC"; run >/dev/null
  echo "alias=$(count 'alias' < "$SB/err.txt"),email=$(count 'git_email' < "$SB/err.txt")"; }

# --- includeIf -----------------------------------------------------------------
t_handover() { new_sandbox
  printf 'work|github.com|git|team|W|w@x.io\n' > "$ACC"; run >/dev/null
  printf 'newteam|github.com|git|team|N|n@x.io\nwork|github.com|git|team-archive|W|w@x.io\n' > "$ACC"; run >/dev/null
  echo "mappings=$(includeifs | count '\.gitconfig-'),hint=$(count 'also mapped' < "$SB/out.txt")"; }

t_spaces() { new_sandbox
  export PROJECT_BASE="$SB/home/My Projects"
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"; run >/dev/null; run >/dev/null; run >/dev/null
  echo "sections=$(includeifs | count '\.gitconfig-a'),orphans=$(count 'Orphaned' < "$SB/out.txt")"; }

t_rename() { new_sandbox
  printf 'a|github.com|git|old|A|a@x.io\n' > "$ACC"; run >/dev/null
  printf 'a|github.com|git|new|A|a@x.io\n' > "$ACC"; run >/dev/null
  includeifs | grep -o 'projects/[^/]*/' | tr '\n' ' '; }

# --- PRUNE -------------------------------------------------------------------
t_prune_own() { new_sandbox
  printf 'a|github.com|git|fa|A|a@x.io\nb|gitlab.com|git|fb|B|b@x.io\n' > "$ACC"; run >/dev/null
  printf 'a|github.com|git|fa|A|a@x.io\n' > "$ACC"; run PRUNE=1 >/dev/null
  echo "config=$(exists "$HOME/.gitconfig-b"),includeIf=$(includeifs | count 'gitconfig-b')"; }

t_prune_backup() { new_sandbox
  printf 'a|github.com|git|fa|A|a@x.io\nwork|github.com|git|fw|W|w@x.io\n' > "$ACC"; run >/dev/null
  cp "$HOME/.gitconfig-work" "$HOME/.gitconfig-work.bak"
  printf 'a|github.com|git|fa|A|a@x.io\n' > "$ACC"; run PRUNE=1 >/dev/null
  echo "bak=$(exists "$HOME/.gitconfig-work.bak"),work=$(exists "$HOME/.gitconfig-work")"; }

t_prune_manual() { new_sandbox
  printf 'a|github.com|git|fa|A|a@x.io\n' > "$ACC"; run >/dev/null
  printf '[user]\n  name = Manual\n' > "$HOME/.gitconfig-local"
  printf '\n[includeIf "gitdir:%s/manual/"]\n    path = %s\n' "$HOME" "$HOME/.gitconfig-local" >> "$HOME/.gitconfig"
  run PRUNE=1 >/dev/null
  echo "file=$(exists "$HOME/.gitconfig-local"),includeIf=$(includeifs | count 'gitconfig-local')"; }

t_marker_backfill() { new_sandbox
  printf 'a|github.com|git|fa|A|a@x.io\n' > "$ACC"; run >/dev/null
  tail -n +2 "$HOME/.gitconfig-a" > "$SB/cfg" && mv "$SB/cfg" "$HOME/.gitconfig-a"
  run >/dev/null
  echo "marker=$(head -n 1 "$HOME/.gitconfig-a" | count '^# managed by'),unchanged=$(count 'Git config unchanged' < "$SB/out.txt")"; }

t_unmanaged_quiet() { new_sandbox
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"; run >/dev/null
  printf '[alias]\n st = status\n' > "$HOME/.gitconfig-local"
  run >/dev/null
  local normal summary
  normal="$(count 'config, not touched' < "$SB/out.txt")"
  summary="$(grep '^Summary' "$SB/out.txt" | grep -o '[0-9][0-9]* unmanaged')"
  run DRY_RUN=1 >/dev/null
  echo "normal_lines=$normal,summary=$summary,dry_run_lines=$(count 'config, not touched' < "$SB/out.txt")"; }

# --- DRY_RUN -------------------------------------------------------------------
t_dry_run() { new_sandbox
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"; run DRY_RUN=1 >/dev/null
  local fresh files bare
  fresh="$(count 'WOULD run' < "$SB/out.txt")"
  bare="$(count 'gpg --armor --export *\(|\|$\)' < "$SB/out.txt")"
  files="$(find "$HOME" -mindepth 1 | wc -l | tr -d ' ')"
  run >/dev/null; run DRY_RUN=1 >/dev/null
  echo "files=$files,fresh_would_run=$fresh,bare_export=$bare,setup_would_run=$(count 'WOULD run' < "$SB/out.txt")"; }

t_idempotent() { new_sandbox
  printf 'a|github.com|git|fa|A|a@x.io|ha\nb|gitlab.com||fb|B|b@x.io|hb\n' > "$ACC"; run >/dev/null
  cp "$HOME/.gitconfig" "$SB/g1"; cp "$HOME/.gitconfig-a" "$SB/a1"; run >/dev/null
  local same=no
  cmp -s "$SB/g1" "$HOME/.gitconfig" && cmp -s "$SB/a1" "$HOME/.gitconfig-a" && same=yes
  echo "identical=$same,unchanged=$(count 'Git config unchanged' < "$SB/out.txt")"; }

t_https_only() { new_sandbox
  printf 'h|github.com||fh|H|h@x.io|handle\n' > "$ACC"; run >/dev/null
  echo "sshCommand=$(git config --file "$HOME/.gitconfig-h" --get core.sshCommand || echo none),key=$(exists "$HOME/.ssh/id_ed25519_h")"; }

# --- GPG -----------------------------------------------------------------------
t_gpg_empty_fpr() { new_sandbox
  export GPG_STUB_FAIL_SILENT=1
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"
  echo "rc=$(run),config=$(exists "$HOME/.gitconfig-a")"; }

t_gpg_exact_match() { new_sandbox; use_real_gpg
  gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --quick-generate-key 'Max Alex <m.alex@bit.de>' ed25519 sign never >/dev/null 2>&1
  printf 'a|github.com|git|f|Alex|alex@bit.de\n' > "$ACC"; run >/dev/null
  key_count; }

t_gpg_expired() { new_sandbox; use_real_gpg
  gpg --batch --quiet --faked-system-time 20200101T000000 --passphrase '' --pinentry-mode loopback \
    --quick-generate-key 'Old <old@x.io>' ed25519 sign 1d >/dev/null 2>&1
  local fpr; fpr="$(key_fpr)"
  printf 'a|github.com|git|f|Old|old@x.io\n' > "$ACC"; run >/dev/null
  local same=no
  [ "$(git config --file "$HOME/.gitconfig-a" --get user.signingkey)" = "$fpr" ] && same=yes
  echo "keys=$(key_count),validity=$(key_validity),same_fpr=$same,hint=$(count 're-upload' < "$SB/out.txt")"; }

t_gpg_expired_protected() { new_sandbox; use_real_gpg
  gpg --batch --quiet --faked-system-time 20200101T000000 --passphrase secret --pinentry-mode loopback \
    --quick-generate-key 'Old <old@x.io>' ed25519 sign 1d >/dev/null 2>&1
  gpgconf --kill gpg-agent   # forget the cached passphrase
  printf 'a|github.com|git|f|Old|old@x.io\n' > "$ACC"; run >/dev/null
  echo "keys=$(key_count),validity=$(key_validity),hint=$(count 'extend it with' < "$SB/out.txt")"; }

t_passphrase_no_tty() { new_sandbox
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"
  local rc; rc="$(run GPG_PASSPHRASE=1)"
  echo "rc=$rc,files=$(find "$HOME" -mindepth 1 | wc -l | tr -d ' ')"; }

t_old_bash() { new_sandbox
  printf 'a|github.com|git|f|A|a@x.io\n' > "$ACC"
  /bin/bash "$SCRIPT" "$ACC" >"$SB/out.txt" 2>"$SB/err.txt" </dev/null
  echo "rc=$?,message=$(count 'bash 5 or newer' < "$SB/err.txt"),files=$(find "$HOME" -mindepth 1 | wc -l | tr -d ' ')"; }

t_tmp_cleanup() { new_sandbox
  mkdir -p "$HOME/.gitconfig-a"   # writing the config fails after mktemp
  local tdir mail
  tdir="$(dirname "$(mktemp -u)")"
  mail="leak$$x$RANDOM@x.io"
  printf 'a|github.com|git|f|A|%s\n' "$mail" > "$ACC"; run >/dev/null
  find "$tdir" -maxdepth 1 -type f -exec grep -lF "$mail" {} + 2>/dev/null | wc -l | tr -d ' '; }

banner "Accounts file"
check "fields are trimmed"                  "handle"      "$(t_trim)"
check "duplicate alias rejected"            "1"           "$(t_dup_alias)"
check "folder/ and folder are one folder"   "1"           "$(t_dup_folder)"
check "no // in gitdir"                     "0"           "$(t_folder_spelling)"
check "acme-dev/acme_dev rejected"          "1"           "$(t_key_collision)"
check "all empty fields named"              "alias=1,email=1" "$(t_empty_fields)"

banner "includeIf"
check "folder handover keeps both mappings" "mappings=2,hint=0"      "$(t_handover)"
check "spaces in PROJECT_BASE"              "sections=1,orphans=0"   "$(t_spaces)"
check "rename moves the entry"              "projects/new/ "         "$(t_rename)"

banner "PRUNE"
check "removes own leftovers"               "config=no,includeIf=0"  "$(t_prune_own)"
check "keeps .bak copies"                   "bak=yes,work=no"        "$(t_prune_backup)"
check "keeps hand-written config + wiring"  "file=yes,includeIf=1"   "$(t_prune_manual)"
check "marker backfilled on old configs"    "marker=1,unchanged=1"   "$(t_marker_backfill)"
check "unmanaged files listed only on DRY_RUN/PRUNE" \
      "normal_lines=0,summary=1 unmanaged,dry_run_lines=1"           "$(t_unmanaged_quiet)"

banner "DRY_RUN and idempotency"
check "dry run writes nothing, previews setup" \
      "files=0,fresh_would_run=3,bare_export=0,setup_would_run=0"    "$(t_dry_run)"
check "second run changes nothing"          "identical=yes,unchanged=2" "$(t_idempotent)"
check "HTTPS-only stays SSH-free"           "sshCommand=none,key=no"  "$(t_https_only)"

banner "GPG"
check "gpg success without key aborts"      "rc=1,config=no"          "$(t_gpg_empty_fpr)"
check "e-mail matched exactly"              "2"                       "$(t_gpg_exact_match)"
check "expired key extended in place"       "keys=1,validity=u,same_fpr=yes,hint=1" "$(t_gpg_expired)"
check "protected expired key: hint, no new key" "keys=1,validity=e,hint=1" "$(t_gpg_expired_protected)"
check "GPG_PASSPHRASE=1 without terminal aborts first" "rc=1,files=0" "$(t_passphrase_no_tty)"
check "temp files removed on abort"         "0"                       "$(t_tmp_cleanup)"

# Only where an old bash exists, i.e. /bin/bash on macOS.
if [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 5 ]; then
  banner "Requirements"
  check "bash < 5 aborts before writing"    "rc=1,message=1,files=0"  "$(t_old_bash)"
fi

summary

# shellcheck shell=bash
# Sandbox helpers for tests/run.sh. Nothing here touches the real HOME.

SCRIPT="${SCRIPT_UNDER_TEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup-git-hosts.sh}"
ORIG_PATH="$PATH"
PASS=0
FAIL=0

check() {   # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  PASS %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"
  fi
}

banner() { printf '\n%s\n' "$1"; }

# Fresh HOME, GNUPGHOME and TMPDIR, plus a gpg stub that knows keys by exact
# e-mail. Real gpg is slow, so only the GPG scenarios use it (use_real_gpg).
new_sandbox() {
  SB="$(mktemp -d)"
  export HOME="$SB/home" GNUPGHOME="$SB/gnupg" PROJECT_BASE="$SB/home/projects" TMPDIR="$SB/tmp"
  mkdir -p "$HOME" "$GNUPGHOME" "$TMPDIR"
  chmod 700 "$GNUPGHOME"
  ACC="$SB/accounts.conf"
  export GPG_STUB_DB="$SB/keys.db" GPG_STUB_FAIL_SILENT=0
  : > "$GPG_STUB_DB"
  mkdir -p "$SB/bin"
  cat > "$SB/bin/gpg" <<'STUB'
#!/usr/bin/env bash
db="${GPG_STUB_DB:?}"
last="${!#}"
case " $* " in
  *" --list-secret-keys "*)
    e="${last#<}"
    e="${e%>}"
    if grep -qxF "$e" "$db" 2>/dev/null; then
      printf 'sec:u:255:22:ABCD:1:2:::::scESC::\nfpr:::::::::FPR%s:\n' \
        "$(printf '%s' "$e" | tr -dc 'A-Za-z0-9' | tr 'a-z' 'A-Z')"
    fi
    ;;
  *" --generate-key "*)
    [ "${GPG_STUB_FAIL_SILENT:-0}" = "1" ] && exit 0
    sed -n 's/^Name-Email: //p' "$last" >> "$db"
    ;;
esac
exit 0
STUB
  chmod +x "$SB/bin/gpg"
  export PATH="$SB/bin:$ORIG_PATH"
}

# Each test runs in its own subshell, so its EXIT trap stops that sandbox's agent.
use_real_gpg() {
  rm -f "$SB/bin/gpg"
  trap 'gpgconf --kill gpg-agent 2>/dev/null' EXIT
}

# run [VAR=value ...]: run the script on $ACC, print its exit code.
# stdin is /dev/null so the script never sees a terminal and never waits on pinentry.
run() {
  env "$@" bash "$SCRIPT" "$ACC" >"$SB/out.txt" 2>"$SB/err.txt" </dev/null
  echo $?
}

includeifs() {
  git config --file "$HOME/.gitconfig" --get-regexp -z '^includeif' 2>/dev/null | tr '\0' '\n'
}

count() { grep -c -- "$1" || true; }

summary() {
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

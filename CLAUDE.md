## Working on this repo

- Requires bash 5. Before every commit, `shellcheck -S style -x setup-git-hosts.sh tests/*.sh` and `bash tests/run.sh` must both pass.
- Run the script only inside a sandbox HOME, like `new_sandbox` in `tests/lib.sh` does.
- Commit messages are a single line.
- Comments state the why in one sentence. Before handing over, read every added `#` line in the diff.

## Agent skills

- Before creating, reading or labelling an issue: `docs/agents/issue-tracker.md` (GitHub via `gh`).
- Before applying a triage label: `docs/agents/triage-labels.md`.
- Before exploring the code: `docs/agents/domain.md` (single context; `CONTEXT.md` and `docs/adr/` are created when needed).

# Domain Docs

How the engineering skills consume this repo's domain documentation when exploring the code.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root: the glossary.
- **`docs/adr/`**: the ADRs that touch the area you are about to work in.

Both are created lazily by `/domain-modeling` (reached via `/grill-with-docs` and `/improve-codebase-architecture`) once a term or decision gets resolved. Until then, carry on without them.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`.

A concept missing from the glossary is a signal: either the language is invented (reconsider) or there is a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

When your output contradicts an existing ADR, say so explicitly:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_

# AI audit log

This folder holds our evidence of AI mistakes. It feeds the AI Audit Report for SC4053.

Each entry records one case where an AI tool gave wrong, unsafe or misleading output, and how we found and fixed it.

## Rule

- Only real failures and real evidence.
- Never invent test output, Slither results, transaction hashes or screenshots.
- If evidence is missing, write `TODO: evidence` in the entry.
- Never write secrets, private keys or private RPC URLs. Write "placeholder".

## Naming

Default: one file per issue, at `docs/ai/issues/NNN-slug.md`.

- `NNN` is a three-digit counter: `001`, `002`, ...
- `slug` is a short lowercase name with hyphens, for example `002-refund-rounding`.

The team may switch to one file per member. If we do, change this section first.

## How to add an entry

1. Copy `docs/ai/TEMPLATE.md` to `docs/ai/issues/NNN-slug.md`. Use the next free number.
2. Fill the metadata table: date, tool, prompt/context, commit.
3. Fill the four sections: why the AI made the mistake, why it is problematic, how we fixed it, evidence the fix works.
4. Add real evidence: test log, Slither output, tx hash or screenshot. Put images in `docs/ai/img/`.
5. Open a PR on a feature branch. Someone else reviews it.

Sources to mine for entries: `actions.md`, `market_creation_plan.md`, `resolution_plan.md`, `work_plan.md` and git history.

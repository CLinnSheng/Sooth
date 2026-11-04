# AI audit log

This folder holds our evidence of AI mistakes. It feeds the AI Audit Report for SC4053.

Each entry records one case where an AI tool gave wrong, unsafe or misleading output, and how we found and fixed it.

## Rule

- Only real failures and real evidence.
- Never invent test output, Slither results, transaction hashes or screenshots.
- If evidence is missing, write `TODO: evidence` in the entry.
- Never write secrets, private keys or private RPC URLs. Write "placeholder".

## Naming

One file per team member, at `docs/ai/<name>.md` (decided 2026-11-04).

- `<name>` is the member's first name in lowercase, for example `docs/ai/lin.md`.
- Entries are numbered inside the file: `## 1. Short title`, `## 2. Short title`, ...
- Numbers only go up. Never renumber old entries, because other docs may refer to them (for example "lin.md #3").
- An issue found by two members goes in the file of the member whose AI session produced it. The other file links to it.

## How to add an entry

1. Open your own file, `docs/ai/<name>.md`. If it does not exist, create it with a `# AI audit log: <Name>` title.
2. Copy the entry block from `docs/ai/TEMPLATE.md` to the end of your file. Give it the next free number in your file.
3. Fill the metadata table: date, tool, prompt/context, commit.
4. Fill the four sections: why the AI made the mistake, why it is problematic, how we fixed it, evidence the fix works.
5. Add real evidence: test log, Slither output, tx hash or screenshot. Put images in `docs/ai/img/`.
6. Open a PR on a feature branch. Someone else reviews it.

Sources to mine for entries: `actions.md`, `market_creation_plan.md`, `resolution_plan.md`, `work_plan.md` and git history.

## N. Short issue title

Copy this block to the end of your own file, `docs/ai/<name>.md`, use the next free number `N` in that file, and fill every field.
Write only what really happened. If evidence is missing, write `TODO: evidence`.

| Field | Value |
|---|---|
| Date | YYYY-MM-DD |
| Tool | e.g. Claude Code, model name and version |
| Prompt / context given | What we asked, and which files or specs the AI could see. Quote or link it. |
| Commit | Commit hash of the fix (and the commit that introduced the bug, if known) |
| Files affected | e.g. `contracts/src/...` |
| Severity | Low / Medium / High |

### Summary

One or two sentences: what the AI produced and what was wrong.

### Why the AI made the mistake

Pick the cause that fits: missing context, wrong assumption, outdated knowledge, or tool misuse. Explain it.

### Why it is problematic

Real-world impact, for example drainable funds, stuck tokens, wrong prices or a broken process.

### How we fixed it

Code change, manual adjustment, or prompt/spec update. Link the commit or PR.

### Evidence the fix works

Real output only. Paste or link each item that applies.

- Test log: test name and result
- Slither output: detector and result
- Transaction hash (testnet) and explorer link
- Screenshot: path under `docs/ai/img/`

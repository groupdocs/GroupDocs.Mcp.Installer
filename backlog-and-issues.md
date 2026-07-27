# GroupDocs.Mcp.Installer — Critical Code Review, Issues & Backlog

**Reviewed:** 2026-07-27, fresh pass over `install-`, `verify-`, `uninstall-groupdocs-mcp.ps1`
after the v2 upgrade. Each issue is written so it can be pasted directly into a GitHub
issue (title in bold, suggested label in brackets).

Overall verdict: the toolkit is sound — safety rails (dry-run, backups, merge-not-
overwrite, sequenced MCP sessions) are real and e2e-verified against published
artifacts. The items below are ranked by how likely they are to bite a user.

---

## 1. Confirmed bugs (reproduced during review)

### 1.1 ~~verify: exit 0 with zero products verified — false PASS~~ — **FIXED 2026-07-27**
Was: NuGet-blocked products silently filtered → `[PASS] all 0 product(s) verified`,
exit 0 — a CI job wired to this would go green while testing nothing.
Now: each skipped product is reported, and an empty verification set fails loudly with
**exit 2**. Verified: `-Products parser,total -Channel nuget` → `[FAIL] no products to
verify …`, exit 2.

### 1.2 ~~verify toolcall can false-PASS on engine failures returned as text~~ — **FIXED 2026-07-27**
Was: the servers' errors-as-text contract (`"<Operation> failed for '<file>': …"`,
`isError` unset) sailed through the protocol-only check as `toolcall: ok`.
Now: the response text is inspected too (`… failed for '` / `Could not …` prefixes)
and reported as a failure with the engine's own message (truncated at 300 chars).
Verified against a real engine failure: a corrupt `.docx` produced
`[FAIL] toolcall 'get_document_info' on 'corrupt.docx' : Document-info lookup failed …
This file type is not supported`, exit 1 — while the good-document path still passes.

### 1.3 ~~Sample config pinned `verify.level: handshake`, contradicting the documented `auto` default~~ — **fixed during review** (config now says `auto`).

## 1b. Final review pass (2026-07-27, second sweep) — what's left

Mechanical gates re-checked after all fixes: all three scripts **parse clean** and are
**ASCII-clean** (the CI gates would pass); regression smoke green (installer dry-run,
uninstall full-sweep dry-run, verify good-path exit 0, bad-path exit 1, empty-set
exit 2). Merge behavior re-confirmed against a real config (foreign `atlassian` server
preserved). PSScriptAnalyzer could not run locally (PS 5.1 module bootstrap is
interactive-only) — first CI run is the gate.

New findings, none blocking:

### 1b.1 **Folders are created before validation completes** `[ux]`
`storagePath`/`outputPath` are created right after config load — *before* product
resolution, the NuGet-blocked guard, and client validation. An install that ends in
`throw` (e.g. all products blocked) still leaves a freshly created storage folder
behind. Extends issue 2.1: **no filesystem mutation before all validation passes**.

### 1b.2 **installer `-Uninstall` with an empty config `clients` list silently does nothing** `[ux]`
A compose-only config (`"clients": []`) delegated to the uninstaller yields an empty
client list — "removed 0" with no hint. Should fall back to `all` (matching the
standalone script's default) or say why nothing happened.

### 1b.3 **verify's docker launch skips backslash normalization** `[consistency]`
The installer normalizes `C:\docs` → `C:/docs` for `-v` mounts; `verify`'s
`Get-Launch` does not. Docker Desktop tolerates backslash drive paths, so impact is
low — but the two launch paths should agree (another argument for the shared module, 3.1).

### 1b.4 **Auto sample pick is "alphabetically first document"** `[docs]`
`Get-ChildItem` order means a stray `aaa-old.doc` in the storage folder becomes the
verification document. Post-bug-2 this *fails loudly* instead of silently passing —
correct, but surprising. Document that `verify.sampleFile` pins the choice.

### 1b.5 CLI-client detection is PowerShell-PATH-scoped `[note]`
`claude`/`codex` npm shims visible in other shells may be invisible to PS 5.1
(observed on the review machine). The warn-and-skip text already points at file-based
clients; no change needed beyond awareness.

## 2. High-priority issues

### 2.1 **Unknown client name throws mid-run, after earlier clients were already written** `[bug]`
`Get-ClientTarget` throws on the first unknown client, but only when its turn comes —
clients earlier in the list have already been modified. A typo like `clients:
["claude-desktop","visual-studio"]` produces a half-applied install.
**Fix:** validate every client name (and warn on unknown products) **before** the first
write; the uninstaller already warn-and-skips — make the installer consistent (validate
upfront, then either skip-with-warning or abort before any mutation).

### 2.2 **Invalid JSON in an existing client config crashes with a raw exception** `[bug]`
`Merge-IntoClient` / `Remove-FromClient` pipe the file straight into `ConvertFrom-Json`.
A hand-edited config with a trailing comma aborts the run mid-way (other clients
already written) with a parser stack trace and no guidance.
**Fix:** try/catch per client: report the path, skip that client, continue, exit non-zero
at the end. Never leave the user guessing which file is broken.

### 2.3 **No Docker preflight** `[ux]`
With the daemon stopped, install happily writes configs, then `-Prewarm`/`-Verify`/first
agent call fail with the npipe error (observed live during testing).
**Fix:** on `channel=docker`, run `docker version` once up front; warn loudly (or prompt
in the wizard) when the daemon is unreachable.

### 2.4 **Single global version pin breaks mixed product sets** `[design]`
Products currently sit at different latest versions (26.7.2 / 26.7.3 / 26.7.4), so
`"version": "26.7.2"` with `products: all` writes references that don't exist for some
products (dnx/docker fail at first launch, not at install).
**Fix (short term):** document that pins are per-set, recommend `latest` for `all`.
**Fix (proper):** per-product pins in the manifest/config, or resolve latest per product
from NuGet/GHCR at install time (see backlog 4.4).

## 3. Improvements (medium)

- 3.1 **Client map duplicated** between install and uninstall scripts — drift risk is
  documented in AGENTS.md but structural: extract `groupdocs-mcp.common.psm1`
  (targets, manifest load, Write-TextNoBom, dnx resolution). `[refactor]`
- 3.2 **Prewarm logic duplicated** (`-Prewarm` block vs the `-Verify` chain's inline
  warm) — same extraction. `[refactor]`
- 3.3 **`.bak` files accumulate unboundedly** — keep the last N (e.g. 5) per file, or a
  single `.bak` with the timestamp inside. `[ux]`
- 3.4 **`-RemoveImages` only removes the specified/`latest` tag** — pinned tags from
  earlier installs survive. Enumerate `docker images` for the repo names instead. `[ux]`
- 3.5 **Cline path supports stock VS Code only** — Insiders/VSCodium globalStorage
  variants are not probed. Probe the known bases, pick those that exist. `[client]`
- 3.6 **`codex mcp add --env` flag is unverified** (marked TODO in code) — click-test
  against a real Codex CLI install; adjust or drop env support for that client. `[verify]`
- 3.7 **`get_view_info` FileInput arg shape unverified against Viewer** — one live run
  settles it (`verify -Products viewer -Channel nuget`). `[verify]`
- 3.8 **ConvertTo-Json cosmetics differ between PS 5.1 and 7** — client files get
  reformatted wholesale on rewrite (noisy diffs for users who track dotfiles). Low
  impact; a custom stable serializer is probably not worth it — document instead. `[docs]`
- 3.9 **Wizard accepts typos silently** — product/client answers are saved unvalidated;
  errors surface only on the install run. Validate against the known lists inside the
  wizard loop and re-ask. `[ux]`
- 3.10 **Verify timeout is global per session** — a cold docker pull inside `verify`
  (user skipped prewarm) eats the whole budget; consider a separate connect budget, or
  detect pull-in-progress from stderr. `[ux]`

## 4. Backlog (initiatives)

- 4.1 **Pester test suite + shared module.** Unit-test the pure parts (product
  resolution, entry generation, client-target map, merge/remove round-trip on temp
  files) on the 3-OS CI matrix. The refactor in 3.1/3.2 is the prerequisite.
- 4.2 **PowerShell Gallery distribution** — publish as a module/script
  (`Install-Script groupdocs-mcp` / `Install-Module`), with **Authenticode signing**
  of release artifacts. This is the modern install path for a public PS tool and
  removes the clone-the-repo step.
- 4.3 **`-Status` / inventory command** — read all known client configs and print which
  GroupDocs servers are registered where, with channel/version — the natural companion
  to install/verify/uninstall (and the first thing support will ask a user for).
- 4.4 **Per-product latest resolution** — query NuGet flat-container / GHCR tags at
  install time so `latest` pins the actual current version per product (reproducible
  installs + correct mixed-set pins; fixes 2.4 properly).
- 4.5 **Rider + VS Code Insiders/VSCodium targets** — add when JetBrains stabilizes an
  MCP config surface; Insiders is just a second globalStorage base.
- 4.6 **Manifest sync automation** — a tiny CI job (or script) that cross-checks
  `manifest.json` against the MCP Registry (`search=groupdocs`) and opens a PR when a
  product appears/changes.
- 4.7 **Interactive uninstall wizard** — mirror `-Interactive` for removal (pick from a
  discovered inventory rather than typing names); pairs with 4.3.

## 5. Ready-to-file issue seeds

| # | Title | Labels |
|---|---|---|
| ~~1~~ | ~~verify: exits 0 when every requested product was filtered out~~ — fixed | ~~bug~~ |
| ~~2~~ | ~~verify toolcall: treat errors-as-text responses as failures~~ — fixed | ~~bug~~ |
| 3 | installer: validate client/product names before the first write (no half-applied installs) | bug, ux |
| 4 | Merge/Remove: survive invalid JSON in one client config; skip + report instead of crashing | bug, ux |
| 5 | docker channel: preflight `docker version` and warn when the daemon is down | ux |
| 6 | Version pin: document per-set semantics; add per-product resolution (backlog 4.4) | design, docs |
| 7 | Extract shared module (client map, prewarm, IO helpers) + Pester suite | refactor, tests |
| 8 | Uninstall: `-RemoveImages` should enumerate all local tags of the product images | ux |
| 9 | Cap `.bak` retention per client file | ux |
| 10 | Verify `codex mcp add --env` and Viewer `get_view_info` arg shape against real clients | verification |
| 11 | Publish to PowerShell Gallery with signed releases | distribution |
| 12 | Add `-Status` inventory command | feature |
| 13 | installer: no filesystem mutation (folder creation) before all validation passes | ux |
| 14 | installer `-Uninstall`: empty config clients should sweep `all` (or explain doing nothing) | ux |
| 15 | verify: normalize backslash host paths in docker launch (parity with installer) | consistency |
| 16 | docs: auto verification picks the alphabetically-first document; `verify.sampleFile` pins it | docs |

---

*Verified-working baseline for context: nuget channel (Signature 26.7.2 — 8 tools +
document toolcall), docker channel (Parser — 6 tools, Total — 38 tools, document
toolcall through containers), wizard, prewarm, uninstall sweep, and the CI dry-run
matrix in `.github/workflows/ci.yml`.*

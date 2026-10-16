---
id: 003
date: 2026-10-16
type: feature
---

# GroupDocs.Search, Docker `--user` on Linux, sample-free verification for Search

## What changed

- **New product: GroupDocs.Search** (`search`) in `manifest.json` — Docker only (`nugetBlocked`:
  the packed tool is 280.9 MiB, over NuGet.org's 250 MB limit). Image
  `ghcr.io/groupdocs-search/search-net-mcp`, server key `groupdocs-search`, MCP Registry
  `io.github.groupdocs-search/groupdocs-search-mcp`. `"all"` now includes it.
- **`inTotal: false`** (new optional product field) marks a product the GroupDocs.Total bundle
  does not contain. Search has it, so `total` + `search` is no longer reported as redundant;
  the warning now names only the products Total actually duplicates. New pure helper
  `Test-BundledInTotal` in `lib/platform.ps1`.
- **Docker on a Linux host: `--user <uid>:<gid>`.** The installer adds it to every Docker entry
  (and `user:` to the generated `docker-compose.yml`), resolved with `id -u` / `id -g` at install
  time because client configs run no shell. The verifier launches containers the same way.
  Windows and macOS (Docker Desktop) are unchanged.
- **Verification of Search:** the `auto` level calls `get_index_info` with no arguments — read-only
  and sample-free — since Search has no `get_document_info`. It runs even when the storage folder
  holds no sample document.
- CI: the NuGet-blocked refusal covers `search`; a Docker dry run for `search`; the e2e job adds
  a live Docker verification of Search on Ubuntu (exercises `--user` and the new auto check).

## Why

GroupDocs.Search.Mcp 26.10.1 is released (GHCR, Docker Hub mirror, MCP Registry). On Linux, the
images run as uid 1654 and a bind mount keeps its host owner, so a folder the user owns is
read-only inside the container: Search could not write its index, and any product writing output
(Parser images, Conversion results) failed with "Permission denied". Docker Desktop does not
enforce bind-mount ownership, which is why this never showed on Windows or macOS.

## Migration / impact

- Linux users: re-run the installer to get `--user` in existing Docker entries. Nothing changes on
  Windows or macOS.
- Configs listing `"all"` gain the `groupdocs-search` server on the next run; list products
  explicitly to keep the previous set.
- `total` together with any product other than Search still warns, as before.

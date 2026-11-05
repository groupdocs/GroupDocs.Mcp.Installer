---
id: 006
date: 2026-11-05
type: feature
---

# Parser on NuGet from 26.11.0, GHCR fallback for Docker Hub, unreleased products skipped

## What changed

- **Parser: `nugetSince: "26.11.0"`** (and `nugetBlocked: false`) in `manifest.json`. GroupDocs.Parser.Mcp
  26.11.0 is published to NuGet as per-platform packages; 26.10.2 and older exist only as images. On the
  nuget channel the installer now refuses a pin older than 26.11.0, and for `latest` it refuses while the
  MCP Registry still lists an older release - so Parser unblocks by itself once 26.11.0 is out, with no
  installer release. New helper `Get-PackageSince` (also reads `overrides.<platform>.packageSince`).
- **`dockerHub: false`** for Parser and Total, which publish to GHCR only. With `-Registry dockerhub`,
  `Get-ImageRef` now uses the GHCR image for them and the installer prints one warning, instead of
  writing a `groupdocs/<slug>-net-mcp` name that does not exist. New helper `Test-HasDockerHub`.
- **Products not yet released are skipped.** When the MCP Registry is reachable and has no entry for a
  product, the install skips it with the reason (it used to warn and write an entry that failed at first
  launch). This matters for `"all"`, which includes Assembly ahead of its first release.
  `-SkipRegistryCheck` still writes it.
- Wizard hint: Total does not bundle Search, Editor or Assembly.
- CI: the NuGet-refusal check covers `search,total` at `latest` and `parser` at 26.10.2.
- README, AGENTS.md, llms.txt, wiki and samples: 15 products (Editor and Assembly added to the lists),
  Parser's NuGet status, the Docker Hub fallback and the unreleased-product rule.

## Why

Parser moved to NuGet in 26.11.0 (engine 26.10.0 split out the OCR models, and per-platform packages each
fit the 250 MB limit). A plain `nugetBlocked: false` would have sent `dnx GroupDocs.Parser.Mcp` to a
package that is not on NuGet until that release, and pins of older versions would never resolve.

Docker Hub: `groupdocs/parser-net-mcp` and `groupdocs/total-net-mcp` return 404; only GHCR has those
images.

## Verification

Dry runs against the live MCP Registry (2026-11-05): nuget `parser` at `latest` refused (registry latest
26.10.2); nuget `parser` at 26.10.2 refused; at 26.11.0 accepted (`dnx` entry written); nuget `search,total`
refused as before; docker `all` skips `assembly` (no registry entry) and includes `editor` 26.10.0;
`-Registry dockerhub` with `parser,editor,search` writes GHCR for Parser with one warning.

## Migration / impact

`-Registry dockerhub` configs that listed Parser or Total now get working GHCR images. `"all"` no longer
writes Assembly until it is released.

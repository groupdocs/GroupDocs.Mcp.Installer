---
id: 005
date: 2026-10-30
type: feature
---

# GroupDocs.Assembly

## What changed

- **New product: GroupDocs.Assembly** (`assembly`) in `manifest.json` — NuGet and Docker
  (`nugetBlocked: false`; the packed tool is 99 MB). Package `GroupDocs.Assembly.Mcp`, image
  `ghcr.io/groupdocs-assembly/assembly-net-mcp`, server key `groupdocs-assembly`, MCP Registry
  `io.github.groupdocs-assembly/groupdocs-assembly-mcp`. `"all"` now includes it.
- **`inTotal: false`** — GroupDocs.Total.Mcp does not expose the Assembly tools, so `total` + `assembly`
  is not reported as redundant.
- Wiki: an Assembly example prompt under "Use it in your IDE".

## Why

GroupDocs.Assembly.Mcp is the family's 15th server (document generation from templates and data).

## Migration / impact

None until the first release is published. Until then the installer skips `assembly` with the reason
(no MCP Registry entry; see 006), so `"all"` does not write an entry that would fail at first launch.

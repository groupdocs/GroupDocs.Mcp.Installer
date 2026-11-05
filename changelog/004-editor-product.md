---
id: 004
date: 2026-10-29
type: feature
---

# GroupDocs.Editor

## What changed

- **New product: GroupDocs.Editor** (`editor`) in `manifest.json` — NuGet and Docker
  (`nugetBlocked: false`; the packed tool is 174 MB). Package `GroupDocs.Editor.Mcp`, image
  `ghcr.io/groupdocs-editor/editor-net-mcp`, server key `groupdocs-editor`, MCP Registry
  `io.github.groupdocs-editor/groupdocs-editor-mcp`. `"all"` now includes it.
- **`inTotal: false`** — GroupDocs.Total.Mcp does not expose the Editor tools, so `total` + `editor`
  is not reported as redundant.
- Wiki: an Editor example prompt under "Use it in your IDE".

## Why

GroupDocs.Editor.Mcp is the family's 14th server (formatting-preserving document editing).

## Migration / impact

None until the first release (26.10.0) is published; installing `editor` before then fails at the
package/image lookup like any unreleased product.

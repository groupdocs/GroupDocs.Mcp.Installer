---
id: 002
date: 2026-09-15
type: feature
---

# Platform selection, metered licensing, MCP Registry version checks

## What changed

- **Platform selection.** New `-Platform` switch, `"platform"` config key, and wizard question
  (asked first). `net` (.NET) is available and the default; `java`, `python` and `node` are
  listed as planned and refused with the list of available platforms. `-Channel` is now validated
  per platform against the manifest instead of a hardcoded `ValidateSet`.
- **`manifest.json` schema 2** (additive). A `platforms` block carries each platform's status,
  channels, naming patterns (server key, GHCR / Docker Hub image, package id, MCP Registry names)
  and package runner (`dnx` for .NET). Products gain `platforms: ["net"]`. Every existing field is
  unchanged, and CI checks that the .NET patterns reproduce the legacy `nuget` / `server` fields.
- **`lib/platform.ps1`** — shared pure functions for platform resolution, naming, the MCP Registry
  and metered-key presence, dot-sourced by all three scripts. The image names, `dnx`, and
  NuGet-blocked logic that were hardcoded in three places now live in one.
- **MCP Registry version check.** One request fetches every GroupDocs entry. A pinned `-Version` is
  checked per product *before any write*; a product never published at the pin is skipped with its
  latest version in the message. With `latest`, the resolved version per product is printed. The
  manifest lists registry name candidates, so the planned `…-mcp-net` rename (decision D1) is
  picked up without an installer release. An unreachable Registry is a warning; new
  `-SkipRegistryCheck` skips the lookup.
- **Metered licensing.** New `-Metered` switch / `"metered": true`. Docker entries forward
  `GROUPDOCS_METERED_PUBLIC_KEY` and `GROUPDOCS_METERED_PRIVATE_KEY` by name (`-e NAME`, no value);
  compose files declare them without values; nuget servers inherit them from the client. The keys
  are never written or printed — the config stores only the boolean, the wizard never asks for
  them, and output shows presence only (`set (32 chars)`). Warns when a key is missing, when only
  one is set, and when a license file is also configured (metered wins).
- **Verifier license check.** On `auto` and `toolcall` levels every server exposing
  `get_license_status` (GroupDocs.Mcp.Core 26.9.0+) is asked for its license mode. The summary gains
  `version` and `license` columns. With metered expected, a server that did not engage metered fails
  with the server's own reason. Older servers report `n/a` and are not failed. New `-Platform` and
  `-Metered` switches; the exit code also counts license failures.
- **Uninstaller.** New `-Platform` (default `all` available platforms); server names, images and the
  NuGet cache purge are resolved per platform.
- **No folder creation before validation** (backlog 1b.1): storage/output folders are created only
  after platform, channel, product, blocked-package and Registry checks pass.
- **Verify docker launch normalizes Windows backslash paths** like the installer (backlog 1b.3).
- **CI.** The nightly E2E sample is now a generated PDF (see Why). New dry-run checks: platform
  contract (planned / unknown / wrong channel), manifest naming drift, and refusal of a never-published
  pin. Every refusal assertion now matches the expected message. Optional metered E2E step runs when
  the `GROUPDOCS_METERED_*` secrets are configured.
- **Config and samples.** `groupdocs-mcp.config.json` reset to neutral values (it held
  machine-specific paths) with `platform` and `metered` keys; every sample sets `"platform": "net"`;
  new `claude.metered.pinned.docker` sample.
- **Docs.** README (Platforms, Licensing, Versions and the MCP Registry, license check), AGENTS.md
  (rules 12–16, adding a platform), CONTRIBUTING, llms.txt, wiki, samples README, backlog.

## Why

- **Platforms.** A Java, Python or Node.js server family is planned. The installer hardcoded .NET in
  three scripts, so a second platform would have meant editing all three. Now it is a manifest entry.
- **Registry.** Products do not share a version — Total 26.7.3 trails the 26.9.0 family — so a
  single pin used to write an entry for Total that could only fail at first launch inside the AI
  client. The MCP Registry is the one index covering every product, including the Docker-only ones.
- **Metered.** GroupDocs.Mcp.Core 26.9.0 added metered licensing to every server; the installer
  had no way to configure it. Writing the keys into client configs would have spread a secret into
  plain-text files that are often synced or committed.
- **E2E.** The nightly E2E had been red every night since at least 2026-09-07. It verified
  GroupDocs.Metadata against `sample.txt`, a format Metadata does not support, so `get_document_info`
  correctly failed. The verifier was right; the sample was wrong.

## Migration / impact

- **No action needed.** Configs without `platform` / `metered` behave exactly as before (`net`,
  not metered). Schema-1 manifests passed via `-Manifest` still work.
- **Pinned installs may now skip products.** A pinned version not published for a product is
  skipped rather than written. If every product is skipped the install stops — previously it
  succeeded and failed later in the client.
- **Verification may now fail where it passed.** With `-Metered` / `"metered": true`, a server
  running in evaluation mode is a failure.
- **Network.** Installs now make one HTTPS request to `registry.modelcontextprotocol.io`; use
  `-SkipRegistryCheck` offline.
- `-Channel` lost its `ValidateSet`, so tab completion no longer offers `docker` / `nuget`. Invalid
  values are still refused, with the valid list for the chosen platform.

## Verification

Windows PowerShell 5.1 **and PowerShell 7.6.6** (portable, Windows). Running PSScriptAnalyzer
with CI's settings caught a bug only PowerShell 7 exposes: a helper parameter named `$isWindows`
collides with the read-only automatic variable, so every nuget-channel preflight would have thrown
`Cannot overwrite variable isWindows` on pwsh — i.e. on every macOS/Linux machine and all three CI
runners. Renamed; both runtimes then passed everything below.

| Check | Result |
|---|---|
| All `.ps1` parse, ASCII-only | 5 files, 0 errors, 0 non-ASCII bytes |
| Default config dry-run | 3 products, latest resolved via Registry (26.9.0) |
| nuget + `-Metered` + pin 26.9.0 with Parser/Total | both skipped as NuGet-blocked; entry has no key env |
| docker + `-Metered` + pin 26.9.0 with Total | Total skipped (`never published at 26.9.0 (latest 26.7.3)`); `-e NAME` pass-through |
| Planned / unknown platform, wrong channel | refused with the available list |
| Pin `99.1.0` | refused before any folder or file is created |
| Schema-1 manifest | installs unchanged |
| Real install into a sandboxed `.mcp.json` + compose, then uninstall | foreign server preserved; no key value in any written file or backup; compose parses as YAML |
| E2E verify, Metadata 26.9.0, real metered keys | handshake PASS, `license: metered`, document toolcall PASS on generated PDF |
| E2E verify, bogus keys, `-Metered` | `[FAIL] license: expected metered … engine rejected them (Authentication failed.)`, exit 1 |
| E2E verify, no keys, not metered | `license: evaluation` with note, not failed |
| E2E verify, Metadata 26.7.2 (pre-`get_license_status`), `-Metered` | `license: n/a`, informational, not failed |
| New CI steps, each as its own process | pass for the right reason; negative control (missing script) fails |

| PSScriptAnalyzer, CI settings | 0 errors (CI fails only on errors) |
| Same battery on PowerShell 7.6.6 | dry-runs, CI steps, samples, sandbox round trip, metered E2E verify — all pass |

Not exercised locally: the docker channel end to end (no Docker daemon on the test machine) and
PowerShell 7 on macOS/Linux — the latter runs in the CI matrix.

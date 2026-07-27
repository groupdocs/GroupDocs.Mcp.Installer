# Changelog

One Markdown file per change, newest number wins. File name: `NNN-<slug>.md`.

Front matter:

```markdown
---
id: NNN
date: YYYY-MM-DD
type: feature | fix | change | docs
---

# Short title

## What changed
## Why
## Migration / impact
```

Behaviour-changing PRs must add an entry (see CONTRIBUTING.md). Release tags
(CalVer `YY.M.N`) reference the entries included since the previous tag.

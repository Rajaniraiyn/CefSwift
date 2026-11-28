---
title: "Build with an agent"
description: "Install the CefSwift skills, point an agent at AGENTS.md and llms.txt, and build a browser from one prompt."
---

```sh
npx skills add Rajaniraiyn/CefSwift
```

This installs two skills from the repository's
[`skills/`](https://github.com/Rajaniraiyn/CefSwift/tree/main/skills)
folder into your agent (Claude Code, Codex, Cursor and the others
[skills.sh](https://skills.sh) supports):

| Skill | Teaches |
|---|---|
| `cefswift` | Which module and host to use, the rules that keep a CEF app running (no `swift run`, no App Sandbox, bundle with `cef bundle`, `CefSwiftApp` instead of `App`), an API cheat sheet, how to verify, and which Gallery demo shows each capability |
| `build-a-browser` | The architecture of the Browser example, which CefSwift API already does each browser feature, what not to rebuild, and recipes for vertical tabs, spaces and a command bar |

## One prompt, one browser

With the skills installed, in an empty folder:

> Use the build-a-browser skill to make a macOS browser called Orbit in this
> folder: Chromium tabs in a vertical sidebar, an address field with
> Chromium's suggestions, bookmarks with ⌘D, history in a menu, a find bar
> on ⌘F, private windows on ⌘⇧N, and a command bar on ⌘K that searches open
> tabs, history and bookmarks. Bundle it with the cef plugin and open it.

## Machine-readable docs

- [`llms.txt`](https://rajaniraiyn.dev/cefswift/llms.txt) lists every page; `llms-full.txt` is the whole
  site as one Markdown file. Append `.md` to any page's address for its
  Markdown.
- [`AGENTS.md`](https://github.com/Rajaniraiyn/CefSwift/blob/main/AGENTS.md)
  at the repository root tells an agent working on CefSwift itself how to
  build, test and where things live.

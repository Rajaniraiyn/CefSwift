# CefSwift website

The documentation site at https://rajaniraiyn.dev/cefswift/, built with
[Blume](https://useblume.dev/) (pinned in `bun.lock`) and Bun 1.4 or newer.

```sh
cd www
bun install
bun run dev        # assemble the pages, then serve with hot reload
bun run build      # assemble the pages, then build the static site into dist/
bun run preview    # serve dist/ at http://localhost:4321/cefswift/
```

## Where the content lives

`docs/*.md` at the repository root stay the single source of the technical
content. The site does not copy them: `scripts/build-pages.ts` assembles
each page in `docs/` here (generated, not committed) from

- a skeleton in `pages/`: front matter, the page's opening (a runnable
  snippet and the matching Gallery demo), and
- the sections of `../docs/*.md` it names, one per line:

  ```md
  <!-- section docs/guide.md#tabs -->             the section, heading included
  <!-- section docs/guide.md#decisions body -->   without its heading
  <!-- section docs/design-notes.md# -->          the document's opening
  ```

A section brings its subsections unless another directive places them.
Every section of every document must be on exactly one page: the script
fails and names the section otherwise. So when you add a section to
`docs/`, add a directive for it to the page it belongs on.

Links between the documents become links between pages, links to other
repository files become GitHub links, and `docs/images/` is copied to
`public/images/`. The changelog page is made from the GitHub releases.

`pages/` holds no technical content beyond each opening. The Swift snippets
in it are compiled by `Scripts/check-doc-samples.py`, like those in
`docs/`.

## Deployment

`.github/workflows/pages.yml` builds on pull requests and deploys `dist/` to
GitHub Pages from `main` and on each release. The static site has local
search (Orama), `llms.txt` and `llms-full.txt`, a Markdown copy of each
page (append `.md`), a sitemap, structured data and Open Graph images. The
Ask AI assistant and MCP server are off because GitHub Pages cannot run
their server code.

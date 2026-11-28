// Assembles the site's pages (www/docs/, generated) from the page
// skeletons in www/pages/ and the sections of docs/*.md they name.
//
// docs/*.md stay the single source of the technical content. A skeleton is
// a Markdown page with front matter and its own short opening (a runnable
// snippet and the matching Gallery demo), plus directives on lines of their
// own:
//
//   <!-- section docs/guide.md#tabs -->            the section, heading included
//   <!-- section docs/guide.md#extensions body --> the section without its heading
//   <!-- section docs/guide.md# -->               the document's opening, before its first ##
//
// A section brings its subsections with it, except those another directive
// names. Every section of every document must land on exactly one page:
// the script fails and lists what is missing or claimed twice, so a new
// section in docs/ gets a place on the site before it publishes.
//
// Links between the documents become links between site pages, links to
// other files in the repository become GitHub links, and docs/images is
// copied into public/.

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import GithubSlugger from "github-slugger";

const www = resolve(import.meta.dir, "..");
const root = resolve(www, "..");
const pagesDir = join(www, "pages");
const outDir = join(www, "docs");
const repoURL = "https://github.com/Rajaniraiyn/CefSwift";
const branch = "main";

// The documents whose sections the site publishes.
const documents = ["guide.md", "architecture.md", "design-notes.md", "bundling.md", "sandbox.md", "automation.md"];

interface Section {
  doc: string;
  level: number; // 1 for the document's opening
  title: string;
  slug: string; // GitHub's anchor in docs/<doc>
  body: string[]; // lines after the heading, before the first subsection
  children: Section[];
  parent?: Section;
  claim?: { page: string; headless: boolean };
}

// ---------------------------------------------------------------- parsing

function parse(doc: string): Section {
  const lines = readFileSync(join(root, "docs", doc), "utf8").split("\n");
  const slugger = new GithubSlugger();
  const top: Section = { doc, level: 1, title: "", slug: "", body: [], children: [] };
  const stack: Section[] = [top];
  let fence: string | null = null;
  for (const line of lines) {
    const marker = line.match(/^\s*(```+|~~~+)/);
    if (marker) {
      if (fence === null) fence = marker[1];
      else if (line.trim().startsWith(fence)) fence = null;
    }
    const match = fence === null && !marker ? line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/) : null;
    if (match && match[1].length === 1 && top.title === "") {
      top.title = match[2];
      continue;
    }
    if (match && match[1].length >= 2) {
      const level = match[1].length;
      while (stack.length > 1 && stack[stack.length - 1].level >= level) stack.pop();
      const parent = stack[stack.length - 1];
      const section: Section = { doc, level, title: match[2], slug: slugger.slug(match[2]), body: [], children: [], parent };
      parent.children.push(section);
      stack.push(section);
      continue;
    }
    stack[stack.length - 1].body.push(line);
  }
  return top;
}

const trees = new Map(documents.map((doc) => [doc, parse(doc)]));

function find(doc: string, slug: string): Section | undefined {
  const tree = trees.get(doc);
  if (!tree) return undefined;
  if (slug === "") return tree;
  const walk = (s: Section): Section | undefined => {
    if (s.slug === slug) return s;
    for (const c of s.children) {
      const f = walk(c);
      if (f) return f;
    }
  };
  return walk(tree);
}

// ---------------------------------------------------------------- skeletons

interface Skeleton {
  route: string; // e.g. "browser/tabs"
  lines: string[];
}

function listSkeletons(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return listSkeletons(path);
    return name.endsWith(".md") ? [path] : [];
  });
}

const directive = /^<!--\s*section\s+docs\/([\w-]+\.md)#([\w-]*)(\s+body)?\s*-->$/;
const skeletons: Skeleton[] = listSkeletons(pagesDir).map((path) => ({
  route: relative(pagesDir, path).replace(/\.md$/, ""),
  lines: readFileSync(path, "utf8").split("\n"),
}));

const errors: string[] = [];
for (const page of skeletons) {
  for (const line of page.lines) {
    const m = line.trim().match(directive);
    if (!m) continue;
    const section = find(m[1], m[2]);
    if (!section) {
      errors.push(`${page.route}: no section docs/${m[1]}#${m[2]}`);
      continue;
    }
    if (section.claim) {
      errors.push(`docs/${m[1]}#${m[2]} is on two pages: ${section.claim.page} and ${page.route}`);
      continue;
    }
    section.claim = { page: page.route, headless: Boolean(m[3]) };
  }
}

// Every section lands somewhere: claimed itself, or inherited from a
// claimed parent. A document's opening never passes its sections on.
function owner(section: Section): Section | undefined {
  for (let s: Section | undefined = section; s; s = s.parent) {
    if (s.claim) return s.level === 1 && s !== section ? undefined : s;
  }
}
for (const tree of trees.values()) {
  const walk = (s: Section) => {
    if (!owner(s)) errors.push(`docs/${s.doc}#${s.slug} ("${s.title || "opening"}") is on no page: add a section directive to a file in www/pages/`);
    s.children.forEach(walk);
  };
  walk(tree);
}
if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

// ---------------------------------------------------------------- rendering

// Where each section's anchor ends up: (doc#slug) → route#anchor.
const anchors = new Map<string, string>();
const pageOfDoc = new Map<string, string>(); // a document's opening, for links without an anchor

interface Line {
  text: string;
  doc: string | null; // the document a spliced line came from
}

interface Rendered {
  route: string;
  lines: Line[];
}

function renderSection(section: Section, shift: number, headless: boolean, out: { lines: Line[]; sections: Section[] }) {
  if (!headless && section.level > 1) {
    const level = Math.min(6, Math.max(2, section.level - shift));
    out.lines.push({ text: `${"#".repeat(level)} ${section.title}`, doc: section.doc });
  }
  out.sections.push(section);
  out.lines.push(...section.body.map((text) => ({ text, doc: section.doc })));
  if (section.level === 1) return; // an opening does not pass its sections on
  for (const child of section.children) {
    if (child.claim) continue; // placed by its own directive
    renderSection(child, shift, false, out);
  }
}

const rendered: Rendered[] = [];
for (const page of skeletons) {
  const lines: Line[] = [];
  const placed: { section: Section; headless: boolean }[] = [];
  for (const line of page.lines) {
    const m = line.trim().match(directive);
    if (!m) {
      lines.push({ text: line, doc: null });
      continue;
    }
    const section = find(m[1], m[2])!;
    const headless = Boolean(m[3]);
    // A section's heading becomes an h2 on the page; its subsections follow.
    const shift = section.level - 2 + (headless ? 1 : 0);
    const out = { lines: [] as Line[], sections: [] as Section[] };
    renderSection(section, shift, headless, out);
    // Trim blank lines at both ends of the spliced block.
    while (out.lines.length && out.lines[0].text.trim() === "") out.lines.shift();
    while (out.lines.length && out.lines[out.lines.length - 1].text.trim() === "") out.lines.pop();
    lines.push(...out.lines);
    for (const s of out.sections) placed.push({ section: s, headless: s === section && headless });
  }
  // Compute the page's anchors as the renderer will: GitHub's slugs of
  // the page's headings, in order, numbered when repeated.
  const slugger = new GithubSlugger();
  const headings: string[] = [];
  let fence: string | null = null;
  for (const { text: line } of lines) {
    const marker = line.match(/^\s*(```+|~~~+)/);
    if (marker) {
      if (fence === null) fence = marker[1];
      else if (line.trim().startsWith(fence)) fence = null;
      continue;
    }
    if (fence !== null) continue;
    const h = line.match(/^#{2,6}\s+(.*?)\s*#*\s*$/);
    if (h) headings.push(h[1]);
  }
  const pageSlugs = new Map<string, string[]>();
  for (const h of headings) {
    const plain = stripInline(h);
    const slug = slugger.slug(plain);
    pageSlugs.set(h, [...(pageSlugs.get(h) ?? []), slug]);
  }
  const used = new Map<string, number>();
  for (const { section, headless } of placed) {
    const key = `${section.doc}#${section.slug}`;
    if (section.level === 1) {
      pageOfDoc.set(section.doc, page.route);
      continue;
    }
    if (headless) {
      anchors.set(key, page.route);
      continue;
    }
    const n = used.get(section.title) ?? 0;
    used.set(section.title, n + 1);
    const slug = pageSlugs.get(section.title)?.[n] ?? section.slug;
    anchors.set(key, `${page.route}#${slug}`);
  }
  rendered.push({ route: page.route, lines });
}

// Headings are slugged from their text: drop inline code ticks, links and emphasis.
function stripInline(text: string): string {
  return text
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_]{1,2}([^*_]+)[*_]{1,2}/g, "$1");
}

function sitePath(route: string): string {
  const [path, hash] = route.split("#");
  const clean = path === "index" ? "/" : `/${path.replace(/\/index$/, "")}`;
  return hash ? `${clean}#${hash}` : clean;
}

// A link in a line spliced from `fromDoc`: "#x" is an anchor in that
// document, "other.md#x" one in another.
function resolveLink(target: string, fromDoc: string | null): string | null {
  const [path, hash = ""] = target.split("#");
  if (path === "") {
    if (!fromDoc) return null;
    const a = anchors.get(`${fromDoc}#${hash}`);
    if (a) return sitePath(a);
    warnings.push(`unresolved link #${hash} in docs/${fromDoc}`);
    return null;
  }
  const docMatch = path.match(/^(?:\.\/)?([\w-]+\.md)$/);
  if (docMatch && documents.includes(docMatch[1])) {
    if (hash === "") return sitePath(pageOfDoc.get(docMatch[1]) ?? "index");
    const a = anchors.get(`${docMatch[1]}#${hash}`);
    if (a) return sitePath(a);
    warnings.push(`unresolved link ${target}`);
    return sitePath(pageOfDoc.get(docMatch[1]) ?? "index");
  }
  if (/^images\//.test(path)) return `/${path}`;
  if (/^\.\.\//.test(path) || /^(\.\/)?[\w.-]+\.(md|json|swift|sh|py|plist)$/.test(path)) {
    const repoPath = path.startsWith("../") ? path.slice(3) : join("docs", path.replace(/^\.\//, ""));
    const full = join(root, repoPath);
    const kind = existsSync(full) && statSync(full).isDirectory() ? "tree" : "blob";
    return `${repoURL}/${kind}/${branch}/${repoPath}${hash ? `#${hash}` : ""}`;
  }
  return null;
}

const warnings: string[] = [];
rmSync(outDir, { recursive: true, force: true });
for (const page of rendered) {
  let fence: string | null = null;
  const lines = page.lines.map(({ text: line, doc }) => {
    const marker = line.match(/^\s*(```+|~~~+)/);
    if (marker) {
      if (fence === null) fence = marker[1];
      else if (line.trim().startsWith(fence)) fence = null;
      return line;
    }
    if (fence !== null) return line;
    return line.replace(/\]\(([^)\s]+)\)/g, (whole, target: string) => {
      if (/^[a-z]+:/i.test(target) || target.startsWith("/")) return whole;
      if (doc === null && !/\.md(#|$)/.test(target)) return whole; // the skeleton's own links
      const resolved = resolveLink(target, doc);
      return resolved ? `](${resolved})` : whole;
    });
  });
  const file = join(outDir, `${page.route}.md`);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, lines.join("\n"));
}

// Images the documents show.
if (existsSync(join(root, "docs", "images"))) {
  cpSync(join(root, "docs", "images"), join(www, "public", "images"), { recursive: true });
}

// The changelog: the repository's GitHub releases, newest first. Without
// network access the page links to them instead.
async function changelog(): Promise<string> {
  const head = ["---", "title: Changelog", "description: What changed in each CefSwift release, from its GitHub release notes.", "---", ""];
  const link = `Every release, with its notes: [GitHub releases](${repoURL}/releases).`;
  try {
    const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
    if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    const response = await fetch("https://api.github.com/repos/Rajaniraiyn/CefSwift/releases?per_page=50", { headers });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const releases = (await response.json()) as { tag_name: string; name: string | null; published_at: string; body: string | null; html_url: string; draft: boolean }[];
    const sections = releases
      .filter((r) => !r.draft)
      .map((r) => {
        // Release notes use ## for their own sections: nest them under the release.
        const body = (r.body ?? "").replace(/\r\n/g, "\n").replace(/^(#{1,4}) /gm, "#$1 ");
        return [`## ${r.name || r.tag_name}`, "", `Released ${r.published_at.slice(0, 10)}. [${r.tag_name} on GitHub](${r.html_url})`, "", body.trim(), ""].join("\n");
      });
    return [...head, link, "", ...sections].join("\n");
  } catch (error) {
    warnings.push(`changelog: could not read GitHub releases (${error}); the page links to them`);
    return [...head, link, ""].join("\n");
  }
}
mkdirSync(join(outDir, "reference"), { recursive: true });
writeFileSync(join(outDir, "reference", "changelog.md"), await changelog());

for (const w of warnings) console.warn(`warning: ${w}`);
console.log(`Assembled ${rendered.length} pages from ${documents.length} documents into ${relative(www, outDir)}/.`);

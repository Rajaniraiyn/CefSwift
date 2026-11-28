import { defineConfig } from "blume";

// docs/ is generated from ../docs/*.md and pages/ by scripts/build-pages.ts.
export default defineConfig({
  title: "CefSwift",
  description: "Build your own Chromium browser for the Mac in Swift, or embed Chromium in any Mac app, on the official prebuilt CEF.",
  content: { root: "docs" },
  logo: { text: "CefSwift", href: "/" },
  github: { owner: "Rajaniraiyn", repo: "CefSwift", branch: "main", dir: "www/pages" },
  theme: { accent: "blue", radius: "md", mode: "system" },
  navigation: {
    sidebar: [
      { label: "Start", items: ["index", "start/install", "start/first-browser", "start/choosing-a-host", "start/agents"] },
      {
        label: "Build a browser",
        items: [
          "browser/tabs",
          "browser/address-bar",
          "browser/bookmarks-history",
          "browser/extensions",
          "browser/downloads",
          "browser/find-bar",
          "browser/popups-and-permissions",
          "browser/profiles",
          "browser/passkeys",
          "browser/streaming-and-drm",
          "browser/discarding-and-sessions",
          "browser/chrome-pages",
        ],
      },
      {
        label: "Embed Chromium",
        items: [
          "embed/webview",
          "embed/offscreen",
          "embed/javascript",
          "embed/custom-schemes",
          "embed/request-filtering",
          "embed/devtools-and-automation",
          "embed/animation",
          "embed/swipe-navigation",
          "embed/accessibility",
        ],
      },
      {
        label: "How it works",
        items: [
          "internals/process-model",
          "internals/sandboxing",
          "internals/c-bridge",
          "internals/threads-and-ownership",
          "internals/mojo-services",
          "internals/data-paths",
          "internals/flags-and-features",
          "internals/frame-timing",
          "internals/layering",
        ],
      },
      {
        label: "Performance",
        items: [
          "performance/memory",
          "performance/startup",
          "performance/offscreen-frames",
          "performance/service-calls",
          "performance/measured-not-used",
        ],
      },
      {
        label: "Ship",
        items: ["ship/tracks", "ship/bundling", "ship/signing", "ship/notarization", "ship/sandbox", "ship/upgrading"],
      },
      { label: "Reference", items: ["reference/known-limits", "reference/changelog", "reference/showcase"] },
    ],
  },
  search: { provider: "orama" },
  ai: {
    llmsTxt: true,
    mcp: { enabled: false },
    webmcp: false,
  },
  seo: { sitemap: true, robots: true, structuredData: true, og: { enabled: true } },
  deployment: {
    output: "static",
    site: (process.env.PAGES_ORIGIN || "https://rajaniraiyn.dev").replace(/^http:/, "https:"),
    // Pages reports the repository's path as /CefSwift; the site uses /cefswift.
    base: process.env.PAGES_BASE_PATH?.toLowerCase() || "/cefswift",
  },
});

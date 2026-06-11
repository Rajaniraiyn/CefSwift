# JS ↔ Swift bridge

`CefBridge` lets page JavaScript call Swift functions and get a typed reply
back as a `Promise`. It is built on CefSwift's custom-scheme machinery: the
reserved `cefswift` scheme (registered automatically in every process) routes
`POST cefswift://bridge/<name>` requests to functions you register.

## Swift side

Register functions any time after `CefRuntime.initialize` (they are global to
the app, not per browser):

```swift
// Typed (Codable in/out — recommended):
struct Person: Codable { let name: String }
struct Greeting: Codable { let message: String }

CefRuntime.shared.bridge.register("greet") { (person: Person) in
    Greeting(message: "Hello, \(person.name)!")
}

// Raw (Data in/out) when you want to handle encoding yourself:
CefRuntime.shared.bridge.register("raw") { (body: Data) async throws -> Data in
    body // echo
}
```

Handlers are `async` and run off the main thread — hop to `@MainActor` for UI
work. Thrown errors surface in JS as a rejected `Promise` (HTTP 500 under the
hood); an unknown function name rejects with a 404.

## JavaScript side

```js
const reply = await window.cefSwift.invoke('greet', { name: 'Ada' });
console.log(reply.message); // "Hello, Ada!"
```

`invoke(name, params)`:

- `params` is JSON-encoded into the request body (omit it for an empty body).
- JSON responses (`application/json`, which is what registered handlers
  return) are parsed; anything else resolves to a string.
- Network/scheme failures and non-2xx statuses reject the promise.

## Getting the shim into the page

`window.cefSwift` is defined by a small shim, available as
`CefBridge.javascriptShim` (idempotent — safe to include twice).

Two delivery options:

1. **Embed it in your pages** (recommended for production). If you serve
   your UI from a custom scheme (`CefBundleSchemeHandler` or your own
   `CefSchemeHandler`), put `<script>…shim…</script>` in the HTML — the
   Gallery example's bridge card does exactly this. The shim is then present
   before any page code runs.
2. **Auto-injection** (`CefRuntime.shared.bridge.autoInjectsShim`, default
   `true`). CefSwift injects the shim into every page at load-end, but only
   while at least one bridge function is registered. **Caveat:** load-end
   fires *after* the page's own scripts started executing, so code that runs
   at parse time or on `DOMContentLoaded` may not see `window.cefSwift` yet —
   poll for it or hook your calls to user actions. For deterministic startup
   ordering, use option 1 and set `autoInjectsShim = false`.

## Transport details (for debugging)

- Scheme: `cefswift`, registered with
  `standard | secure | corsEnabled | fetchEnabled` so `fetch()` from any
  origin (https pages included) may target it.
- Endpoint: `POST cefswift://bridge/<function-name>`; the response carries
  `Access-Control-Allow-Origin: *` and `OPTIONS` preflights are answered.
- Responses are fully buffered (v1) — keep payloads reasonably sized.

## Security notes

- **Bridge handlers run with your app's full privileges**, and *any* page
  loaded in *any* browser of your app can call them (the scheme is app-local —
  other apps can't reach it, but every page you render can). Validate and
  clamp all inputs; decode with strict Codable types, not dictionaries.
- Don't expose generic primitives ("run this shell command", "read this
  path"). Design narrow, purpose-specific functions.
- If you load arbitrary third-party web content, consider gating sensitive
  functions on the calling page's URL — pass the page origin explicitly as a
  parameter you verify server-side… better: don't register sensitive
  functions in browsers that show untrusted content.
- Replies are visible to the page; never return secrets a page shouldn't see.

## Demo

The Gallery example ships a "Swift ↔ JS Bridge" card: a `gallery://` page
(served by a `CefSchemeHandler`, shim embedded) auto-invokes a registered
`greet` function on load, renders the Swift reply in the page, and mirrors
each call into a native SwiftUI log. See
`Examples/Sources/Gallery/BridgeCard.swift`.

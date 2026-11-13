import Foundation

/// Finds whether any frame of a browser's page has a `beforeunload`
/// listener, with the DevTools Protocol.
///
/// Chromium runs `beforeunload` in every frame before a page is left, so
/// every frame's window is asked: `DOMDebugger.getEventListeners` lists a
/// target's listeners, including a `window.onbeforeunload` handler, but
/// only those of the execution context its object belongs to. Each window
/// is therefore reached in its own frame's main world:
///
/// - the main frame's with `Runtime.evaluate("window")`;
/// - a subframe in the same renderer process (`Page.getFrameTree`) through
///   its document, `DOM.getFrameOwner`, `DOM.describeNode` (the owner's
///   `contentDocument`), `DOM.resolveNode`, then the document's
///   `defaultView` with `Runtime.callFunctionOn`;
/// - an out-of-process frame (a cross-site `iframe`) in a session of its
///   own, `Target.attachToTarget` with `flatten`, the same way, and the
///   session detached afterwards. `Target.getTargets` lists such frames;
///   those whose parent targets lead to this page's are its own.
///
/// No domain is enabled. Chromium's performance-manager graph has a
/// `has_nonempty_beforeunload` field on frame and page nodes, but Blink
/// never sets it (CEF 156.0.28: `false` with listeners present, in either
/// runtime style), so the graph cannot be used for this.
@MainActor
enum CefBeforeUnloadListeners {
    static let objectGroup: CefJSON = "cefswift-discard"

    /// Whether a frame of `browser`'s page has a `beforeunload` listener.
    /// Throws when a step fails or a reply lacks what it should carry.
    static func present(in browser: CefBrowser) async throws -> Bool {
        let devTools = browser.devTools
        defer { Task { _ = try? await devTools.send("Runtime.releaseObjectGroup", ["objectGroup": objectGroup]) } }
        let tree = try await devTools.send("Page.getFrameTree")
        if try await present(inFramesOf: tree, devTools, session: nil) { return true }
        guard let pageID = tree["frameTree"]["frame"]["id"].stringValue else {
            throw CefError.operationFailed("Page.getFrameTree returned no main frame")
        }
        let targets = try await devTools.send("Target.getTargets")
        for frameID in try outOfProcessFrames(of: pageID, in: targets) {
            let attached = try await devTools.send("Target.attachToTarget", ["targetId": .string(frameID), "flatten": true])
            guard let session = attached["sessionId"].stringValue else {
                throw CefError.operationFailed("Target.attachToTarget returned no session")
            }
            defer { Task { _ = try? await devTools.send("Target.detachFromTarget", ["sessionId": .string(session)]) } }
            let frameTree = try await devTools.send("Page.getFrameTree", inSession: session)
            if try await present(inFramesOf: frameTree, devTools, session: session) { return true }
        }
        return false
    }

    /// Whether a frame of one renderer's part of the page (`tree`, that
    /// session's `Page.getFrameTree`) has a listener.
    private static func present(inFramesOf tree: CefJSON, _ devTools: CefDevTools, session: String?) async throws -> Bool {
        func send(_ method: String, _ params: CefJSON) async throws -> CefJSON {
            guard let session else { return try await devTools.send(method, params) }
            return try await devTools.send(method, params, inSession: session)
        }
        let window = try await send("Runtime.evaluate", ["expression": "window", "silent": true, "objectGroup": objectGroup])
        if try await hasListener(on: window["result"]["objectId"], send) { return true }
        for frameID in try subframes(inFrameTree: tree) {
            let owner = try await send("DOM.getFrameOwner", ["frameId": .string(frameID)])
            let described = try await send("DOM.describeNode", ["backendNodeId": owner["backendNodeId"]])
            // A frame owner whose document is elsewhere is listed by its own target.
            guard let document = described["node"]["contentDocument"]["backendNodeId"].intValue else { continue }
            let resolved = try await send("DOM.resolveNode", ["backendNodeId": .number(Double(document)), "objectGroup": objectGroup])
            let window = try await send("Runtime.callFunctionOn", [
                "objectId": resolved["object"]["objectId"], "functionDeclaration": "function() { return this.defaultView; }",
                "silent": true, "objectGroup": objectGroup,
            ])
            if try await hasListener(on: window["result"]["objectId"], send) { return true }
        }
        return false
    }

    private static func hasListener(
        on window: CefJSON, _ send: (String, CefJSON) async throws -> CefJSON
    ) async throws -> Bool {
        guard window.stringValue != nil else { throw CefError.operationFailed("A frame's window has no object id") }
        return try hasBeforeUnload(listeners: try await send("DOMDebugger.getEventListeners", ["objectId": window]))
    }

    // MARK: Replies

    /// Whether a `DOMDebugger.getEventListeners` reply lists a
    /// `beforeunload` listener.
    static func hasBeforeUnload(listeners reply: CefJSON) throws -> Bool {
        guard let listeners = reply["listeners"].arrayValue else {
            throw CefError.operationFailed("DOMDebugger.getEventListeners returned no listeners")
        }
        return listeners.contains { $0["type"].stringValue == "beforeunload" }
    }

    /// The ids of every frame below the main frame in a `Page.getFrameTree`
    /// reply: the subframes in the same renderer process.
    static func subframes(inFrameTree reply: CefJSON) throws -> [String] {
        guard reply["frameTree"]["frame"]["id"].stringValue != nil else {
            throw CefError.operationFailed("Page.getFrameTree returned no main frame")
        }
        var ids: [String] = []
        func collect(_ node: CefJSON) throws {
            for child in node["childFrames"].arrayValue ?? [] {
                guard let id = child["frame"]["id"].stringValue else {
                    throw CefError.operationFailed("Page.getFrameTree returned a frame without an id")
                }
                ids.append(id)
                try collect(child)
            }
        }
        try collect(reply["frameTree"])
        return ids
    }

    /// The out-of-process frames of the page `pageID` in a
    /// `Target.getTargets` reply: `iframe` targets whose chain of
    /// `parentId`s reaches it.
    static func outOfProcessFrames(of pageID: String, in reply: CefJSON) throws -> [String] {
        guard let targets = reply["targetInfos"].arrayValue else {
            throw CefError.operationFailed("Target.getTargets returned no targets")
        }
        var parents: [String: String] = [:]
        var frames: [String] = []
        for target in targets {
            guard let id = target["targetId"].stringValue else { continue }
            if let parent = target["parentId"].stringValue { parents[id] = parent }
            if target["type"].stringValue == "iframe" { frames.append(id) }
        }
        return frames.filter { frame in
            var current = parents[frame]
            var steps = 0
            while let id = current, steps < targets.count {
                if id == pageID { return true }
                current = parents[id]
                steps += 1
            }
            return false
        }
    }
}

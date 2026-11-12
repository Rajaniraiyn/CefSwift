import Foundation

/// Answers one browser's WebAuthn requests for ``CefPasskeyMode/app(_:)``
/// and ``CefPasskeyMode/disabled``, through the DevTools Protocol.
///
/// - `WebAuthn.enable`, without Chromium's UI, puts the browser's pages in a
///   virtual authenticator environment: Chromium's own dialog, security
///   keys and iCloud Keychain are out of the picture, and a request waits
///   for an authenticator until its timeout passes.
/// - A function-call breakpoint on each document's
///   `CredentialsContainer.prototype.create` and `.get` stops the page at
///   every call, before the call runs, in the calling document's execution
///   context (and so with its origin). Nothing is added to or changed in
///   the page. The breakpoints are set as each document's context appears.
/// - While the page is stopped, the delegate decides, and an authenticator
///   made for that one call is put in place: an empty one for a
///   registration, one holding only the chosen passkey for an assertion,
///   or one whose user verification fails for a refusal, which rejects the
///   call at once. Then the page goes on and makes its call. Chromium
///   reports the new or used credential (`WebAuthn.credentialAdded`,
///   `credentialAsserted`), which goes to the store, and the authenticator
///   is removed.
@MainActor
final class CefPasskeyAuthenticator {
    private weak var browser: CefBrowser?
    private let mode: CefPasskeyMode

    private struct Context {
        var origin: String
        var frameID: String
        /// The breakpoints on this context's `create` and `get`.
        var breakpoints: [String] = []
    }

    /// Default-world execution contexts by ID.
    private var contexts: [Int: Context] = [:]
    /// Each parsed script's execution context.
    private var scriptContexts: [String: Int] = [:]
    /// Breakpoint IDs by the request kind they report.
    private var breakpointKinds: [String: CefPasskeyRequest.Kind] = [:]
    private var mainFrameID: String?
    private var listeners: [Task<Void, Never>] = []
    /// The authenticator put in place for the latest call.
    private var authenticatorID: String?
    /// Credentials Chromium reported, by the authenticator that reported them.
    private var reported: [String: CefJSON] = [:]

    init(browser: CefBrowser, mode: CefPasskeyMode) {
        self.browser = browser
        self.mode = mode
    }

    /// Installs the environment and the breakpoints. Called before the
    /// browser loads its first page.
    func start() async throws {
        guard let browser else { throw CefError.browserClosed }
        let devTools = browser.devTools
        listen(devTools, "Runtime.executionContextCreated") { $0.contextCreated($1["context"]) }
        listen(devTools, "Runtime.executionContextDestroyed") { $0.contextDestroyed($1["executionContextId"].intValue) }
        listen(devTools, "Runtime.executionContextsCleared") { owner, _ in owner.contextsCleared() }
        listen(devTools, "Debugger.scriptParsed") { owner, event in
            if let script = event["scriptId"].stringValue, let context = event["executionContextId"].intValue {
                owner.scriptContexts[script] = context
            }
        }
        listen(devTools, "Debugger.paused") { owner, event in Task { await owner.paused(event) } }
        listen(devTools, "WebAuthn.credentialAdded") { $0.credentialReported($1) }
        listen(devTools, "WebAuthn.credentialAsserted") { $0.credentialReported($1) }

        try await devTools.send("WebAuthn.enable", ["enableUI": false])
        mainFrameID = try await devTools.send("Page.getFrameTree")["frameTree"]["frame"]["id"].stringValue
        try await devTools.send("Debugger.enable")
        try await devTools.send("Runtime.enable")
    }

    /// Ends the event streams. The browser's DevTools session ends with it.
    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    private func listen(
        _ devTools: CefDevTools, _ event: String, _ handler: @escaping @MainActor (CefPasskeyAuthenticator, CefJSON) -> Void
    ) {
        let stream = devTools.events(event)
        listeners.append(Task { [weak self] in
            for await parameters in stream {
                guard let self else { return }
                handler(self, parameters)
            }
        })
    }

    // MARK: Contexts and breakpoints

    private func contextCreated(_ context: CefJSON) {
        guard let id = context["id"].intValue, context["auxData"]["isDefault"].boolValue == true else { return }
        contexts[id] = Context(
            origin: context["origin"].stringValue ?? "",
            frameID: context["auxData"]["frameId"].stringValue ?? "")
        Task { await arm(id) }
    }

    private func contextDestroyed(_ id: Int?) {
        guard let id, let context = contexts.removeValue(forKey: id) else { return }
        for breakpoint in context.breakpoints {
            breakpointKinds[breakpoint] = nil
            let devTools = browser?.devTools
            Task { _ = try? await devTools?.send("Debugger.removeBreakpoint", ["breakpointId": .string(breakpoint)]) }
        }
    }

    private func contextsCleared() {
        contexts = [:]
        scriptContexts = [:]
        breakpointKinds = [:]
    }

    /// Sets the breakpoints on one context's `create` and `get`.
    private func arm(_ context: Int) async {
        guard let devTools = browser?.devTools else { return }
        for (name, kind) in [("create", CefPasskeyRequest.Kind.registration), ("get", .assertion)] {
            do {
                let function = try await devTools.send("Runtime.evaluate", [
                    "expression": .string("CredentialsContainer.prototype.\(name)"),
                    "contextId": .number(Double(context)), "silent": true,
                ])
                guard let object = function["result"]["objectId"].stringValue else { continue }
                let breakpoint = try await devTools.send("Debugger.setBreakpointOnFunctionCall", ["objectId": .string(object)])
                guard let id = breakpoint["breakpointId"].stringValue else { continue }
                guard contexts[context] != nil else {
                    _ = try? await devTools.send("Debugger.removeBreakpoint", ["breakpointId": .string(id)])
                    return
                }
                breakpointKinds[id] = kind
                contexts[context]?.breakpoints.append(id)
            } catch {
                // The context went away first, as a document that navigates
                // on at once does.
                return
            }
        }
    }

    // MARK: Answering

    private func paused(_ event: CefJSON) async {
        guard let devTools = browser?.devTools else { return }
        let frame = event["callFrames"][0]
        let kind = (event["hitBreakpoints"].arrayValue ?? []).compactMap { $0.stringValue.flatMap { breakpointKinds[$0] } }.first
        let contextID = scriptContexts[frame["location"]["scriptId"].stringValue ?? ""]
        if let kind, let contextID, let context = contexts[contextID] {
            let gesture = try? await devTools.send("Debugger.evaluateOnCallFrame", [
                "callFrameId": frame["callFrameId"], "expression": "navigator.userActivation.isActive",
                "silent": true, "throwOnSideEffect": true, "returnByValue": true,
            ])
            let request = CefPasskeyRequest(
                kind: kind, origin: context.origin,
                isMainFrame: context.frameID == mainFrameID,
                hasUserGesture: gesture?["result"]["value"].boolValue ?? false)
            await prepare(for: request)
        }
        // Anything else that stops the page, such as a `debugger`
        // statement, is not CefKit's to hold.
        _ = try? await devTools.send("Debugger.resume")
    }

    /// Decides `request` while the page is stopped before its call, and
    /// puts the authenticator in place that answers the call that way.
    private func prepare(for request: CefPasskeyRequest) async {
        // An authenticator left from an earlier call must not answer this
        // one unasked.
        await removeAuthenticator()
        guard let browser, browser.state == .live else { return }
        var request = request
        let decision: CefPasskeyDecision
        switch mode {
        case .app(let store):
            if request.kind == .assertion {
                request.passkeys = (try? await store.passkeys(usableOnHost: request.host)) ?? []
            }
            decision = await (browser.delegate ?? CefDefaultBrowserDelegate.shared)
                .browser(browser, decidePasskeyRequest: request)
        case .disabled, .chromium:
            decision = .deny
        }
        guard browser.state == .live else { return }

        switch (decision, request.kind) {
        case (.ignore, _):
            return
        case (.createPasskey, .registration):
            guard let id = await addAuthenticator() else { return }
            Task { await finish(id) { created in
                guard var passkey = CefPasskey(devToolsCredential: created) else { return }
                passkey.creationDate = .now
                try? await self.mode.store?.save(passkey)
            } }
        case (.signIn(let passkey), .assertion):
            guard let id = await addAuthenticator(holding: passkey) else { return }
            Task { await finish(id) { asserted in
                var used = passkey
                used.signCount = UInt32(clamping: asserted["signCount"].intValue ?? Int(passkey.signCount) + 1)
                used.lastUsedDate = .now
                try? await self.mode.store?.save(used)
            } }
        default:
            // A refusal: user verification fails, which ends the call with
            // `NotAllowedError` at once whatever verification it asks for.
            guard let id = await addAuthenticator(),
                  (try? await browser.devTools.send(
                      "WebAuthn.setUserVerified", ["authenticatorId": .string(id), "isUserVerified": false])) != nil
            else { return }
            Task { await finish(id, timeout: .seconds(1)) { _ in } }
        }
    }

    private func addAuthenticator(holding passkey: CefPasskey? = nil) async -> String? {
        guard let devTools = browser?.devTools else { return nil }
        do {
            let added = try await devTools.send("WebAuthn.addVirtualAuthenticator", ["options": [
                "protocol": "ctap2", "ctap2Version": "ctap2_1", "transport": "internal",
                "hasResidentKey": true, "hasUserVerification": true, "isUserVerified": true,
                "automaticPresenceSimulation": true,
            ]])
            guard let id = added["authenticatorId"].stringValue else { return nil }
            authenticatorID = id
            if let passkey {
                try await devTools.send("WebAuthn.addCredential", ["authenticatorId": .string(id), "credential": passkey.devToolsCredential])
            }
            return id
        } catch {
            CefLog.error("passkeys: could not set up an authenticator: \(error)")
            await removeAuthenticator()
            return nil
        }
    }

    /// Waits for the credential authenticator `id` reports, hands it to
    /// `body`, and removes the authenticator. The page may end its call
    /// instead (it aborts, navigates or times out); then nothing is reported.
    private func finish(_ id: String, timeout: Duration = .seconds(30), _ body: (CefJSON) async -> Void) async {
        let deadline = ContinuousClock.now + timeout
        while reported[id] == nil, authenticatorID == id, ContinuousClock.now < deadline, browser?.state == .live {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let credential = reported.removeValue(forKey: id) {
            await body(credential)
            // Leave the authenticator a moment to hand its response over.
            try? await Task.sleep(for: .milliseconds(200))
        }
        if authenticatorID == id { await removeAuthenticator() }
    }

    private func credentialReported(_ event: CefJSON) {
        guard let id = event["authenticatorId"].stringValue, id == authenticatorID else { return }
        reported[id] = event["credential"]
    }

    private func removeAuthenticator() async {
        guard let id = authenticatorID, let devTools = browser?.devTools else { return }
        authenticatorID = nil
        reported[id] = nil
        _ = try? await devTools.send("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": .string(id)])
    }
}

// MARK: - DevTools credential form

extension CefPasskey {
    /// A credential from the `WebAuthn` domain, whose binary fields are
    /// standard base64.
    init?(devToolsCredential json: CefJSON) {
        guard let id = json["credentialId"].stringValue.flatMap(Data.init(base64OrBase64URL:)),
              let party = json["rpId"].stringValue,
              let key = json["privateKey"].stringValue.flatMap(Data.init(base64OrBase64URL:))
        else { return nil }
        self.init(
            id: id, relyingPartyID: party,
            userHandle: json["userHandle"].stringValue.flatMap(Data.init(base64OrBase64URL:)) ?? Data(),
            userName: json["userName"].stringValue ?? "",
            userDisplayName: json["userDisplayName"].stringValue ?? "",
            privateKey: key,
            signCount: UInt32(clamping: json["signCount"].intValue ?? 0))
    }

    /// The `WebAuthn.Credential` that hands this passkey to an authenticator.
    var devToolsCredential: CefJSON {
        [
            "credentialId": .string(id.base64EncodedString()),
            "isResidentCredential": true,
            "rpId": .string(relyingPartyID),
            "privateKey": .string(privateKey.base64EncodedString()),
            "userHandle": .string(userHandle.base64EncodedString()),
            "signCount": .number(Double(signCount)),
            "userName": .string(userName),
            "userDisplayName": .string(userDisplayName),
        ]
    }
}

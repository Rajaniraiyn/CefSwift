import Foundation

/// Reads whether an Alloy-style browser's page plays sound or has form
/// input from Chromium's performance-manager graph, through the Mojo
/// interface behind the Graph tab of `chrome://discards`.
///
/// Chromium's performance manager keeps a `PageNode` for every
/// `WebContents`, Alloy-style browsers' included, and a `FrameNode` for
/// each of its frames. The page node knows what Chromium's own discard
/// rules ask (`DiscardEligibilityPolicy`): whether the page is audible
/// (`PageNode::IsAudible`, from the `WebContents`' audio stream monitor,
/// so any frame, media element or Web Audio counts, and a muted element
/// does not), when that last changed, and whether a frame had form
/// interaction or user edits (`HadFormInteraction`, `HadUserEdits`, which
/// Blink reports from the renderer). Nothing reads the page's content.
///
/// `discards.mojom.GraphDump` streams the graph's nodes to a
/// `GraphChangeStream`, each with the JSON of Chromium's node data
/// describers (`PageNodeImplDescriber`, `FrameNodeImplDescriber`), and
/// describes nodes on request (`RequestNodeDescriptions`). The service
/// host subscribes once per document and keeps, per frame node, its page
/// and its frame token, which is what CEF's frame identifier carries
/// (`"<render process id in hexadecimal>-<frame token>"`); a browser's page is therefore
/// found exactly, by its main frame, with no guessing by address or title.
/// Each look-up then asks for that page's current description.
///
/// The describers' JSON is Chromium-private and unversioned: a node that
/// cannot be found, or a description without the fields CefKit reads, is a
/// blocker, ``CefBrowser/DiscardBlocker/unknown(_:)``, never "safe".
/// The SelfTest checks (`discard blockers (view): …`) fail when a CEF
/// update changes them.
@MainActor
enum CefPageGraph {
    /// The audio and form blockers of an Alloy-style `browser`'s page; a
    /// failed look-up is a blocker too.
    static func blockers(for browser: CefBrowser) async -> Set<CefBrowser.DiscardBlocker> {
        let identifier = browser.mainFrameIdentifier
        guard let token = Self.frameToken(fromFrameIdentifier: identifier) else {
            return [.unknown("CEF's main frame identifier carries no frame token: \(identifier ?? "none")")]
        }
        do {
            // The browser process has one graph for every profile, so the
            // default profile's host serves them all.
            let reply = try await CefProfile.default.serviceHosts.call(
                Self.module, "(s, a) => s.describe(a.token)", ["token": .string(token)], timeout: .seconds(10))
            return Self.blockers(fromDescription: reply)
        } catch {
            return [.unknown("chrome://discards graph: \(error)")]
        }
    }

    /// The frame token in a CEF frame identifier, `"<render process id in
    /// hexadecimal>-<frame token>"` (`frame_util::MakeFrameIdentifier`;
    /// `"6-…"` and `"1A-…"` seen), as the graph's `frame_token` spells it:
    /// 32 hexadecimal digits.
    static func frameToken(fromFrameIdentifier identifier: String?) -> String? {
        guard let parts = identifier?.split(separator: "-"), parts.count == 2, Int(parts[0], radix: 16) != nil else {
            return nil
        }
        let token = parts[1].uppercased()
        guard token.count == 32, token.allSatisfy(\.isHexDigit) else { return nil }
        return token
    }

    /// How long after a page falls silent Chromium still protects it
    /// (`kTabAudioProtectionTime`, `discard_eligibility_policy.cc`).
    static let audioProtectionTime: Duration = .seconds(60)

    /// The blockers a look-up's reply (``module``'s `describe`) reports:
    /// `{found: false}`, or `{found: true, page: <the page node's
    /// description>}`.
    static func blockers(fromDescription reply: CefJSON) -> Set<CefBrowser.DiscardBlocker> {
        guard reply["found"].boolValue == true else {
            return [.unknown("Chromium's page graph has no frame with this browser's main frame token.")]
        }
        let page = reply["page"]["PageNodeImpl"]
        guard let audible = page["is_audible"].boolValue, let formInteraction = page["had_form_interaction"].boolValue,
              let userEdits = page["had_user_edits"].boolValue
        else {
            return [.unknown("Chromium's page graph described the page without its audio and form state.")]
        }
        var blockers = Set<CefBrowser.DiscardBlocker>()
        if audible {
            blockers.insert(.playingAudio)
        } else if let changed = page["audible_change_time"].stringValue {
            // Present once the page has been audible.
            guard let since = elapsed(fromDescriberTime: changed) else {
                return [.unknown("Chromium's page graph gave a time CefKit cannot read: \(changed)")]
            }
            if since < audioProtectionTime { blockers.insert(.playingAudio) }
        }
        if formInteraction || userEdits { blockers.insert(.formInteraction) }
        return blockers
    }

    /// A time the describers give as how long ago it was,
    /// `"<h> hr, <m> min, <s> sec"` (`TimeDeltaFromNowToValue`,
    /// `node_data_describer_util.cc`).
    static func elapsed(fromDescriberTime text: String) -> Duration? {
        let fields = text.split(separator: ",").map { $0.split(separator: " ") }
        guard fields.count == 3, fields.map({ $0.last }) == ["hr", "min", "sec"],
              let hours = fields[0].first.flatMap({ Int($0) }), let minutes = fields[1].first.flatMap({ Int($0) }),
              let seconds = fields[2].first.flatMap({ Int($0) }), fields.allSatisfy({ $0.count == 2 })
        else { return nil }
        return .seconds(hours * 3600 + minutes * 60 + seconds)
    }

    /// Keeps the frames of Chromium's graph by node id, from a
    /// subscription that lasts as long as the host's document:
    /// `frames.get(id) = {page, token}`. `(event, frame | id)` is applied
    /// for each event: `created` and `changed` carry a `FrameInfo`,
    /// `deleted` a node id.
    static let frameStore = """
        (frames, event, value) => {
          if (event === 'deleted') { frames.delete(value); return; }
          let token;
          try { token = JSON.parse(value.descriptionJson).FrameNodeImpl.frame_token; } catch {}
          frames.set(value.id, { page: value.pageId, token: token ?? frames.get(value.id)?.token });
        }
        """

    /// Subscribes to the graph and waits for its first dump, which arrives
    /// at once and has no end marker: until no node has arrived for 50 ms.
    /// `describe(token)` then finds the page of the frame with that token
    /// and asks Chromium for its description.
    static let module = CefServiceHost.Module(
        name: "discards-graph", hosts: [.discards],
        setup: """
        async () => {
          const m = await import('chrome://discards/discards.mojom-webui.js');
          const graph = m.GraphDump.getRemote();
          const router = new m.GraphChangeStreamCallbackRouter();
          const frames = new Map(), apply = \(frameStore);
          let last = performance.now(), broken = false;
          const on = event => value => { last = performance.now(); apply(frames, event, value); };
          router.frameCreated.addListener(on('created'));
          router.frameChanged.addListener(on('changed'));
          router.nodeDeleted.addListener(on('deleted'));
          router.onConnectionError.addListener(() => { broken = true; });
          graph.subscribeToChanges(router.$.bindNewPipeAndPassRemote());
          const sleep = ms => new Promise(r => setTimeout(r, ms));
          const start = performance.now();
          while (performance.now() - start < 3000 && (frames.size === 0 || performance.now() - last < 50)) await sleep(10);
          if (frames.size === 0) throw new Error('GraphDump sent no frames');
          const find = token => { for (const f of frames.values()) if (f.token === token) return f; };
          const describe = async token => {
            if (broken) {
              // The next call subscribes again.
              delete window.__cefswiftServices?.['discards-graph'];
              throw new Error('GraphDump disconnected');
            }
            let frame = find(token);
            // A frame created a moment ago may not have arrived yet.
            for (let i = 0; !frame && i < 10; i++) { await sleep(20); frame = find(token); }
            if (!frame) return { found: false };
            const { nodeDescriptionsJson } = await graph.requestNodeDescriptions([frame.page]);
            const json = nodeDescriptionsJson.get(frame.page);
            return { found: json !== undefined, page: json === undefined ? null : JSON.parse(json) };
          };
          return { describe };
        }
        """)
}

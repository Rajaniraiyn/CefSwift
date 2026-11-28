import CefProtectedMedia
import CefSwiftUI
import SwiftUI

/// CefProtectedMedia's `CefFairPlay` plays FairPlay Streaming audio in
/// Chromium pages of the origins an app lists, Spotify's web player first,
/// through the FairPlay service the gallery's `fairPlay` capability adds.
/// The demo opens Spotify with it on, lets you add an origin, and shows
/// what the delegate hears: a failure the app would answer by opening the
/// page in WebKit, and the player starting and stopping. Playing needs a
/// Spotify account.
struct FairPlayDemo: Demo {
    let title = "FairPlay in Chromium"
    let summary = "Spotify's protected audio in a Chromium page, played by AVFoundation in a sandboxed service, for an allowlist of origins."
    let symbol = "lock.shield"
    let category = DemoCategory.page

    func makeView() -> some View { FairPlayDemoView() }

    static let page = SamplePage("fairplay/index.html", title: "FairPlay in Chromium", body: """
        <h1>FairPlay in Chromium</h1>
        <p>This page's origin is not on the list, so it gets Chromium's own EME:
        <code id=answer>…</code></p>
        <p><a href="https://open.spotify.com/">Open Spotify's web player</a>, which is on the list: sign in and play a
        track, and its audio plays through the FairPlay service while the page's player shows its progress.</p>
        <script>
          navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', [{ initDataTypes: ['skd'] }])
            .then((a) => a.keySystem, (e) => e.name).then((r) => { document.getElementById('answer').textContent = r; });
        </script>
        """)
}

@MainActor
private final class FairPlayDemoModel: CefFairPlayDelegate {
    let fairPlay = CefFairPlay(origins: CefFairPlay.spotify)
    var events: [String] = []
    var onChange: () -> Void = {}

    init() {
        fairPlay.delegate = self
        fairPlay.install(in: .default)
    }

    func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didFail error: CefFairPlayError) {
        events.insert("Failed: \(error). An app would open the page in WebKit now.", at: 0)
        onChange()
    }

    func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didChangePlaying isPlaying: Bool) {
        events.insert(isPlaying ? "The FairPlay service is playing." : "The FairPlay service stopped.", at: 0)
        onChange()
    }

    static let shared = FairPlayDemoModel()
}

private struct FairPlayDemoView: View {
    @State private var page = CefPage(url: FairPlayDemo.page.url)
    @State private var origin = ""
    @State private var events: [String] = []
    @State private var origins: [String] = []
    private let model = FairPlayDemoModel.shared

    var body: some View {
        HSplitView {
            CefWebView(page).frame(minWidth: 420)
            Form {
                Section("Service") {
                    LabeledContent("FairPlay service", value: CefFairPlay.isServiceAvailable ? "In the bundle" : "Missing")
                }
                Section("Origins") {
                    ForEach(origins, id: \.self) { Text($0).font(.body.monospaced()) }
                    HStack {
                        TextField("https://music.example", text: $origin)
                        Button("Add") {
                            model.fairPlay.origins.insert(origin)
                            origins = model.fairPlay.origins.sorted()
                            origin = ""
                        }
                    }
                }
                Section("What the delegate heard") {
                    if events.isEmpty { Text("Nothing yet. Sign in to Spotify and play a track.").foregroundStyle(.secondary) }
                    ForEach(events, id: \.self) { Text($0) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 280)
        }
        .onAppear {
            origins = model.fairPlay.origins.sorted()
            model.onChange = { events = model.events }
        }
        .reportReady { try await page.waitUntilLoaded(timeout: .seconds(30)) }
        .onDisappear { page.close(force: true) }
    }
}

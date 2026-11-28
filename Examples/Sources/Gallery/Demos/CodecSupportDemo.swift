import CefSwiftUI
import SwiftUI

/// What this build of Chromium decodes, asked the three ways a page asks:
/// `canPlayType`, `MediaSource.isTypeSupported` and WebCodecs'
/// `isConfigSupported`. With the gallery's `services.systemMediaDecoders =
/// .audio`, the system audio codecs answer yes through the first two; H.264
/// and HEVC answer no everywhere, which is why such pages go to WebKit
/// (docs/design-notes.md, "System video decoders: measured, not built").
struct CodecSupportDemo: Demo {
    let title = "Codec Support"
    let summary = "Which audio and video codecs pages can play here, through media elements, Media Source Extensions and WebCodecs."
    let symbol = "film.stack"
    let category = DemoCategory.page

    func makeView() -> some View { CodecSupportDemoView() }
}

private struct CodecSupportDemoView: View {
    @State private var page = CefPage(url: CodecSupportDemo.page.url)

    var body: some View {
        CefWebView(page)
            .reportReady { try await page.waitUntilLoaded(timeout: .seconds(30)) }
            .onDisappear { page.close(force: true) }
    }
}

extension CodecSupportDemo {
    static let page = SamplePage("codec-support/index.html", title: "Codec support", body: """
        <h1>Codec support</h1>
        <p class=muted>Each row asks this Chromium whether it plays the codec. "MSE" is
        <code>MediaSource.isTypeSupported</code>, "Element" is <code>canPlayType</code>, "WebCodecs" is
        <code>VideoDecoder</code> or <code>AudioDecoder</code>'s <code>isConfigSupported</code>.</p>
        <table id=codecs style="border-collapse: collapse; width: 100%">
          <tr><th align=left>Codec</th><th>MSE</th><th>Element</th><th>WebCodecs</th></tr>
        </table>
        <script>
          const rows = [
            ['H.264', 'video/mp4', 'avc1.640028', 'video'], ['HEVC', 'video/mp4', 'hvc1.1.6.L120.90', 'video'],
            ['VP9', 'video/mp4', 'vp09.00.10.08', 'video'], ['AV1', 'video/mp4', 'av01.0.04M.08', 'video'],
            ['AAC-LC', 'audio/mp4', 'mp4a.40.2', 'audio'], ['HE-AAC', 'audio/mp4', 'mp4a.40.5', 'audio'],
            ['Apple Lossless', 'audio/mp4', 'alac', 'audio'], ['AC-3', 'audio/mp4', 'ac-3', 'audio'],
            ['E-AC-3', 'audio/mp4', 'ec-3', 'audio'], ['Opus', 'audio/mp4', 'opus', 'audio'], ['FLAC', 'audio/mp4', 'flac', 'audio'],
          ];
          const mark = (yes) => yes ? '✓' : '—';
          (async () => {
            const table = document.getElementById('codecs');
            for (const [name, mime, codec, kind] of rows) {
              const type = `${mime}; codecs="${codec}"`;
              const element = document.createElement(kind).canPlayType(type);
              const config = kind === 'video' ? { codec, codedWidth: 1280, codedHeight: 720 } : { codec, sampleRate: 48000, numberOfChannels: 2 };
              let webCodecs = false;
              try { webCodecs = (await (kind === 'video' ? VideoDecoder : AudioDecoder).isConfigSupported(config)).supported; } catch (e) {}
              const row = table.insertRow();
              row.innerHTML = `<td><b>${name}</b> <code>${codec}</code></td><td align=center>${mark(MediaSource.isTypeSupported(type))}</td>` +
                `<td align=center>${element || '—'}</td><td align=center>${mark(webCodecs)}</td>`;
            }
          })();
        </script>
        """)
}

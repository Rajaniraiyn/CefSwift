import AppKit
@_spi(Testing) import CefKit

/// What the design notes' "System video decoders: measured, not built"
/// rests on, checked against the running CEF so that an update that opens
/// a route shows up: Chromium decodes no H.264 or HEVC, through MSE or
/// WebCodecs; it decodes and encodes VP9, and accepts it in MP4 through
/// MSE, which a placeholder track would need.
extension SelfTest {
    static func videoRouteChecks() async {
        let page = CefPage(url: URL(string: "selftest://media/index.html")!)
        let view = hostWindowed(page)
        defer {
            page.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(page) else {
            check("video routes: page loads", false)
            return
        }
        let routes = try? await page.evaluateJavaScript("""
            (async () => {
              const decode = async (codec) => (await VideoDecoder.isConfigSupported({ codec, codedWidth: 1280, codedHeight: 720 })).supported;
              const encode = async (codec) => (await VideoEncoder.isConfigSupported({ codec, width: 1280, height: 720, bitrate: 2e6 })).supported;
              return {
                mseH264: MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"'),
                mseHEVC: MediaSource.isTypeSupported('video/mp4; codecs="hvc1.1.6.L120.90"'),
                mseVP9: MediaSource.isTypeSupported('video/mp4; codecs="vp09.00.10.08"'),
                decodeH264: await decode('avc1.640028'), decodeHEVC: await decode('hvc1.1.6.L120.90'),
                decodeVP9: await decode('vp09.00.10.08'), encodeVP9: await encode('vp09.00.10.08'),
              };
            })()
            """)
        check("video routes: Chromium decodes no H.264 or HEVC, through MSE or WebCodecs",
              ["mseH264", "mseHEVC", "decodeH264", "decodeHEVC"].allSatisfy { routes?[$0].boolValue == false },
              detail: routes?.text ?? "no result")
        check("video routes: VP9 in MP4 through MSE, and VP9 through WebCodecs both ways",
              ["mseVP9", "decodeVP9", "encodeVP9"].allSatisfy { routes?[$0].boolValue == true },
              detail: routes?.text ?? "no result")
    }
}

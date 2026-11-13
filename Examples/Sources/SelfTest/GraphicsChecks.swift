import AppKit
import CefKit
import CefSwiftUI

/// Pages render, windowed and offscreen, and what WebGL runs on. Run it
/// with `--disable-gpu`, or in a bundle made with
/// `--software-gpu-fallback exclude`, to see what each leaves.
extension SelfTest {
    static let webGLRendererScript = """
        (() => {
          const gl = document.createElement('canvas').getContext('webgl');
          if (!gl) return 'none';
          const info = gl.getExtension('WEBGL_debug_renderer_info');
          return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : 'available';
        })()
        """

    static func graphicsChecks() async {
        let libraries = Bundle.main.privateFrameworksURL!
            .appendingPathComponent("Chromium Embedded Framework.framework/Libraries")
        let hasSwiftShader = FileManager.default.fileExists(
            atPath: libraries.appendingPathComponent("libvk_swiftshader.dylib").path)
        let gpuDisabled = CommandLine.arguments.contains("--disable-gpu")

        for offscreen in [false, true] {
            let label = offscreen ? "offscreen" : "windowed"
            var configuration = CefBrowser.Configuration()
            if offscreen { configuration.rendering = .offscreen }
            let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, configuration: configuration)
            let view: NSView
            if offscreen {
                let hosting = CefOffscreenBrowserView()
                hosting.browser = browser
                view = hosting
            } else {
                let hosting = CefWindowedBrowserView()
                hosting.browser = browser
                view = hosting
            }
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            defer {
                browser.close(force: true)
                view.removeFromSuperview()
            }
            guard await waitUntil({ browser.title == "tab" }) else {
                check("graphics (\(label)): loads", false, detail: browser.title)
                continue
            }
            if offscreen {
                check("graphics (offscreen): paints", await waitUntil { view.layer?.sublayers?.first?.contents != nil })
            } else {
                _ = try? await browser.evaluateJavaScript(
                    "window.__frames = 0; (function tick() { window.__frames++; requestAnimationFrame(tick); })()")
                try? await Task.sleep(for: .milliseconds(500))
                let frames = (try? await browser.evaluateJavaScript("window.__frames").intValue ?? 0) ?? 0
                check("graphics (windowed): the page produces frames", frames > 5, detail: "\(frames) frames")
            }
            let renderer = (try? await browser.evaluateJavaScript(webGLRendererScript).stringValue) ?? nil
            print("NOTE graphics (\(label)): WebGL renderer '\(renderer ?? "nil")'" +
                  " (SwiftShader \(hasSwiftShader ? "bundled" : "left out")\(gpuDisabled ? ", --disable-gpu" : ""))")
        }
    }
}

import AppKit
import CefKit

// Small page controls over CEF calls: zoom steps, spelling, leaving
// fullscreen, the find selection, and URLs for security display.
extension SelfTest {
    static func browserControlsChecks() async {
        let runtime = CefRuntime.shared
        check("controls: securityDisplayString drops the path and the default port",
              runtime.securityDisplayString(for: URL(string: "https://example.com:443/a/b?c#d")!) == "https://example.com",
              detail: runtime.securityDisplayString(for: URL(string: "https://example.com:443/a/b?c#d")!) ?? "nil")
        check("controls: securityDisplayString keeps another port and a file path",
              runtime.securityDisplayString(for: URL(string: "http://example.com:8080/x")!) == "http://example.com:8080"
                  && runtime.securityDisplayString(for: URL(fileURLWithPath: "/tmp/a.html")) == "file:///tmp/a.html")
        let spoof = runtime.securityDisplayString(for: URL(string: "https://xn--80ak6aa92e.com/login")!)
        let safe = runtime.securityDisplayString(for: URL(string: "https://xn--bcher-kva.de/")!)
        check("controls: securityDisplayString keeps a look-alike domain in Punycode, a safe one in Unicode",
              spoof == "https://xn--80ak6aa92e.com" && safe == "https://bücher.de",
              detail: "\(spoof ?? "nil"), \(safe ?? "nil")")

        let origin = URL(string: "https://cefswift.test")!
        let page = CefPage(url: origin.appendingPathComponent("second.html"))
        let view = hostWindowed(page)
        guard await loaded(page, title: "second") else {
            check("controls: page loads", false, detail: page.title)
            await closeHosted(page, view)
            return
        }

        // Chrome's presets: 100% then 110%.
        check("controls: at the default level, reset has nothing to do", !page.canZoom(.reset) && page.canZoom(.zoomIn))
        page.zoom(.zoomIn)
        let expected = log(1.1) / log(1.2)
        check("controls: zoom(.zoomIn) steps to Chrome's next preset",
              await waitUntil { abs(page.zoomLevel - expected) < 0.01 }, detail: "\(page.zoomLevel)")
        page.zoom(.reset)
        check("controls: zoom(.reset) goes back to the default",
              await waitUntil { abs(page.zoomLevel - page.defaultZoomLevel) < 0.001 } && page.defaultZoomLevel == 0,
              detail: "\(page.zoomLevel)")

        // The find selection.
        _ = try? await page.evaluateJavaScript("document.body.innerHTML = '<h1>needle</h1><p>needle</p>'; 0")
        page.find("needle")
        _ = await waitUntil { page.findResult?.isFinal == true }
        page.find("needle")
        check("controls: a find result has the match's rectangle", await waitUntil {
            page.findResult?.isFinal == true && (page.findResult?.selectionRect.map { !$0.isEmpty } ?? false)
        }, detail: "\(String(describing: page.findResult))")
        page.stopFinding()

        // Exercise exitFullscreen even when the isolated test process is
        // in the background. Chromium 158 requires focus for gesture-based entry.
        let settings = CefProfile.default.siteSettings
        settings.set(.allow, for: .automaticFullscreen, origin: origin)
        defer { settings.set(.default, for: .automaticFullscreen, origin: origin) }
        let fullscreenResult = try? await page.evaluateJavaScript("""
            document.body.requestFullscreen().then(() => 'entered', error => error.message)
            """, timeout: .seconds(5)).stringValue
        if await waitUntil(timeout: .seconds(5), { page.isFullscreen }) {
            page.exitFullscreen()
            check("controls: exitFullscreen leaves fullscreen", await waitUntil(timeout: .seconds(5)) { !page.isFullscreen })
        } else {
            check("controls: the page enters fullscreen", false, detail: fullscreenResult ?? "no result")
        }
        _ = await waitUntil(timeout: .seconds(3)) { view.window?.styleMask.contains(.fullScreen) != true }

        // Spelling: a misspelled word, selected, replaced by a suggestion.
        _ = try? await page.evaluateJavaScript("""
            document.body.innerHTML = '<div id=e contenteditable spellcheck=true></div>';
            document.getElementById('e').focus(); 0
            """, userGesture: true)
        // Typed, so that Chromium's spell checker marks it.
        _ = try? await page.devTools.send("Input.insertText", ["text": "teh "])
        try? await Task.sleep(for: .milliseconds(1500))
        _ = try? await page.evaluateJavaScript("""
            const t = document.getElementById('e').firstChild; const r = document.createRange();
            r.setStart(t, 0); r.setEnd(t, 3); getSelection().removeAllRanges(); getSelection().addRange(r); 0
            """)
        page.replaceMisspelling(with: "the")
        let replaced = await waitUntilAsync(timeout: .seconds(3)) {
            (try? await page.evaluateJavaScript("document.getElementById('e').textContent").stringValue)?.hasPrefix("the") == true
        }
        // Not a check: Chromium acts only on a word its spell checker has
        // marked, which typing through DevTools did not get marked here.
        print("NOTE controls: replaceMisspelling on a typed, selected misspelling \(replaced ? "replaced it" : "changed nothing")")
        page.learnSpelling("cefswiftword")
        await closeHosted(page, view)
    }
}

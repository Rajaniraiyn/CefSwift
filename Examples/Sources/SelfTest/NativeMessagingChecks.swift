import Foundation
@_spi(Testing) import CefKit

/// Native messaging hosts found through
/// `CefRuntime.Configuration.nativeMessagingHostDirectories`, as a password
/// manager's are in Google Chrome's directory: part of the `extensions`
/// probe. The first phase installs an echo host in a directory of its own,
/// as another app would for Chrome, and the test extension talks to it; the
/// relaunch has uninstalled it, and the extension no longer finds it.
extension SelfTest {
    static let nativeHostName = "dev.cefswift.selftest.echo"

    /// The directory standing in for `~/Library/Application Support/Google/Chrome/NativeMessagingHosts`.
    static func nativeHostDirectory(in root: URL) -> URL {
        root.appendingPathComponent("chrome-native-messaging-hosts", isDirectory: true)
    }

    /// Writes the echo host before Chromium starts (first phase) or removes
    /// it (relaunch), and lists its directory in the configuration.
    static func configureNativeMessagingProbe(_ configuration: inout CefRuntime.Configuration, root: URL) {
        let directory = nativeHostDirectory(in: root)
        let manifest = directory.appendingPathComponent("\(nativeHostName).json")
        configuration.nativeMessagingHostDirectories = [directory]
        guard ProcessInfo.processInfo.environment[extensionPhaseKey] != "2" else {
            try? FileManager.default.removeItem(at: manifest)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Echoes each message (a length and JSON, which `cat` copies
        // unchanged), and records the caller Chromium names in its argument.
        let host = directory.appendingPathComponent("echo-host.sh")
        let origin = directory.appendingPathComponent("caller.txt")
        try? Data("#!/bin/sh\nprintf '%s' \"$1\" > '\(origin.path)'\nexec /bin/cat\n".utf8).write(to: host)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        let json: [String: Any] = [
            "name": nativeHostName, "description": "SelfTest echo host", "path": host.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(ExtensionFixture.id)/"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: manifest) }
    }

    static let connectNativeScript = """
        new Promise(resolve => {
          const port = chrome.runtime.connectNative('\(nativeHostName)');
          port.onMessage.addListener(m => { resolve('message ' + JSON.stringify(m)); port.disconnect(); });
          port.onDisconnect.addListener(() => resolve('disconnected ' + chrome.runtime.lastError?.message));
          port.postMessage({echo: 'hello', n: 42});
          setTimeout(() => resolve('no reply'), 5000);
        })
        """

    static func nativeMessagingChecks() async {
        guard let root = CefRuntime.shared.configuration?.rootCacheDirectory else { return }
        let link = root.appendingPathComponent("NativeMessagingHosts/\(nativeHostName).json")
        let (window, page) = await extensionWindow(
            URL(string: "chrome-extension://\(ExtensionFixture.id)/options.html")!, toolbar: .none)
        defer { window.close() }
        if ProcessInfo.processInfo.environment[extensionPhaseKey] == "2" {
            check("an uninstalled host's link in the root cache directory is removed at start-up",
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
            await expect("the extension no longer finds the uninstalled host") {
                let value = try await page.evaluateJavaScript(connectNativeScript, timeout: .seconds(10))
                let text = value.stringValue ?? value.text
                return (text.hasPrefix("disconnected") && text.contains("not found"), text)
            }
            return
        }
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        check("a host in nativeMessagingHostDirectories is linked into the root cache directory",
              target?.hasSuffix("\(nativeHostName).json") == true, detail: target ?? "no link")
        await expect("chrome.runtime.connectNative reaches the host another app installed for Chrome, which echoes") {
            let value = try await page.evaluateJavaScript(connectNativeScript, timeout: .seconds(10))
            let text = value.stringValue ?? value.text
            return (text == #"message {"echo":"hello","n":42}"#, text)
        }
        await expect("chrome.runtime.sendNativeMessage reaches it too") {
            let value = try await page.evaluateJavaScript("""
                chrome.runtime.sendNativeMessage('\(nativeHostName)', {ping: true})
                  .then(m => JSON.stringify(m), e => 'error ' + e.message)
                """, timeout: .seconds(10))
            let text = value.stringValue ?? value.text
            return (text == #"{"ping":true}"#, text)
        }
        let caller = try? String(contentsOf: nativeHostDirectory(in: root).appendingPathComponent("caller.txt"), encoding: .utf8)
        check("Chromium starts the host naming the calling extension",
              caller == "chrome-extension://\(ExtensionFixture.id)/", detail: caller ?? "nothing recorded")
    }
}

import CefSwiftUI
import SwiftUI

/// A `CefProfile` holds cookies, storage and cache. The default profile
/// keeps them on disk; an incognito profile keeps them in memory and drops
/// them with the profile. Browsers in different profiles share nothing.
struct ProfilesDemo: Demo {
    let title = "Profiles and Cookies"
    let summary = "The same page in the default profile, kept on disk, and in an incognito one: each keeps its own cookies, read back from Swift."
    let symbol = "person.2"
    let category = DemoCategory.network

    func makeView() -> some View { ProfilesView() }
}

private struct ProfilesView: View {
    @State private var onDisk = CefBrowser.inProfile(.default)
    @State private var incognito = CefBrowser.inProfile(.incognito())

    var body: some View {
        HStack(spacing: 1) {
            ProfilePane(browser: onDisk, name: "Default, on Disk", symbol: "externaldrive")
            ProfilePane(browser: incognito, name: "Incognito", symbol: "eyeglasses")
        }
        .background(.separator)
        .readyWhenLoaded(onDisk, incognito)
        .onDisappear {
            onDisk.close(force: true)
            incognito.close(force: true)
        }
    }
}

private struct ProfilePane: View {
    let browser: CefBrowser
    let name: String
    let symbol: String
    @State private var cookies: [HTTPCookie] = []

    var body: some View {
        VStack(spacing: 0) {
            Label(name, systemImage: symbol).font(.headline).padding(8)
            CefWebView(browser)
            List(cookies, id: \.name) { cookie in
                LabeledContent(cookie.name, value: cookie.value)
            }
            .frame(height: 120)
            .overlay { if cookies.isEmpty { Text("No cookies").foregroundStyle(.secondary) } }
            Button("Delete Cookies", role: .destructive) {
                browser.configuration.profile?.deleteCookies(for: ProfilesPages.page.localURL)
                browser.reload()
            }
            .padding(8)
        }
        .background(.background)
        // The profile's cookies for the page, read again after every load.
        .task(id: browser.isLoading) {
            guard !browser.isLoading, let profile = browser.configuration.profile else { return }
            cookies = await profile.cookies(for: ProfilesPages.page.localURL)
        }
    }
}

private extension CefBrowser {
    static func inProfile(_ profile: CefProfile) -> CefBrowser {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        return CefBrowser(url: ProfilesPages.page.localURL, configuration: configuration)
    }
}

private enum ProfilesPages {
    // On http://localhost, since cookies belong to a host.
    static let page = SamplePage("cookies.html", title: "Cookies", body: """
        <h1>Visits: <span id=visits></span></h1>
        <p>A cookie counts your visits. Reload, and relaunch the gallery: the count on disk goes on, the incognito one starts again.</p>
        <button onclick="location.reload()">Visit Again</button>
        <script>
          const visits = Number(document.cookie.match(/visits=(\\d+)/)?.[1] ?? 0) + 1;
          document.cookie = `visits=${visits}; max-age=31536000; path=/`;
          document.getElementById('visits').textContent = visits;
        </script>
        """)
}

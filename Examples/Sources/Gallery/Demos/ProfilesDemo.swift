import CefSwiftUI
import SwiftUI

/// A `CefProfile` holds cookies, storage and cache. A persistent profile
/// keeps them on disk, in a directory of its own, and finds them again at
/// the next launch; an incognito profile keeps them in memory and drops
/// them with the profile. Pages in different profiles share nothing.
struct ProfilesDemo: Demo {
    let title = "Profiles and Cookies"
    let summary = "The same page in a persistent profile, kept on disk, and in an incognito one: each keeps its own cookies, read back from Swift."
    let symbol = "person.2"
    let category = DemoCategory.network

    func makeView() -> some View { ProfilesView() }
}

private struct ProfilesView: View {
    // Chromium loads a persistent profile in the background the first
    // time it is used; the page waits for it by itself.
    @ViewState private var onDisk = CefPage.inProfile(.persistent(id: "gallery", displayName: "Gallery"))
    @ViewState private var incognito = CefPage.inProfile(.incognito())

    var body: some View {
        HStack(spacing: 1) {
            ProfilePane(page: onDisk, name: "Persistent, on Disk", symbol: "externaldrive")
            ProfilePane(page: incognito, name: "Incognito", symbol: "eyeglasses")
        }
        .background(.separator)
        .reportReady {
            // Throws CefError.profileUnavailable if Chromium could not
            // give the profile its directory: it never falls back to memory.
            try await onDisk.configuration.profile?.ready()
            for page in [onDisk, incognito] {
                try await page.waitUntilLoaded(timeout: .seconds(30))
            }
        }
        .onDisappear {
            onDisk.close(force: true)
            incognito.close(force: true)
        }
    }
}

private struct ProfilePane: View {
    let page: CefPage
    let name: String
    let symbol: String
    @ViewState private var cookies: [CefProfile.Cookie] = []
    @ViewState private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Label(name, systemImage: symbol).font(.headline).padding(8)
            if let failure {
                ContentUnavailableView("Profile Unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                CefWebView(page)
            }
            List(cookies, id: \.name) { cookie in
                LabeledContent(cookie.name, value: cookie.value)
            }
            .frame(height: 120)
            .overlay { if cookies.isEmpty { Text("No cookies").foregroundStyle(.secondary) } }
            Button("Delete Cookies", role: .destructive) {
                Task {
                    _ = try? await page.configuration.profile?.deleteCookies(for: ProfilesPages.page.localURL)
                    page.reload()
                }
            }
            .padding(8)
        }
        .background(.background)
        .task {
            do {
                try await page.configuration.profile?.ready()
            } catch {
                failure = "\(error)"
            }
        }
        // The profile's cookies for the page, read again after every load.
        .task(id: page.isLoading) {
            guard !page.isLoading, let profile = page.configuration.profile else { return }
            cookies = (try? await profile.cookies(for: ProfilesPages.page.localURL)) ?? []
        }
    }
}

private extension CefPage {
    static func inProfile(_ profile: CefProfile) -> CefPage {
        var configuration = CefPage.Configuration()
        configuration.profile = profile
        return CefPage(url: ProfilesPages.page.localURL, configuration: configuration)
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

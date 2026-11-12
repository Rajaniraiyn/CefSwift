import CefSwiftUI
import SecurityInterface
import SwiftUI

/// The lock at the start of the address field; clicking it shows the
/// site's page info.
struct PageInfoButton: View {
    let browser: CefBrowser
    let security: SiteSecurity
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: { security.badge }
            .buttonStyle(.borderless)
            .help("Show page info")
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                PageInfoView(browser: browser)
            }
            .task {
                // -showPageInfo YES, for screenshots.
                guard UserDefaults.standard.bool(forKey: "showPageInfo") else { return }
                try? await Task.sleep(for: .seconds(2))
                isShowing = true
            }
    }
}

/// A site's page info: who it is, how it is connected, and what it may use.
struct PageInfoView: View {
    let browser: CefBrowser
    @State private var settings: [CefSitePermission: CefSitePermission.Setting] = [:]

    /// The permissions listed for every site; others appear once the site
    /// has a value of its own for them.
    private static let listed: [CefSitePermission] = [
        .camera, .microphone, .geolocation, .notifications, .popups, .sound, .automaticDownloads, .clipboard,
    ]

    private var origin: URL? {
        guard let url = browser.url, let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")")
    }

    private var siteSettings: CefSiteSettings { (browser.options.profile ?? .default).siteSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(origin?.host() ?? browser.url?.absoluteString ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ConnectionSummary(browser: browser)
            }
            if origin != nil {
                Divider()
                Text("Permissions").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(permissions, id: \.self) { permission in
                        GridRow {
                            Text(permission.localizedName)
                            Picker(permission.localizedName, selection: binding(for: permission)) {
                                ForEach(permission.supportedSettings, id: \.self) { setting in
                                    Text(Self.title(of: setting)).tag(setting)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset Permissions") {
                        if let origin { siteSettings.reset(origin: origin) }
                        reload()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear(perform: reload)
        .task {
            // Chromium's own prompts and pages change settings too.
            for await _ in siteSettings.changes { reload() }
        }
    }

    private var permissions: [CefSitePermission] {
        guard let origin else { return [] }
        let own = siteSettings.exceptions().filter { $0.applies(to: origin) }.map(\.permission)
        return Self.listed + CefSitePermission.allCases.filter { own.contains($0) && !Self.listed.contains($0) }
    }

    private func binding(for permission: CefSitePermission) -> Binding<CefSitePermission.Setting> {
        Binding {
            settings[permission] ?? .default
        } set: { setting in
            guard let origin else { return }
            siteSettings.set(setting, for: permission, origin: origin)
            reload()
        }
    }

    private func reload() {
        guard let origin else { return }
        var current: [CefSitePermission: CefSitePermission.Setting] = [:]
        for permission in permissions { current[permission] = siteSettings.setting(for: permission, origin: origin) }
        settings = current
    }

    private static func title(of setting: CefSitePermission.Setting) -> String {
        switch setting {
        case .allow: "Allow"
        case .block: "Block"
        case .ask: "Ask"
        case .sessionOnly: "This Session"
        case .default: "Default"
        }
    }
}

/// How the page is connected, and its certificate.
struct ConnectionSummary: View {
    let browser: CefBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch browser.connectionSecurity?.level {
            case .secure:
                Label("Connection is secure", systemImage: "lock.fill").foregroundStyle(.secondary)
            case .partiallySecure:
                Label("Connection is not fully secure", systemImage: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.orange)
            case .notSecure:
                Label("Connection is not secure", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .local, nil:
                Label("Page of this app", systemImage: "gearshape.fill").foregroundStyle(.secondary)
            }
            if let security = browser.connectionSecurity, let certificate = security.certificate {
                Text(Self.details(of: security, certificate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Certificate") { Self.show(certificate, from: browser) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private static func details(of security: CefConnectionSecurity, _ certificate: CefCertificate) -> String {
        let version: String =
            switch security.protocolVersion {
            case .tls1_3: "TLS 1.3"
            case .tls1_2: "TLS 1.2"
            case .quic: "QUIC"
            case .tls1_0, .tls1_1, .other: "an old TLS version"
            case nil: "TLS"
            }
        let expiry = certificate.validUntil.formatted(date: .abbreviated, time: .omitted)
        return "\(version) · issued by \(certificate.issuer.displayName) · valid until \(expiry)"
    }

    /// The system's certificate sheet, with the chain the site sent.
    private static func show(_ certificate: CefCertificate, from browser: CefBrowser) {
        guard let window = browser.hostWindow else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
            certificates: certificate.secCertificateChain, showGroup: true)
    }
}

import CefChromium
import CefSwiftUI
import SwiftUI

/// One feature of the browser: bookmarks, the find bar, Memory Saver.
///
/// A feature is built from CefSwift's public API and plugs into the browser
/// through these few points, each with a default that does nothing, so a
/// feature implements only the ones it uses. ``BrowserApp/features`` lists
/// them; deleting a feature's line there, and its folder, builds the
/// browser without it.
@MainActor
protocol BrowserFeature {
    associatedtype MenuCommands: Commands = EmptyCommands
    associatedtype SettingsSection: View = EmptyView
    associatedtype ToolbarItems: View = EmptyView
    associatedtype PageOverlay: View = EmptyView

    /// Called once the app has launched and Chromium runs, before the first
    /// tab opens.
    func start(_ controller: BrowserController)

    /// Adjusts a new tab's browser before Chromium creates it: attachments,
    /// bridges, user scripts, context menu items. The profile is already
    /// chosen.
    func configure(_ configuration: inout CefPage.Configuration)

    /// Called for each new window, once the browser has dressed it: the
    /// windows the browser opens and those Chromium opens itself.
    func windowDidOpen(_ window: CefChromeWindow)

    /// Decides a main-frame navigation, or returns `nil` to leave it to the
    /// features after this one. Navigations no feature decides are allowed.
    func decidePolicy(for navigation: CefNavigationAction, in page: CefPage) -> CefNavigationDecision?

    /// Answers a page's request for the camera, location and the like, or
    /// returns `nil` to leave it to the features after this one. Requests
    /// no feature answers are denied.
    func decidePermission(for request: CefPermissionRequest, in page: CefPage) async -> CefPermissionDecision?

    /// Menu bar commands.
    @CommandsBuilder func commands(for controller: BrowserController) -> MenuCommands

    /// Rows of the Settings window.
    @ViewBuilder var settings: SettingsSection { get }

    /// Views for one place in a tab's toolbar. They can read the
    /// ``BrowserController`` from the environment.
    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for page: CefPage) -> ToolbarItems

    /// A view laid over the page of every window, passing clicks through.
    @ViewBuilder func pageOverlay(for page: CefPage) -> PageOverlay
}

/// The places in a tab's toolbar that features fill.
enum ToolbarPlacement {
    /// The center: the address field.
    case principal
    /// Inside the address field, before the address: badges and buttons
    /// about the page.
    case addressFieldLeading
    /// Inside the address field, after the address.
    case addressFieldTrailing
    /// The far edge, before the New Tab button.
    case trailing
}

// Written out rather than with `@Entry`, whose macro plugin comes with
// Xcode, not with the Command Line Tools.
private struct IsEditingAddressKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the address field is being edited, for its accessories that
    /// make way while it is.
    var isEditingAddress: Bool {
        get { self[IsEditingAddressKey.self] }
        set { self[IsEditingAddressKey.self] = newValue }
    }
}

extension BrowserFeature {
    func start(_ controller: BrowserController) {}
    func configure(_ configuration: inout CefPage.Configuration) {}
    func windowDidOpen(_ window: CefChromeWindow) {}
    func decidePolicy(for navigation: CefNavigationAction, in page: CefPage) -> CefNavigationDecision? { nil }
    func decidePermission(for request: CefPermissionRequest, in page: CefPage) async -> CefPermissionDecision? { nil }
}

extension BrowserFeature where MenuCommands == EmptyCommands {
    func commands(for controller: BrowserController) -> EmptyCommands { EmptyCommands() }
}

extension BrowserFeature where SettingsSection == EmptyView {
    var settings: EmptyView { EmptyView() }
}

extension BrowserFeature where ToolbarItems == EmptyView {
    func toolbarItems(_ placement: ToolbarPlacement, for page: CefPage) -> EmptyView { EmptyView() }
}

extension BrowserFeature where PageOverlay == EmptyView {
    func pageOverlay(for page: CefPage) -> EmptyView { EmptyView() }
}

// MARK: - A list of features

/// Features listed one per line, as in ``BrowserApp/features``. The list is
/// itself a feature: each point is passed to every feature in order, and
/// their views and commands appear in that order.
struct BrowserFeatures<Content: BrowserFeature>: BrowserFeature {
    let content: Content

    init(@BrowserFeatureBuilder _ content: () -> Content) {
        self.content = content()
    }

    func start(_ controller: BrowserController) { content.start(controller) }
    func configure(_ configuration: inout CefPage.Configuration) { content.configure(&configuration) }
    func windowDidOpen(_ window: CefChromeWindow) { content.windowDidOpen(window) }

    func decidePolicy(for navigation: CefNavigationAction, in page: CefPage) -> CefNavigationDecision? {
        content.decidePolicy(for: navigation, in: page)
    }

    func decidePermission(for request: CefPermissionRequest, in page: CefPage) async -> CefPermissionDecision? {
        await content.decidePermission(for: request, in: page)
    }

    func commands(for controller: BrowserController) -> Content.MenuCommands { content.commands(for: controller) }
    var settings: Content.SettingsSection { content.settings }

    func toolbarItems(_ placement: ToolbarPlacement, for page: CefPage) -> Content.ToolbarItems {
        content.toolbarItems(placement, for: page)
    }

    func pageOverlay(for page: CefPage) -> Content.PageOverlay { content.pageOverlay(for: page) }
}

@MainActor
@resultBuilder
enum BrowserFeatureBuilder {
    static func buildPartialBlock<First: BrowserFeature>(first: First) -> First { first }

    static func buildPartialBlock<Accumulated: BrowserFeature, Next: BrowserFeature>(
        accumulated: Accumulated, next: Next
    ) -> FeaturePair<Accumulated, Next> {
        FeaturePair(first: accumulated, second: next)
    }
}

/// Two features as one, the first going first.
struct FeaturePair<First: BrowserFeature, Second: BrowserFeature>: BrowserFeature {
    let first: First
    let second: Second

    func start(_ controller: BrowserController) {
        first.start(controller)
        second.start(controller)
    }

    func configure(_ configuration: inout CefPage.Configuration) {
        first.configure(&configuration)
        second.configure(&configuration)
    }

    func windowDidOpen(_ window: CefChromeWindow) {
        first.windowDidOpen(window)
        second.windowDidOpen(window)
    }

    func decidePolicy(for navigation: CefNavigationAction, in page: CefPage) -> CefNavigationDecision? {
        first.decidePolicy(for: navigation, in: page) ?? second.decidePolicy(for: navigation, in: page)
    }

    func decidePermission(for request: CefPermissionRequest, in page: CefPage) async -> CefPermissionDecision? {
        if let decision = await first.decidePermission(for: request, in: page) { return decision }
        return await second.decidePermission(for: request, in: page)
    }

    @CommandsBuilder func commands(for controller: BrowserController) -> some Commands {
        first.commands(for: controller)
        second.commands(for: controller)
    }

    @ViewBuilder var settings: some View {
        first.settings
        second.settings
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for page: CefPage) -> some View {
        first.toolbarItems(placement, for: page)
        second.toolbarItems(placement, for: page)
    }

    @ViewBuilder func pageOverlay(for page: CefPage) -> some View {
        first.pageOverlay(for: page)
        second.pageOverlay(for: page)
    }
}

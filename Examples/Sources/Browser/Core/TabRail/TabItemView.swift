import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// One tab in the rail: its icon, title and state, a close button, and its
/// menu. Clicking selects it (⌘-click adds it to the selection, ⇧-click
/// selects the run up to it); dragging moves it.
struct TabItemView: View {
    enum Style { case tab, pinned, pinnedTile, row }

    let tab: CefTab
    let style: Style

    @Environment(BrowserController.self) private var controller
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .tab ? 8 : 7, style: .continuous)
        HStack(spacing: 6) {
            TabFavicon(tab: tab)
            if style == .tab || style == .row {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: tab.isActive ? .medium : .regular))
                    .foregroundStyle(tab.isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                indicators
                closeButton
            }
        }
        .padding(.horizontal, style == .tab || style == .row ? 8 : 0)
        .frame(maxWidth: style == .pinned ? 34 : .infinity)
        .frame(height: style == .pinnedTile ? 36 : 30)
        .frame(width: style == .pinnedTile ? 40 : nil)
        .background {
            shape.fill(.background.opacity(tab.isActive ? 1 : 0))
                .shadow(color: .black.opacity(tab.isActive ? 0.12 : 0), radius: 1, y: 0.5)
            shape.fill(.primary.opacity(!tab.isActive && (isHovered || tab.isSelected) ? 0.06 : style == .pinnedTile ? 0.04 : 0))
        }
        .overlay(alignment: .bottom) { groupBar }
        .overlay(alignment: .leading) {
            if let group = tab.group, style == .row {
                Capsule().fill(group.color.swiftUIColor).frame(width: 3).padding(.vertical, 7).offset(x: -5)
            }
        }
        .contentShape(shape)
        .opacity(tab.isDiscarded ? 0.6 : 1)
        .onHover { isHovered = $0 }
        .onTapGesture { controller.click(tab, modifiers: NSEvent.modifierFlags) }
        .gesture(TapGesture().modifiers(.command).onEnded { controller.click(tab, modifiers: .command) })
        .gesture(TapGesture().modifiers(.shift).onEnded { controller.click(tab, modifiers: .shift) })
        .simultaneousGesture(dragOut)
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(tab.accessibilityState)
        .accessibilityAddTraits(tab.isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { Task { try? await tab.select() } }
        .accessibilityAction(named: "Close Tab") { tab.close() }
        .accessibilityAction(named: tab.isPinned ? "Unpin Tab" : "Pin Tab") { Task { try? await tab.pin(!tab.isPinned) } }
        .accessibilityAction(named: tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
    }

    @ViewBuilder private var indicators: some View {
        if tab.isAudible || tab.isMuted {
            Button {
                tab.setMuted(!tab.isMuted)
            } label: {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
        }
        if tab.alerts.contains(.recording) || tab.alerts.contains(.capturing) {
            Image(systemName: "record.circle").font(.system(size: 10)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var closeButton: some View {
        if isHovered || tab.isActive {
            Button {
                tab.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(CloseButtonStyle())
            .help("Close Tab (⌘W)")
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var groupBar: some View {
        if let group = tab.group, style == .tab {
            Capsule()
                .fill(group.color.swiftUIColor)
                .frame(height: 2)
                .padding(.horizontal, 8)
                .offset(y: 1)
        }
    }

    /// Dragging a tab: an AppKit drag of the tab, so it can land in any
    /// window's rail, in Finder as its address, or outside every window,
    /// which moves it into a new one.
    private var dragOut: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { _ in controller.beginDrag(of: tab) }
    }
}

/// A tab's favicon, a spinner while it loads, or a symbol.
struct TabFavicon: View {
    let tab: CefTab
    @Environment(BrowserController.self) private var controller

    var body: some View {
        Group {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: controller.isStartPage(tab.url) ? "square.grid.2x2"
                        : BrowserPages.isInternal(tab.url) ? "gearshape" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .saturation(tab.isDiscarded ? 0 : 1)
        .overlay(alignment: .bottomTrailing) {
            if tab.window?.profile.isIncognito == true {
                Image(systemName: "hand.raised.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(.tint)
                    .offset(x: 3, y: 3)
            }
        }
    }
}

/// A group's coloured chip: its name, or a dot for a group without one.
/// Clicking it collapses or expands the group.
struct GroupHeaderView: View {
    let group: CefTabGroup
    let axis: TabRail.Axis

    @Environment(BrowserController.self) private var controller
    @State private var isRenaming = false
    @State private var name = ""

    static func width(for title: String) -> CGFloat {
        title.isEmpty ? 22 : min(140, CGFloat(title.count) * 7 + 22)
    }

    var body: some View {
        let isCollapsed = controller.isCollapsed(group)
        Button {
            controller.toggleCollapsed(group)
        } label: {
            HStack(spacing: 4) {
                if axis == .vertical {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                }
                if group.title.isEmpty {
                    Circle().fill(group.color.swiftUIColor).frame(width: 10, height: 10)
                } else {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(group.color.swiftUIColor, in: .capsule)
                }
                if axis == .vertical { Spacer(minLength: 0) }
                if isCollapsed, axis == .vertical {
                    Text("\(group.tabs.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: axis == .vertical ? .infinity : nil, minHeight: 28)
            .padding(.horizontal, axis == .vertical ? 6 : 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { GroupMenu(group: group, rename: { name = group.title; isRenaming = true }) }
        .popover(isPresented: $isRenaming) {
            TextField("Group Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .padding(10)
                .onSubmit {
                    isRenaming = false
                    Task { try? await group.setTitle(name) }
                }
        }
        .help(group.title.isEmpty ? "Tab group" : group.title)
        .accessibilityLabel(group.title.isEmpty ? "Tab group" : "\(group.title) group")
        .accessibilityValue("\(group.tabs.count) tabs, \(isCollapsed ? "collapsed" : "expanded")")
        .accessibilityAction(named: isCollapsed ? "Expand" : "Collapse") { controller.toggleCollapsed(group) }
    }
}

private struct CloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.18 : isHovered ? 0.1 : 0), in: .rect(cornerRadius: 4))
                .onHover { isHovered = $0 }
        }
    }
}

extension CefTabGroup.Color {
    /// Chrome's group colours, as SwiftUI colours.
    var swiftUIColor: Color {
        switch self {
        case .grey: Color(.systemGray)
        case .blue: Color(.systemBlue)
        case .red: Color(.systemRed)
        case .yellow: Color(.systemYellow)
        case .green: Color(.systemGreen)
        case .pink: Color(.systemPink)
        case .purple: Color(.systemPurple)
        case .cyan: Color(.systemTeal)
        case .orange: Color(.systemOrange)
        }
    }

    var name: String {
        switch self {
        case .grey: "Grey"
        case .blue: "Blue"
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .pink: "Pink"
        case .purple: "Purple"
        case .cyan: "Cyan"
        case .orange: "Orange"
        }
    }
}

extension CefTab {
    /// The title the rail shows: "New Tab" for a blank page, the host for a
    /// page without a title.
    var displayTitle: String {
        guard let url, url.absoluteString != "about:blank" else { return "New Tab" }
        let title = browser?.title ?? self.title
        guard !title.isEmpty, title != url.absoluteString else { return url.host() ?? url.absoluteString }
        return title
    }

    var helpText: String {
        var lines = [displayTitle]
        if let host = url?.host() { lines.append(host) }
        if isDiscarded { lines.append("Asleep to save memory") }
        return lines.joined(separator: "\n")
    }

    var accessibilityState: String {
        var parts: [String] = []
        if let window, let index = window.tabs.firstIndex(where: { $0 === self }) {
            parts.append("Tab \(index + 1) of \(window.tabs.count)")
        }
        if isPinned { parts.append("pinned") }
        if let group { parts.append(group.title.isEmpty ? "in a group" : "in group \(group.title)") }
        if isMuted { parts.append("muted") } else if isAudible { parts.append("playing sound") }
        if isLoading { parts.append("loading") }
        if isDiscarded { parts.append("asleep") }
        return parts.joined(separator: ", ")
    }
}

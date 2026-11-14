import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// A tab's menu. Each item applies to the tab, or to every selected tab
/// when the tab is one of them.
struct TabMenu: View {
    let tab: CefTab
    @Environment(BrowserController.self) private var controller

    var body: some View {
        let tabs = controller.targets(of: tab)
        let window = tab.window
        Button("New Tab to the Right") {
            if let window { controller.openTab(in: window, at: tab.index + 1, inGroup: tab.group) }
        }
        Button("Duplicate") { Task { for tab in tabs { _ = try? await tab.duplicate() } } }
        Button(tab.isPinned ? "Unpin" : "Pin") { Task { try? await tab.window?.strip.pin(tabs, !tab.isPinned) } }
        Button(tab.isMuted ? "Unmute" : "Mute") { tabs.forEach { $0.setMuted(!tab.isMuted) } }
        Divider()
        Menu("Add to Group") {
            Button("New Group") { Task { try? await tab.window?.strip.group(tabs) } }
            if let window, !window.groups.isEmpty {
                Divider()
                ForEach(window.groups) { group in
                    Button(group.title.isEmpty ? "Unnamed Group" : group.title) { Task { try? await group.add(tabs) } }
                }
            }
        }
        if tab.group != nil {
            Button("Remove from Group") { Task { try? await tab.window?.strip.ungroup(tabs) } }
        }
        Menu("Move to Window") {
            Button("New Window") { Task { try? await tab.window?.strip.moveToNewWindow(tabs) } }
            let others = controller.windows.map(\.chrome).filter { $0 !== window }
            if !others.isEmpty { Divider() }
            ForEach(others) { other in
                if other.profile === window?.profile {
                    Button(other.activeTab?.displayTitle ?? "Window") {
                        Task { try? await other.strip.move(tabs, to: -1, in: other) }
                    }
                } else if let url = tab.url {
                    // Chromium moves tabs only within a profile.
                    Button("\(other.profile.isIncognito ? "Private" : "Other") Window: \(other.activeTab?.displayTitle ?? "")") {
                        Task { await controller.moveToProfile(tab, url: url, window: other) }
                    }
                    .help("Opens the page in that window's profile and closes it here; its history stays behind.")
                }
            }
        }
        Divider()
        Button("Close Tab") { tabs.forEach { $0.close() } }
        if let window {
            let pinned = Set(window.tabs.filter(\.isPinned).map(\.index))
            Button("Close Other Tabs") {
                let indices = TabRailLogic.indicesToClose(others: tab.index, count: window.tabs.count, pinned: pinned)
                window.strip.close(indices.map { window.tabs[$0] })
            }
            Button("Close Tabs to the Right") {
                let indices = TabRailLogic.indicesToClose(after: tab.index, count: window.tabs.count, pinned: pinned)
                window.strip.close(indices.map { window.tabs[$0] })
            }
            Divider()
            Button("Reopen Closed Tab") { window.reopenClosedTab() }
                .disabled(window.strip.recentlyClosed.isEmpty)
        }
    }
}

/// A tab group's menu.
struct GroupMenu: View {
    let group: CefTabGroup
    let rename: () -> Void
    @Environment(BrowserController.self) private var controller

    var body: some View {
        Button("Rename…", action: rename)
        Menu("Colour") {
            ForEach(CefTabGroup.Color.allCases, id: \.self) { color in
                Button {
                    Task { try? await group.setColor(color) }
                } label: {
                    Label(color.name, systemImage: group.color == color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
            Task { try? await group.setCollapsed(!group.isCollapsed) }
        }
        Divider()
        Button("New Tab in Group") {
            if let window = group.window, let last = group.tabs.last {
                controller.openTab(in: window, at: last.index + 1, inGroup: group)
            }
        }
        Button("Ungroup") { Task { try? await group.ungroup() } }
        Button("Move Group to New Window") { Task { try? await group.moveToNewWindow() } }
        Divider()
        Button("Close Group") { group.close() }
    }
}

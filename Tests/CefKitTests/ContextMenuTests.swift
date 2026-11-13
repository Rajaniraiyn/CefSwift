import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit

/// ``CefContextMenu``: reading Chromium's model, the typed commands, and
/// the changes apps make.
@MainActor
struct ContextMenuTests {
    /// A menu as Chromium builds one for a link in a Chrome-style browser.
    static func chromeLinkMenu() -> CefContextMenu {
        func item(_ id: Int32, _ title: String, enabled: Bool = true) -> CefContextMenu.Item {
            CefContextMenu.Item(chromiumID: Int(id), title: title, isEnabled: enabled, isChromeStyle: true)
        }
        return CefContextMenu([
            item(IDC_CONTENT_CONTEXT_OPENLINKNEWTAB, "Open Link in New Tab"),
            item(IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW, "Open Link in New Window"),
            .separator,
            item(IDC_CONTENT_CONTEXT_SAVELINKAS, "Save Link As…"),
            item(IDC_CONTENT_CONTEXT_COPYLINKLOCATION, "Copy Link Address"),
            .separator,
            item(IDC_CONTENT_CONTEXT_INSPECTELEMENT, "Inspect"),
            .separator,
            CefContextMenu.Item(chromiumID: 100, title: "Speech", submenu: CefContextMenu([
                CefContextMenu.Item(chromiumID: 101, title: "Start Speaking", isChromeStyle: true),
                CefContextMenu.Item(chromiumID: 102, title: "Stop Speaking", isEnabled: false, isChromeStyle: true),
            ]), kind: "submenu", isChromeStyle: true),
        ])
    }

    // MARK: Commands

    @Test func commandsReadTheSameInEitherStyle() {
        #expect(CefContextMenuCommand(chromiumID: Int(MENU_ID_COPY.rawValue), isChromeStyle: false) == .copy)
        #expect(CefContextMenuCommand(chromiumID: Int(IDC_CONTENT_CONTEXT_COPY), isChromeStyle: true) == .copy)
        #expect(CefContextMenuCommand(chromiumID: Int(MENU_ID_BACK.rawValue), isChromeStyle: false) == .back)
        #expect(CefContextMenuCommand(chromiumID: Int(IDC_BACK), isChromeStyle: true) == .back)
        #expect(CefContextMenuCommand(chromiumID: Int(MENU_ID_VIEW_SOURCE.rawValue), isChromeStyle: false) == .viewSource)
        #expect(CefContextMenuCommand(chromiumID: Int(MENU_ID_SPELLCHECK_SUGGESTION_0.rawValue) + 2, isChromeStyle: false)
            == .spellingSuggestion(2))
        #expect(CefContextMenuCommand.spellingSuggestion(2).spellingSuggestionIndex == 2)
        #expect(CefContextMenuCommand.copy.spellingSuggestionIndex == nil)
    }

    /// In Chrome-style menus macOS's text services number their items with
    /// the values CEF gives back, forward and reload elsewhere.
    @Test func textServiceItemsAreNotNavigation() {
        #expect(CefContextMenuCommand(chromiumID: 100, isChromeStyle: true) == .speechMenu)
        #expect(CefContextMenuCommand(chromiumID: 101, isChromeStyle: true) == .startSpeaking)
        #expect(CefContextMenuCommand(chromiumID: 103, isChromeStyle: true) == .writingDirectionMenu)
        #expect(CefContextMenuCommand(chromiumID: 106, isChromeStyle: true) == .writingDirectionRightToLeft)
        #expect(CefContextMenuCommand(chromiumID: 100, isChromeStyle: false) == .back)
    }

    @Test func unknownCommandsRoundTrip() {
        let future = CefContextMenuCommand(chromiumID: 59_999, isChromeStyle: true)
        #expect(future.rawValue == 59_999)
        #expect(!future.isKnown)
        #expect(future.description == "CefContextMenuCommand(rawValue: 59999)")
        let item = CefContextMenu.Item(chromiumID: 59_999, title: "Something New", isChromeStyle: true)
        #expect(item.command == future)
        #expect(item.chromiumID == 59_999)
        #expect(CefContextMenuCommand.copyLinkAddress.isKnown)
        #expect(CefContextMenuCommand.copyLinkAddress.description == "copyLinkAddress")
    }

    @Test func titlesLoseMnemonics() {
        #expect(CefContextMenu.title(fromChromiumLabel: "&Copy") == "Copy")
        #expect(CefContextMenu.title(fromChromiumLabel: "Save && &Quit") == "Save & Quit")
    }

    // MARK: Changes

    @Test func findsItemsInSubmenus() {
        let menu = Self.chromeLinkMenu()
        #expect(menu.contains(.copyLinkAddress))
        #expect(menu.contains(.startSpeaking))
        #expect(!menu.contains(.back))
        #expect(menu[.stopSpeaking]?.isEnabled == false)
        #expect(menu.commands == [
            .openLinkInNewTab, .openLinkInNewWindow, .saveLinkAs, .copyLinkAddress, .inspectElement,
            .speechMenu, .startSpeaking, .stopSpeaking,
        ])
    }

    @Test func removesInsertsAndReplaces() {
        var menu = Self.chromeLinkMenu()
        menu.remove(.openLinkInNewWindow, .startSpeaking)
        #expect(!menu.contains(.openLinkInNewWindow) && !menu.contains(.startSpeaking))

        let markdown = CefContextMenu.Item("Copy as Markdown") { _, _ in }
        let inserted = menu.insert(markdown, after: .copyLinkAddress)
        #expect(inserted)
        #expect(menu.items.map(\.title).firstIndex(of: "Copy as Markdown")
            == menu.items.map(\.title).firstIndex(of: "Copy Link Address")! + 1)
        let separated = menu.insert(.separator, before: .stopSpeaking)
        #expect(separated)
        #expect(menu[.speechMenu]?.submenu?.items.first?.isSeparator == true)
        let missing = menu.insert(markdown, after: .back)
        #expect(!missing)

        menu[.saveLinkAs]?.title = "Download Linked File"
        #expect(menu[.saveLinkAs]?.title == "Download Linked File")
        menu[.inspectElement] = nil
        #expect(!menu.contains(.inspectElement))
    }

    @Test func handlingACommandKeepsItsTitle() {
        var menu = Self.chromeLinkMenu()
        #expect(menu[.openLinkInNewTab]?.action == nil)
        let handled = menu.handle(.openLinkInNewTab) { _, _ in }
        #expect(handled)
        #expect(menu[.openLinkInNewTab]?.action != nil)
        #expect(menu[.openLinkInNewTab]?.title == "Open Link in New Tab")
        #expect(menu[.openLinkInNewTab]?.chromiumID == Int(IDC_CONTENT_CONTEXT_OPENLINKNEWTAB))
        let unhandled = menu.handle(.back) { _, _ in }
        #expect(!unhandled)
    }

    @Test func customizationsComposeInOrder() {
        var configuration = CefBrowser.Configuration.ContextMenu()
        configuration.customize { menu, _ in menu.remove(.inspectElement) }
        configuration.customize { menu, target in
            if target.linkURL != nil {
                menu.appendSection([CefContextMenu.Item("Bookmark Link") { _, _ in }])
            }
        }
        configuration.customize { menu, _ in
            menu.items.append(CefContextMenu.Item("Last") { _, _ in })
        }
        let target = CefContextMenuTarget(linkURL: URL(string: "https://example.com"))
        let menu = configuration.menu(from: Self.chromeLinkMenu(), for: target, isChromeStyle: true)
        let titles = menu.items.map { $0.isSeparator ? "—" : $0.title }
        #expect(titles == [
            "Open Link in New Tab", "Open Link in New Window", "—", "Save Link As…", "Copy Link Address", "—",
            "Bookmark Link", "Last",
        ])
    }

    /// Speech and Writing Direction run as AppKit actions on Chromium's
    /// view; with no view that answers them, they are left out rather
    /// than shown dead (or crashing CEF, as Chrome's own handling does).
    @Test func textServiceItemsNeedAViewThatAnswersThem() {
        let menu = CefContextMenu.adjusted(Self.chromeLinkMenu(), for: CefContextMenuTarget(), isChromeStyle: true, pageView: NSView())
        #expect(!menu.contains(.speechMenu) || menu[.speechMenu]?.submenu?.items.isEmpty == true)
        #expect(!menu.contains(.startSpeaking) && !menu.contains(.stopSpeaking))
        let speaker = SpeakingView()
        let answered = CefContextMenu.adjusted(Self.chromeLinkMenu(), for: CefContextMenuTarget(), isChromeStyle: true, pageView: speaker)
        #expect(answered[.startSpeaking]?.action != nil)
    }

    @Test func inspectIsAddedOnlyWhenMissing() {
        var configuration = CefBrowser.Configuration.ContextMenu()
        configuration.showsInspectElement = true
        let chrome = configuration.menu(from: Self.chromeLinkMenu(), for: CefContextMenuTarget(), isChromeStyle: true)
        #expect(chrome.items.filter { $0.command == .inspectElement || $0.title == "Inspect" }.count == 1)
        let alloy = configuration.menu(
            from: CefContextMenu([CefContextMenu.Item(chromiumID: Int(MENU_ID_COPY.rawValue), title: "Copy", isChromeStyle: false)]),
            for: CefContextMenuTarget(), isChromeStyle: false)
        #expect(alloy.items.last?.command == .inspectElement)
        #expect(alloy.items.map(\.title).last == CefBrowser.Configuration.ContextMenu.inspectTitle)
    }

    @Test func normalizingDropsStraySeparatorsAndEmptySubmenus() {
        let menu = CefContextMenu([
            .separator,
            CefContextMenu.Item("A") { _, _ in },
            .separator, .separator,
            CefContextMenu.Item("Empty", submenu: CefContextMenu([.separator])),
            CefContextMenu.Item("B") { _, _ in },
            .separator,
        ]).normalized
        #expect(menu.items.map { $0.isSeparator ? "—" : $0.title } == ["A", "—", "B"])
    }

    // MARK: Native menu

    @Test func nativeMenuMirrorsTheValue() {
        var menu = Self.chromeLinkMenu()
        menu[.openLinkInNewWindow]?.isChecked = true
        let native = CefContextMenuPresenter.makeMenu(for: menu)
        #expect(native.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "Open Link in New Tab", "Open Link in New Window", "—", "Save Link As…", "Copy Link Address", "—",
            "Inspect", "—", "Speech",
        ])
        #expect(native.items[1].state == .on)
        let speech = native.items.last!
        #expect(speech.submenu?.items.map(\.title) == ["Start Speaking", "Stop Speaking"])
        #expect(speech.submenu?.items.last?.isEnabled == false)
        // Each item names its place in the menu, for the choice.
        let path = speech.submenu?.items.first?.representedObject as? [Int]
        #expect(path.flatMap { menu.normalized.item(at: $0) }?.command == .startSpeaking)
    }

    // MARK: Reading Chromium's model

    @Test func readsChromiumsModel() {
        MenuModelFixture.items = [
            .init(id: Int32(MENU_ID_UNDO.rawValue), type: MENUITEMTYPE_COMMAND, enabled: false),
            .init(id: -1, type: MENUITEMTYPE_SEPARATOR),
            .init(id: Int32(MENU_ID_COPY.rawValue), type: MENUITEMTYPE_COMMAND),
            .init(id: 26_600, type: MENUITEMTYPE_COMMAND, visible: false),
            .init(id: 41_122, type: MENUITEMTYPE_CHECK, checked: true),
            .init(id: 41_123, type: MENUITEMTYPE_RADIO, checked: true, group: 3),
            .init(id: 59_999, type: MENUITEMTYPE_COMMAND),
        ]
        var model = MenuModelFixture.model()
        let menu = withUnsafeMutablePointer(to: &model) { CefContextMenu(model: $0, isChromeStyle: false) }
        #expect(menu.items.count == 6)
        #expect(menu.items[0].command == .undo && !menu.items[0].isEnabled)
        #expect(menu.items[1].isSeparator)
        #expect(menu.items[2].command == .copy && menu.items[2].chromiumID == Int(MENU_ID_COPY.rawValue))
        #expect(menu.items[3].command == .writingDirectionLeftToRight && menu.items[3].isChecked)
        #expect(menu.items[4].isChecked && menu.items[4].chromiumGroup == 3)
        #expect(menu.items[5].command == CefContextMenuCommand(rawValue: 59_999))
    }
}

/// A hand-built `cef_menu_model_t` over ``items``. C function pointers
/// cannot capture, so its callbacks read this global; only these tests use
/// it.
enum MenuModelFixture {
    struct Entry {
        var id: Int32
        var type: cef_menu_item_type_t
        var enabled = true
        var visible = true
        var checked = false
        var group: Int32 = -1
    }

    nonisolated(unsafe) static var items: [Entry] = []

    static func model() -> cef_menu_model_t {
        var model = cef_menu_model_t()
        model.get_count = { _ in MenuModelFixture.items.count }
        model.get_type_at = { _, index in MenuModelFixture.items[index].type }
        model.get_command_id_at = { _, index in MenuModelFixture.items[index].id }
        model.get_label_at = { _, _ in nil }
        model.is_visible_at = { _, index in MenuModelFixture.items[index].visible ? 1 : 0 }
        model.is_enabled_at = { _, index in MenuModelFixture.items[index].enabled ? 1 : 0 }
        model.is_checked_at = { _, index in MenuModelFixture.items[index].checked ? 1 : 0 }
        model.get_group_id_at = { _, index in MenuModelFixture.items[index].group }
        model.get_sub_menu_at = { _, _ in nil }
        return model
    }
}

/// A view that answers `startSpeaking:` and `stopSpeaking:`, as Chromium's does.
private final class SpeakingView: NSView {
    @objc func startSpeaking(_ sender: Any?) {}
    @objc func stopSpeaking(_ sender: Any?) {}
}

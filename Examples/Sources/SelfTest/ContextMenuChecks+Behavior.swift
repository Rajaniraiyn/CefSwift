import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// What each menu holds, and that its items do what they say.
extension SelfTest {
    /// What the checks' customization does to the next menu.
    @MainActor enum MenuCustomization {
        /// Adds "Mark Link" to links; choosing it sets ``marked``.
        static var marked: URL?
        /// Handles Copy Link Address itself, setting ``intercepted``.
        static var interceptsCopyLink = false
        static var intercepted: URL?
        /// Empties the menu, which then does not show.
        static var empties = false

        static func apply(_ menu: inout CefContextMenu, _ target: CefContextMenuTarget) {
            if empties { menu.items.removeAll() }
            if let link = target.linkURL {
                menu.appendSection([CefContextMenu.Item("Mark Link") { _, _ in marked = link }])
                if interceptsCopyLink {
                    menu.handle(.copyLinkAddress) { _, target in intercepted = target.linkURL }
                }
            }
        }
    }

    /// The commands of each target's menu, top to bottom, by hosting
    /// style, with Inspect shown in Alloy style too. Spelling suggestions,
    /// which come from the system's dictionary, are left out; offscreen
    /// views have no Speech or Writing Direction. Chrome's 52999 (Import
    /// Passwords) and 50168 (Ask Google for Suggestions) have no name in
    /// CefKit.
    static let expectedMenuCommands: [String: [String: [CefContextMenuCommand]]] = [
        "alloy": [
            "audio": [.openMediaInNewTab, .saveMediaAs, .copyMediaAddress, .back, .forward, .print, .viewSource, .inspectElement],
            "canvas": [.back, .forward, .print, .viewSource, .inspectElement],
            "field": [.lookUp, .emojiAndSymbols, .undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .speechMenu, .startSpeaking, .stopSpeaking, .inspectElement],
            "field selection": [.lookUp, .emojiAndSymbols, .undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .speechMenu, .startSpeaking, .stopSpeaking, .inspectElement],
            "iframe": [.back, .forward, .print, .viewSource, .inspectElement],
            "image": [.openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .back, .forward, .print, .viewSource, .inspectElement],
            "link": [.openLinkInNewTab, .openLinkInNewWindow, .saveLinkAs, .copyLinkAddress, .lookUp, .copy, .speechMenu, .startSpeaking, .stopSpeaking, .inspectElement],
            "linked image": [.openLinkInNewTab, .openLinkInNewWindow, .saveLinkAs, .copyLinkAddress, .openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .back, .forward, .print, .viewSource, .inspectElement],
            "misspelling": [.lookUp, .emojiAndSymbols, .undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .addToDictionary, .speechMenu, .startSpeaking, .stopSpeaking, .inspectElement],
            "page": [.back, .forward, .print, .viewSource, .inspectElement],
            "pdf": [.back, .forward, .print, .viewSource, .inspectElement],
            "selection": [.lookUp, .copy, .speechMenu, .startSpeaking, .stopSpeaking, .inspectElement],
            "video": [.openMediaInNewTab, .saveMediaAs, .copyMediaAddress, .back, .forward, .print, .viewSource, .inspectElement],
        ],
        "chrome": [
            "audio": [.loop, .showControls, .openMediaInNewTab, .saveMediaAs, .copyMediaAddress, .inspectElement],
            "canvas": [.saveImageAs, .copyImage, .inspectElement],
            "field": [.lookUp, .emojiAndSymbols, CefContextMenuCommand(rawValue: 52_999), .undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .searchWebFor, .print, .languageSettings, .inspectElement, .speechMenu, .startSpeaking, .stopSpeaking],
            "field selection": [.lookUp, .emojiAndSymbols, CefContextMenuCommand(rawValue: 52_999), .undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .searchWebFor, .print, .languageSettings, .inspectElement, .speechMenu, .startSpeaking, .stopSpeaking],
            "iframe": [.back, .forward, .reload, .savePage, .print, .createQRCode, .viewSource, .viewFrameSource, .reloadFrame, .inspectElement],
            "image": [.openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .createQRCode, .searchLensForImage, .inspectElement],
            "link": [.openLinkInNewTab, .openLinkInNewWindow, .openLinkInIncognitoWindow, .saveLinkAs, .copyLinkAddress, .copy, .copyLinkToHighlight, .searchWebFor, .print, .inspectElement, .speechMenu, .startSpeaking, .stopSpeaking],
            "linked image": [.openLinkInNewTab, .openLinkInNewWindow, .openLinkInIncognitoWindow, .createQRCode, .saveLinkAs, .copyLinkAddress, .openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .searchLensForImage, .inspectElement],
            "misspelling": [.addToDictionary, CefContextMenuCommand(rawValue: 50_168), .searchWebFor, .lookUp, .undo, .redo, .cut, .copy, .paste, .inspectElement, .speechMenu, .startSpeaking, .stopSpeaking],
            "page": [.back, .forward, .reload, .savePage, .print, .createQRCode, .viewSource, .inspectElement],
            "pdf": [.back, .forward, .reload, .savePage, .print, .createQRCode, .rotateClockwise, .rotateCounterclockwise, .inspectElement],
            "selection": [.lookUp, .copy, .copyLinkToHighlight, .searchWebFor, .print, .inspectElement, .speechMenu, .startSpeaking, .stopSpeaking],
            "video": [.loop, .showControls, .openMediaInNewTab, .saveMediaAs, .copyMediaAddress, .inspectElement],
        ],
    ]

    /// macOS's Speech and Writing Direction items, which offscreen views
    /// cannot run.
    static let textServiceCommands: Set<CefContextMenuCommand> = [
        .speechMenu, .startSpeaking, .stopSpeaking, .writingDirectionMenu,
        .writingDirectionDefault, .writingDirectionLeftToRight, .writingDirectionRightToLeft,
    ]

    static func contextMenuBehaviorChecks(base: URL) async {
        var chromeTabs: [URL] = []
        let previousHandler = CefRuntime.shared.onChromeTab
        CefRuntime.shared.onChromeTab = { request in chromeTabs.append(request.url); return .close }
        defer { CefRuntime.shared.onChromeTab = previousHandler }
        var commandsByStyle: [String: [String: [CefContextMenuCommand]]] = [:]

        for style in ["windowed", "offscreen", "chrome"] {
            let recorder = MenuRecorder()
            guard let host = await makeMenuHost(style, base: base, recorder: recorder, configure: {
                $0.contextMenu.showsInspectElement = true
                $0.contextMenu.customize(MenuCustomization.apply)
            }) else {
                check("contextMenu (\(style)): the page loads", false)
                continue
            }
            let browser = host.browser
            func open(_ name: String) async -> (shown: CefContextMenu, chromium: CefContextMenu, target: CefContextMenuTarget)? {
                guard let target = menuTargets.first(where: { $0.name == name }) else { return nil }
                return await openMenu(target, base: base, in: browser, recorder: recorder, reload: true)
            }
            /// Opens `name`'s menu, chooses the item running `command`, and
            /// waits until `done`.
            func choose(_ command: CefContextMenuCommand, on name: String, until done: () -> Bool) async -> Bool {
                recorder.choose = { $0[command] }
                defer { recorder.choose = { _ in nil } }
                guard let opened = await open(name), opened.shown.contains(command) else { return false }
                return await waitUntil(timeout: .seconds(5), done)
            }

            // What each menu holds.
            var commands: [String: [CefContextMenuCommand]] = [:]
            for target in menuTargets {
                var opened = await openMenu(target, base: base, in: browser, recorder: recorder, reload: true)
                // Spell checking marks the word a moment after it is typed.
                for _ in 0..<3 where target.name == "misspelling" && opened?.target.misspelledWord.isEmpty != false {
                    try? await Task.sleep(for: .seconds(1))
                    opened = await openMenu(target, base: base, in: browser, recorder: recorder, reload: false)
                }
                guard let opened else {
                    check("contextMenu (\(style), \(target.name)): the menu opens", false)
                    continue
                }
                let menu = opened.shown
                let listed = menu.commands.filter { $0.spellingSuggestionIndex == nil }
                commands[target.name] = listed
                let duplicates = Dictionary(grouping: listed, by: { $0 }).filter { $0.value.count > 1 }.keys
                let titles = leaves(of: menu).map(\.title)
                let repeatedTitles = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
                check("contextMenu (\(style), \(target.name)): no item appears twice",
                      duplicates.isEmpty && repeatedTitles.isEmpty, detail: "\(Array(duplicates)) \(Array(repeatedTitles))")
                check("contextMenu (\(style), \(target.name)): no separator at an end or next to another",
                      hasTidySeparators(menu), detail: "\(menu)")
                let expected = expectedMenuCommands[style == "chrome" ? "chrome" : "alloy"]?[target.name]
                if var expected {
                    if style == "offscreen" {
                        expected.removeAll { textServiceCommands.contains($0) }
                    }
                    check("contextMenu (\(style), \(target.name)): Chromium's items, and no others",
                          listed == expected, detail: "got \(listed), expected \(expected)")
                }
                if target.name == "misspelling" {
                    check("contextMenu (\(style), misspelling): offers corrections and Add to Dictionary",
                          menu.commands.contains(.spellingSuggestion(0)) && menu.contains(.addToDictionary)
                              && opened.target.misspelledWord == "wrold" && !opened.target.spellingSuggestions.isEmpty,
                          detail: "\(menu.commands) \(opened.target.misspelledWord) \(opened.target.spellingSuggestions)")
                }
            }
            commandsByStyle[style] = commands

            // Items do what they say.
            let link = base.appendingPathComponent("target.html")
            let image = base.appendingPathComponent("icon.png")
            NSPasteboard.general.clearContents()
            check("contextMenu (\(style)): Copy Link Address copies the link",
                  await choose(.copyLinkAddress, on: "link") { NSPasteboard.general.string(forType: .string) == link.absoluteString },
                  detail: NSPasteboard.general.string(forType: .string) ?? "-")
            let opens = recorder.windowOpens.count
            check("contextMenu (\(style)): Open Link in New Tab asks the app to open a background tab",
                  await choose(.openLinkInNewTab, on: "link") {
                      recorder.windowOpens.dropFirst(opens).contains { $0.disposition == .newBackgroundTab && $0.targetURL == link }
                  }, detail: "\(recorder.windowOpens.dropFirst(opens).map { "\($0.disposition) \($0.targetURL?.absoluteString ?? "-")" })")
            let windows = recorder.windowOpens.count
            check("contextMenu (\(style)): Open Link in New Window asks the app to open a window",
                  await choose(.openLinkInNewWindow, on: "link") {
                      recorder.windowOpens.dropFirst(windows).contains { $0.disposition == .newWindow && $0.targetURL == link }
                  })
            let downloads = recorder.downloads.count
            check("contextMenu (\(style)): Save Image As starts a download",
                  await choose(.saveImageAs, on: "image") { recorder.downloads.dropFirst(downloads).contains("icon.png") },
                  detail: "\(recorder.downloads)")
            NSPasteboard.general.clearContents()
            check("contextMenu (\(style)): Copy Image copies the image",
                  await choose(.copyImage, on: "image") { NSPasteboard.general.canReadObject(forClasses: [NSImage.self]) },
                  detail: "\(NSPasteboard.general.types?.map(\.rawValue) ?? [])")
            NSPasteboard.general.clearContents()
            check("contextMenu (\(style)): Copy Image Address copies the image's address",
                  await choose(.copyImageAddress, on: "image") { NSPasteboard.general.string(forType: .string) == image.absoluteString })
            check("contextMenu (\(style)): Inspect opens DevTools",
                  await choose(.inspectElement, on: "page") { browser.isShowingDevTools })
            browser.closeDevTools()
            _ = await waitUntil(timeout: .seconds(5)) { !browser.isShowingDevTools }
            let sources = recorder.windowOpens.count, tabs = chromeTabs.count
            check("contextMenu (\(style)): View Page Source opens the source in a new tab",
                  await choose(.viewSource, on: "page") {
                      // Chromium opens it in a tab of its own, which reports the page's address.
                      recorder.windowOpens.dropFirst(sources).contains { $0.targetURL?.scheme == "view-source" }
                          || chromeTabs.count > tabs
                  }, detail: "\(recorder.windowOpens.dropFirst(sources).map(\.targetURL)) \(chromeTabs.dropFirst(tabs))")
            let selected = await choose(.selectAll, on: "field") { true }
            let selection = "(() => { const f = document.getElementById('field'); return f.value.substring(f.selectionStart, f.selectionEnd); })()"
            let allSelected = await waitUntilAsync(timeout: .seconds(5)) {
                (try? await browser.evaluateJavaScript(selection).stringValue) == "hello world"
            }
            check("contextMenu (\(style)): Select All selects the field's text", selected && allSelected)
            if style != "offscreen" {
                let direction = "getComputedStyle(document.getElementById('field')).direction"
                // Offered only where Chromium's view answers it.
                if await choose(.writingDirectionRightToLeft, on: "field", until: { true }) {
                    let flipped = await waitUntilAsync(timeout: .seconds(5)) {
                        (try? await browser.evaluateJavaScript(direction).stringValue) == "rtl"
                    }
                    check("contextMenu (\(style)): Writing Direction › Right to Left turns the field", flipped)
                }
            }

            // The app's items and handlers.
            MenuCustomization.marked = nil
            recorder.choose = { menu in menu.items.first { $0.title == "Mark Link" } }
            _ = await open("link")
            recorder.choose = { _ in nil }
            check("contextMenu (\(style)): an app's item runs its action",
                  await waitUntil(timeout: .seconds(5)) { MenuCustomization.marked == link })
            MenuCustomization.interceptsCopyLink = true
            MenuCustomization.intercepted = nil
            NSPasteboard.general.clearContents()
            let interceptedRan = await choose(.copyLinkAddress, on: "link") { MenuCustomization.intercepted == link }
            check("contextMenu (\(style)): a command the app handles runs the app's code, not Chromium's",
                  interceptedRan && NSPasteboard.general.string(forType: .string) == nil)
            MenuCustomization.interceptsCopyLink = false
            MenuCustomization.empties = true
            let asked = recorder.menus.count
            _ = await open("page")
            try? await Task.sleep(for: .milliseconds(500))
            check("contextMenu (\(style)): an emptied menu does not show", recorder.menus.count == asked)
            MenuCustomization.empties = false

            // The stock menu: an NSMenu of the same items, at the click.
            var shownTitles: [String]?
            let observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
            ) { notification in
                nonisolated(unsafe) let menu = notification.object as? NSMenu
                MainActor.assumeIsolated {
                    shownTitles = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title }
                    // Closes it from inside the menu's tracking loop.
                    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                        MainActor.assumeIsolated { menu?.cancelTracking() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
            recorder.usesStockMenu = true
            let stockAsked = recorder.menus.count
            _ = await open("link")
            _ = await waitUntil(timeout: .seconds(5)) { shownTitles != nil }
            try? await Task.sleep(for: .milliseconds(500))
            recorder.usesStockMenu = false
            NotificationCenter.default.removeObserver(observer)
            let expectedTitles = recorder.menus.dropFirst(stockAsked).first.map {
                $0.menu.items.map { $0.isSeparator ? "—" : $0.title }
            }
            check("contextMenu (\(style)): the stock menu shows the same items as a native menu",
                  shownTitles != nil && Array(shownTitles!.prefix(expectedTitles?.count ?? 0)) == expectedTitles,
                  detail: "\(shownTitles ?? []) vs \(expectedTitles ?? [])")
            if let shownTitles, let expectedTitles, shownTitles.count > expectedTitles.count {
                print("NOTE contextMenu (\(style)): AppKit added \(shownTitles.dropFirst(expectedTitles.count))")
            }

            if style == "chrome" {
                // An item CefKit has no name for keeps its value, shows, and runs.
                let unknown = CefContextMenuCommand(rawValue: 52_999)  // IDC_CONTENT_CONTEXT_AUTOFILL_FALLBACK_PASSWORDS_IMPORT_PASSWORDS
                let before = chromeTabs.count
                let ran = await choose(unknown, on: "field") { chromeTabs.count > before }
                check("contextMenu (chrome): an item of a command CefKit does not name survives and runs",
                      !unknown.isKnown && ran, detail: "\(chromeTabs.dropFirst(before))")
            }
            await host.close()
        }

        let windowed = commandsByStyle["windowed"] ?? [:], offscreen = commandsByStyle["offscreen"] ?? [:]
        for target in menuTargets.map(\.name) where windowed[target] != nil && offscreen[target] != nil {
            check("contextMenu (\(target)): offscreen views show what windowed views show",
                  windowed[target]!.filter { !textServiceCommands.contains($0) } == offscreen[target]!,
                  detail: "windowed \(windowed[target]!), offscreen \(offscreen[target]!)")
        }
        if ProcessInfo.processInfo.environment["SELFTEST_MENU_PRINT"] != nil {
            for (style, commands) in commandsByStyle {
                for (target, list) in commands.sorted(by: { $0.key < $1.key }) {
                    print("NOTE menu \(style) \(target): \(list.map { ".\($0)" }.joined(separator: ", "))")
                }
            }
        }

        await incognitoMenuChecks(base: base)
    }

    /// Chrome-style menus in an incognito profile. (A profile with DevTools
    /// turned off cannot be checked: the checks click through DevTools.)
    static func incognitoMenuChecks(base: URL) async {
        let recorder = MenuRecorder()
        let profile = CefProfile.incognito()
        guard let host = await makeMenuHost("chrome", base: base, recorder: recorder, configure: { $0.profile = profile }) else {
            return check("contextMenu (chrome, incognito): the page loads", false)
        }
        let link = await openMenu(menuTargets.first { $0.name == "link" }!, base: base, in: host.browser, recorder: recorder)
        check("contextMenu (chrome, incognito): Open Link in Incognito Window is there but off",
              link?.shown[.openLinkInIncognitoWindow]?.isEnabled == false, detail: "\(link?.shown.description ?? "no menu")")
        await host.close()
    }

    /// Whether no menu in `menu` starts or ends with a separator or has two
    /// in a row.
    static func hasTidySeparators(_ menu: CefContextMenu) -> Bool {
        let items = menu.items
        guard items.first?.isSeparator != true, items.last?.isSeparator != true else { return false }
        for (first, second) in zip(items, items.dropFirst()) where first.isSeparator && second.isSeparator { return false }
        return items.allSatisfy { $0.submenu.map(hasTidySeparators) ?? true }
    }
}

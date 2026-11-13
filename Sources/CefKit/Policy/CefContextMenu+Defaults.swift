import AppKit
import CCef
import Foundation

// MARK: - The default menu

@MainActor
extension CefContextMenu {
    /// Chromium's menu as CefKit shows it with no configuration.
    ///
    /// Chrome-style browsers get Chrome's menu. Chrome's commands that open
    /// something reach the app as they do from a page: tabs and windows
    /// through ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``,
    /// Chromium's own pages through ``CefRuntime/onChromeTab``, files
    /// through the download decisions.
    ///
    /// Alloy-style browsers get CEF's short menu (navigation, editing,
    /// spelling, print, source) completed with the items Chrome shows for
    /// links, images, audio, video, selections and fields, which CefKit runs
    /// through CEF the same ways, copying to the general pasteboard.
    ///
    /// In both, macOS's Speech and Writing Direction items are sent to
    /// Chromium's view in `pageView` as the AppKit actions the Edit menu
    /// sends, and are left out where that view does not answer them.
    static func adjusted(
        _ menu: CefContextMenu, for target: CefContextMenuTarget, isChromeStyle: Bool, pageView: NSView?
    ) -> CefContextMenu {
        var menu = menu
        if !isChromeStyle {
            menu.items.insert(contentsOf: alloyLeadingItems(for: target), at: 0)
            menu.handle(.viewSource) { browser, target in
                guard let page = target.pageURL, let source = URL(string: "view-source:" + page.absoluteString) else { return }
                browser.openFromContextMenu(source, disposition: .newForegroundTab)
            }
            menu.appendSection(alloyTextServiceItems(for: target))
        }
        routeTextServices(in: &menu, pageView: pageView)
        return menu
    }

    // MARK: Text services

    /// The AppKit actions behind macOS's Speech and Writing Direction
    /// items, which Chromium's view answers as it does from the Edit menu.
    static let textServiceActions: [CefContextMenuCommand: Selector] = [
        .startSpeaking: #selector(NSTextView.startSpeaking(_:)),
        .stopSpeaking: #selector(NSTextView.stopSpeaking(_:)),
        .writingDirectionDefault: #selector(NSResponder.makeBaseWritingDirectionNatural(_:)),
        .writingDirectionLeftToRight: #selector(NSResponder.makeBaseWritingDirectionLeftToRight(_:)),
        .writingDirectionRightToLeft: #selector(NSResponder.makeBaseWritingDirectionRightToLeft(_:)),
    ]

    /// Sends the text-service items to Chromium's view, and removes those
    /// it does not answer.
    ///
    /// Chrome-style menus carry these items from `ui::TextServicesContextMenu`,
    /// but CEF runs a command chosen from a menu the app presents through
    /// Chrome's context menu, which does not know them and crashes.
    static func routeTextServices(in menu: inout CefContextMenu, pageView: NSView?) {
        for (command, action) in textServiceActions where menu.contains(command) {
            guard let responder = pageView.flatMap({ responder(to: action, in: $0) }) else {
                menu.remove(command)
                continue
            }
            menu.handle(command) { [weak responder] _, _ in
                guard let responder else { return }
                NSApp.sendAction(action, to: responder, from: nil)
            }
        }
    }

    /// The first view in `root`, itself included, that answers `action`:
    /// Chromium's page view. AppKit's own text views, such as a field of
    /// the app laid over the page, do not count.
    static func responder(to action: Selector, in root: NSView) -> NSView? {
        if !(root is NSText), root.responds(to: action) { return root }
        for subview in root.subviews {
            if let found = responder(to: action, in: subview) { return found }
        }
        return nil
    }

    /// Speech and Writing Direction submenus for an Alloy-style menu, as
    /// Chrome shows them; empty when Chromium's view does not answer them,
    /// as an offscreen browser's does not.
    static func alloyTextServiceItems(for target: CefContextMenuTarget) -> [Item] {
        func item(_ command: CefContextMenuCommand, _ stringID: Int32) -> Item {
            Item(command, stringID) { _, _ in }
        }
        var items: [Item] = []
        if target.isEditable {
            items.append(Item(
                localized(IDS_CONTENT_CONTEXT_WRITING_DIRECTION_MENU) ?? "Writing Direction",
                submenu: CefContextMenu([
                    item(.writingDirectionDefault, IDS_CONTENT_CONTEXT_WRITING_DIRECTION_DEFAULT),
                    item(.writingDirectionLeftToRight, IDS_CONTENT_CONTEXT_WRITING_DIRECTION_LTR),
                    item(.writingDirectionRightToLeft, IDS_CONTENT_CONTEXT_WRITING_DIRECTION_RTL),
                ]), command: .writingDirectionMenu))
        }
        if target.isEditable || !target.selectedText.isEmpty {
            items.append(Item(
                localized(IDS_SPEECH_MAC) ?? "Speech",
                submenu: CefContextMenu([
                    item(.startSpeaking, IDS_SPEECH_START_SPEAKING_MAC),
                    item(.stopSpeaking, IDS_SPEECH_STOP_SPEAKING_MAC),
                ]), command: .speechMenu))
        }
        return items
    }

    /// The items Chrome shows above the rest for `target`, which CEF's
    /// Alloy-style menu lacks.
    static func alloyLeadingItems(for target: CefContextMenuTarget) -> [Item] {
        var sections: [[Item]] = []
        if let link = target.linkURL {
            sections.append([
                Item(.openLinkInNewTab, IDS_CONTENT_CONTEXT_OPENLINKNEWTAB) { browser, _ in
                    browser.openFromContextMenu(link, disposition: .newBackgroundTab)
                },
                Item(.openLinkInNewWindow, IDS_CONTENT_CONTEXT_OPENLINKNEWWINDOW) { browser, _ in
                    browser.openFromContextMenu(link, disposition: .newWindow)
                },
            ])
            sections.append([
                Item(.saveLinkAs, IDS_CONTENT_CONTEXT_SAVELINKAS) { browser, _ in browser.startDownload(link) },
                Item(.copyLinkAddress, IDS_CONTENT_CONTEXT_COPYLINKLOCATION) { _, _ in copyToPasteboard(link) },
            ])
        }
        if let source = target.sourceURL {
            switch target.mediaType {
            case .image:
                sections.append([
                    Item(.openImageInNewTab, IDS_CONTENT_CONTEXT_OPENIMAGENEWTAB) { browser, _ in
                        browser.openFromContextMenu(source, disposition: .newBackgroundTab)
                    },
                    Item(.saveImageAs, IDS_CONTENT_CONTEXT_SAVEIMAGEAS) { browser, _ in browser.startDownload(source) },
                    Item(.copyImage, IDS_CONTENT_CONTEXT_COPYIMAGE) { browser, _ in
                        guard let image = await browser.downloadImage(source) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    },
                    Item(.copyImageAddress, IDS_CONTENT_CONTEXT_COPYIMAGELOCATION) { _, _ in copyToPasteboard(source) },
                ])
            case .video, .audio:
                let isVideo = target.mediaType == .video
                var items = [
                    Item(.openMediaInNewTab, isVideo ? IDS_CONTENT_CONTEXT_OPENVIDEONEWTAB : IDS_CONTENT_CONTEXT_OPENAUDIONEWTAB) { browser, _ in
                        browser.openFromContextMenu(source, disposition: .newBackgroundTab)
                    },
                ]
                if target.mediaState.contains(.canSave) {
                    items.append(Item(.saveMediaAs, isVideo ? IDS_CONTENT_CONTEXT_SAVEVIDEOAS : IDS_CONTENT_CONTEXT_SAVEAUDIOAS) { browser, _ in
                        browser.startDownload(source)
                    })
                }
                items.append(Item(.copyMediaAddress, isVideo ? IDS_CONTENT_CONTEXT_COPYVIDEOLOCATION : IDS_CONTENT_CONTEXT_COPYAUDIOLOCATION) { _, _ in
                    copyToPasteboard(source)
                })
                sections.append(items)
            default:
                break
            }
        }
        let selection = target.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty, let title = localized(IDS_CONTENT_CONTEXT_LOOK_UP) {
            sections.append([
                Item(command: .lookUp, title: title.replacingOccurrences(of: "$1", with: truncated(selection))) { browser, target in
                    guard let view = CefContextMenuPresenter.contentView(of: browser) else { return }
                    view.showDefinition(
                        for: NSAttributedString(string: selection),
                        at: CefContextMenuPresenter.viewPoint(of: target.location, in: view))
                },
            ])
        }
        if target.isEditable {
            sections.append([Item(.emojiAndSymbols, IDS_CONTENT_CONTEXT_EMOJI) { _, _ in NSApp.orderFrontCharacterPalette(nil) }])
        }
        guard !sections.isEmpty else { return [] }
        return Array(sections.joined(separator: [Item.separator])) + [.separator]
    }

    /// Chromium's string `id` in Chromium's locale, or `nil` when the
    /// runtime has none.
    static func localized(_ id: Int32) -> String? {
        CefRuntime.shared.localizedString(CefRuntime.StringID(rawValue: id))
    }

    /// The selection as Chrome quotes it in an item's title: at most 50
    /// characters.
    static func truncated(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 50 ? flat.prefix(50) + "…" : flat
    }

    static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// Removes the items that run any of `commands`, wherever they are.
    mutating func remove(contentsOf commands: Set<CefContextMenuCommand>) {
        guard !commands.isEmpty else { return }
        removeAll { $0.command.map(commands.contains) ?? false }
    }
}

@MainActor
extension CefContextMenu.Item {
    /// An item CefKit adds for one of Chromium's commands, titled with
    /// Chromium's string `stringID`. Choosing it runs `action`.
    init(_ command: CefContextMenuCommand, _ stringID: Int32, action: @escaping CefContextMenu.Action) {
        self.init(command: command, title: CefContextMenu.localized(stringID) ?? "\(command)", action: action)
    }
}

// MARK: - What the items do

extension CefBrowser {
    /// Opens `url` as a link the user chose to open somewhere else: asks
    /// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``, as a page's
    /// `target=_blank` link does, and carries out the answer.
    func openFromContextMenu(_ url: URL, disposition: CefWindowOpenDisposition) {
        let request = CefWindowOpenRequest(
            targetURL: url, disposition: disposition, hasUserGesture: true,
            isSourceOffscreen: isOffscreen, isSourceChromeStyle: isChromeStyle)
        let decided = (delegate ?? CefDefaultBrowserDelegate.shared).browser(self, decideWindowOpenFor: request)
        switch CefWindowOpenPolicy.resolve(decided, for: request) {
        case .allowNativePopup: openPopupInNewBrowser(request)
        case .openInCurrentBrowser: load(url)
        case .deny, .handled: break
        }
    }
}

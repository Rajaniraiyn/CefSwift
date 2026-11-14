import Foundation

/// A context menu, as a value: Chromium's items, in Chromium's words, and
/// the ones your app adds.
///
/// CefKit reads the menu Chromium builds for a click into this value,
/// passes it through ``CefBrowser/Configuration/ContextMenu/customize(_:)``
/// in order, and shows the result
/// (``CefBrowserDelegate/browser(_:runContextMenu:for:)``). Chromium's items
/// keep their ``Item/command`` and run natively when chosen, unless you give
/// one an ``Item/action``; your items run their action.
///
/// ```swift
/// browserConfiguration.contextMenu.customize { menu, target in
///     menu.remove(.viewSource)
///     if target.linkURL != nil {
///         menu.insert(CefContextMenu.Item("Copy as Markdown") { browser, target in
///             copyMarkdownLink(target.linkURL!, title: browser.title)
///         }, after: .copyLinkAddress)
///     }
/// }
/// ```
public struct CefContextMenu: Sendable {
    /// The items, top to bottom.
    public var items: [Item]

    public init(_ items: [Item] = []) {
        self.items = items
    }
}

extension CefContextMenu {
    /// What an item of yours does when chosen, given the browser and what
    /// the menu was opened on.
    public typealias Action = @MainActor @Sendable (CefBrowser, CefContextMenuTarget) async -> Void

    /// One row of a ``CefContextMenu``: a command, a submenu or a separator.
    public struct Item: Sendable {
        /// The text shown, without mnemonic markers. Chromium's items carry
        /// Chromium's text, in Chromium's language (``CefRuntime/locale``).
        public var title: String
        /// The Chromium command the item runs, or `nil` for your items and
        /// separators.
        public private(set) var command: CefContextMenuCommand?
        /// What the item does instead of Chromium's command, or `nil` to
        /// run ``command``. Setting it on Chromium's item handles the
        /// command yourself.
        public var action: Action?
        /// The submenu the item opens, or `nil` for a command.
        public var submenu: CefContextMenu?
        /// Whether the item can be chosen.
        public var isEnabled: Bool
        /// Whether the item shows a check mark, as Chromium's check and radio
        /// items do when on.
        public var isChecked: Bool
        /// Whether the item is a separator line.
        public private(set) var isSeparator: Bool

        /// The command ID Chromium gave the item, which choosing it reports.
        package private(set) var chromiumID: Int?
        /// Chromium's kind of item (command, check, radio, submenu) and
        /// radio group, for diagnostics.
        package private(set) var chromiumKind: String?
        package private(set) var chromiumGroup: Int?

        /// An item of yours that runs `action`.
        public init(
            _ title: String, isEnabled: Bool = true, isChecked: Bool = false,
            action: @escaping Action
        ) {
            self.title = title
            self.action = action
            self.isEnabled = isEnabled
            self.isChecked = isChecked
            isSeparator = false
        }

        /// A submenu of yours.
        public init(_ title: String, isEnabled: Bool = true, submenu: CefContextMenu) {
            self.title = title
            self.submenu = submenu
            self.isEnabled = isEnabled
            isChecked = false
            isSeparator = false
        }

        /// A separator line. Separators at either end of a menu, or next to
        /// another, are dropped when the menu shows.
        public static var separator: Item {
            var item = Item(title: "", isEnabled: false)
            item.isSeparator = true
            return item
        }

        /// One of Chromium's items, as Chromium built it.
        package init(
            chromiumID: Int, title: String, submenu: CefContextMenu? = nil,
            isEnabled: Bool = true, isChecked: Bool = false, kind: String = "command", group: Int? = nil,
            isChromeStyle: Bool
        ) {
            self.init(title: title, isEnabled: isEnabled)
            self.chromiumID = chromiumID
            chromiumKind = kind
            chromiumGroup = group
            command = CefContextMenuCommand(chromiumID: chromiumID, isChromeStyle: isChromeStyle)
            self.submenu = submenu
            self.isChecked = isChecked
        }

        /// A submenu CefKit adds for one of Chromium's.
        package init(_ title: String, submenu: CefContextMenu, command: CefContextMenuCommand) {
            self.init(title, submenu: submenu)
            self.command = command
        }

        /// An item CefKit adds for one of Chromium's commands, which runs
        /// `action` when chosen.
        package init(command: CefContextMenuCommand, title: String, action: @escaping Action) {
            self.init(title: title, isEnabled: true)
            self.command = command
            self.action = action
        }

        private init(title: String, isEnabled: Bool) {
            self.title = title
            self.isEnabled = isEnabled
            isChecked = false
            isSeparator = false
        }
    }
}

// MARK: - Finding and changing items

extension CefContextMenu {
    /// The commands of Chromium's items, top to bottom, each followed by
    /// those of its submenu.
    public var commands: [CefContextMenuCommand] {
        items.flatMap { item in
            (item.command.map { [$0] } ?? []) + (item.submenu?.commands ?? [])
        }
    }

    /// Whether an item, in this menu or a submenu, runs `command`.
    public func contains(_ command: CefContextMenuCommand) -> Bool {
        path(of: command) != nil
    }

    /// The item that runs `command`, in this menu or a submenu. Setting it
    /// replaces that item; setting `nil` removes it.
    public subscript(command: CefContextMenuCommand) -> Item? {
        get { path(of: command).map { self[path: $0] } }
        set {
            guard let path = path(of: command) else { return }
            if let newValue {
                self[path: path] = newValue
            } else {
                remove(at: path)
            }
        }
    }

    /// Removes the items that run any of `commands`, wherever they are.
    public mutating func remove(_ commands: CefContextMenuCommand...) {
        let commands = Set(commands)
        removeAll { $0.command.map(commands.contains) ?? false }
    }

    /// Removes the items, wherever they are, that `shouldBeRemoved` picks.
    public mutating func removeAll(where shouldBeRemoved: (Item) throws -> Bool) rethrows {
        try items.removeAll(where: shouldBeRemoved)
        for index in items.indices where items[index].submenu != nil {
            try items[index].submenu!.removeAll(where: shouldBeRemoved)
        }
    }

    /// Inserts `newItems` after the item that runs `command`, in the menu
    /// that holds it. Returns `false`, and inserts nothing, when no item
    /// runs `command`.
    @discardableResult
    public mutating func insert(_ newItems: Item..., after command: CefContextMenuCommand) -> Bool {
        insert(newItems, at: command, offset: 1)
    }

    /// Inserts `newItems` before the item that runs `command`, in the menu
    /// that holds it. Returns `false`, and inserts nothing, when no item
    /// runs `command`.
    @discardableResult
    public mutating func insert(_ newItems: Item..., before command: CefContextMenuCommand) -> Bool {
        insert(newItems, at: command, offset: 0)
    }

    /// Adds `newItems` at the end, set apart by a separator.
    public mutating func appendSection(_ newItems: [Item]) {
        guard !newItems.isEmpty else { return }
        items.append(.separator)
        items.append(contentsOf: newItems)
    }

    /// Runs `action` instead of Chromium's command when the item that runs
    /// `command` is chosen, keeping Chromium's title. Returns `false` when
    /// no item runs `command`.
    @discardableResult
    public mutating func handle(_ command: CefContextMenuCommand, with action: @escaping Action) -> Bool {
        guard let path = path(of: command) else { return false }
        self[path: path].action = action
        return true
    }

    // MARK: Paths

    /// The indices leading to the first item that runs `command`: one per
    /// level of submenu.
    func path(of command: CefContextMenuCommand) -> [Int]? {
        for (index, item) in items.enumerated() {
            if item.command == command { return [index] }
            if let inner = item.submenu?.path(of: command) { return [index] + inner }
        }
        return nil
    }

    subscript(path path: [Int]) -> Item {
        get {
            path.count == 1 ? items[path[0]] : items[path[0]].submenu![path: Array(path.dropFirst())]
        }
        set {
            if path.count == 1 {
                items[path[0]] = newValue
            } else {
                items[path[0]].submenu![path: Array(path.dropFirst())] = newValue
            }
        }
    }

    private mutating func remove(at path: [Int]) {
        if path.count == 1 {
            items.remove(at: path[0])
        } else {
            items[path[0]].submenu!.remove(at: Array(path.dropFirst()))
        }
    }

    private mutating func insert(_ newItems: [Item], at command: CefContextMenuCommand, offset: Int) -> Bool {
        guard let path = path(of: command) else { return false }
        insert(newItems, at: path, offset: offset)
        return true
    }

    private mutating func insert(_ newItems: [Item], at path: [Int], offset: Int) {
        if path.count == 1 {
            items.insert(contentsOf: newItems, at: path[0] + offset)
        } else {
            items[path[0]].submenu!.insert(newItems, at: Array(path.dropFirst()), offset: offset)
        }
    }

    // MARK: Tidying

    /// The menu as it shows: without separators at either end or next to
    /// another, and without empty submenus.
    package var normalized: CefContextMenu {
        var result: [Item] = []
        for var item in items {
            if let submenu = item.submenu {
                let tidy = submenu.normalized
                guard !tidy.items.isEmpty else { continue }
                item.submenu = tidy
            }
            if item.isSeparator, result.last?.isSeparator ?? true { continue }
            result.append(item)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return CefContextMenu(result)
    }

    /// The item at `path`, for choosing it from a presented menu.
    package func item(at path: [Int]) -> Item? {
        guard let first = path.first, items.indices.contains(first) else { return nil }
        if path.count == 1 { return items[first] }
        return items[first].submenu?.item(at: Array(path.dropFirst()))
    }
}

extension CefContextMenu.Item {
    /// The command ID Chromium gave the item, its kind and radio group.
    @_spi(Testing) public var chromiumDetails: (id: Int, kind: String, group: Int?)? {
        chromiumID.map { ($0, chromiumKind ?? "command", chromiumGroup) }
    }
}

extension CefContextMenu.Item: CustomStringConvertible {
    /// The item for logs and test output: its title and command.
    public var description: String {
        if isSeparator { return "—" }
        var text = command.map { "\($0) \"\(title)\"" } ?? "\"\(title)\""
        if !isEnabled { text += " (disabled)" }
        if isChecked { text += " (checked)" }
        if let submenu { text += " [" + submenu.items.map(\.description).joined(separator: ", ") + "]" }
        return text
    }
}

extension CefContextMenu: CustomStringConvertible {
    public var description: String {
        "[" + items.map(\.description).joined(separator: ", ") + "]"
    }
}

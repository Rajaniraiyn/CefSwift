import CoreGraphics
import Foundation

/// A DevTools Protocol command with typed parameters and a typed result.
///
/// The value's encoded properties are the command's parameters, and
/// ``Result`` decodes the reply's result object. CefKit declares the
/// commands browser and agent builders use most (screenshots, input, the
/// accessibility tree and DOM snapshots) under ``CefDevTools``; declare
/// any other the same way:
///
/// ```swift
/// struct GetLayoutMetrics: CefDevToolsCommand {
///     static let method = "Page.getLayoutMetrics"
///     struct Result: Decodable, Sendable {
///         struct Viewport: Decodable, Sendable { var clientWidth: Double; var clientHeight: Double }
///         var cssLayoutViewport: Viewport
///     }
/// }
/// let metrics = try await page.devTools.send(GetLayoutMetrics())
/// ```
///
/// Optional properties that are `nil` are left out of the parameters, so
/// Chromium applies its defaults.
public protocol CefDevToolsCommand: Encodable, Sendable {
    /// What the reply's result object decodes as. ``CefDevTools/NoResult``
    /// for a command whose result is empty.
    associatedtype Result: Decodable & Sendable
    /// The protocol method, `Domain.method`.
    static var method: String { get }
}

/// A DevTools Protocol event with typed parameters, for
/// `CefDevTools.events(_:bufferingPolicy:)`.
public protocol CefDevToolsEvent: Decodable, Sendable {
    /// The protocol event, `Domain.event`.
    static var method: String { get }
}

extension CefDevTools {
    /// The result of a command that returns nothing.
    public struct NoResult: Decodable, Sendable, Equatable {
        /// Creates a value of your own, for previews and tests.
        public init() {}
    }

    /// Sends `command` and decodes its result.
    ///
    /// The parameters are encoded once into the message, and the result is
    /// decoded straight from the reply's bytes, with no `CefJSON` tree in
    /// between: a 2 MB screenshot is one base64 decode into `Data`. It
    /// waits, retries and throws as ``send(_:_:)`` does; an `X.enable` or
    /// `X.disable` command takes or returns the domain's lease as there.
    @discardableResult
    public func send<Command: CefDevToolsCommand>(_ command: Command) async throws -> Command.Result {
        let params = try JSONEncoder().encode(command)
        if Self.lease(for: Command.method) != nil {
            return try await send(Command.method, CefJSON(data: params)).decode(Command.Result.self)
        }
        return try Self.decode(Command.Result.self, from: await sendEncoded(Command.method, params: params), for: Command.method)
    }

    /// The stream of an event, decoded as `Event` straight from the event's
    /// bytes. Enable the event's domain first. An event that does not
    /// decode as `Event` is dropped and logged. The stream ends when the
    /// page closes or the consuming task is cancelled; `bufferingPolicy`
    /// is as in the untyped `events(_:bufferingPolicy:)`.
    public func events<Event: CefDevToolsEvent>(
        _ type: Event.Type,
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .bufferingNewest(1_000)
    ) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let token = UUID(), method = Event.method
            let decoder = JSONDecoder()
            eventDecoders[method, default: [:]][token] = { bytes in
                do {
                    continuation.yield(try decoder.decode(Event.self, from: bytes))
                } catch {
                    CefLog.error("devTools: dropped \(method) that does not decode as \(Event.self): \(error)")
                }
            }
            typedStreamFinishers[token] = { continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventDecoders[method]?[token] = nil
                    self?.typedStreamFinishers[token] = nil
                }
            }
        }
    }
}

// MARK: - Modifiers

extension CefDevTools {
    /// Modifier keys held during an input event, as the protocol numbers
    /// them.
    public struct Modifiers: OptionSet, Sendable, Hashable, Encodable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let option = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let command = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

// MARK: - Page

extension CefDevTools {
    /// Commands of the protocol's `Page` domain.
    public enum Page {
        /// `Page.captureScreenshot`: a picture of the page, as the
        /// compositor draws it, a background page's included.
        ///
        /// ``CefPage/snapshot()`` returns the frame an offscreen view
        /// shows without the protocol; this command takes a format, a
        /// region, a scale and the page beyond the viewport.
        public struct CaptureScreenshot: CefDevToolsCommand {
            public static let method = "Page.captureScreenshot"

            /// An image format.
            public enum Format: String, Sendable, Encodable {
                case png, jpeg, webp
            }

            /// The image format; PNG when `nil`.
            public var format: Format?
            /// The compression quality, 0 to 100, for JPEG and WebP.
            public var quality: Int?
            /// The region to capture, in CSS pixels of the page, and the
            /// scale to draw it at.
            public var clip: (rect: CGRect, scale: Double)?
            /// Captures the whole page, not only what the viewport shows.
            public var capturesBeyondViewport: Bool?
            /// Trades image size for speed.
            public var optimizesForSpeed: Bool?

            public init(
                format: Format? = nil, quality: Int? = nil, clip: (rect: CGRect, scale: Double)? = nil,
                capturesBeyondViewport: Bool? = nil, optimizesForSpeed: Bool? = nil
            ) {
                self.format = format
                self.quality = quality
                self.clip = clip
                self.capturesBeyondViewport = capturesBeyondViewport
                self.optimizesForSpeed = optimizesForSpeed
            }

            public struct Result: Decodable, Sendable {
                /// The encoded image.
                public var data: Data

                /// Creates a value of your own, for previews and tests.
                public init(data: Data) { self.data = data }
            }

            private enum CodingKeys: String, CodingKey {
                case format, quality, clip, captureBeyondViewport, optimizeForSpeed
            }

            private enum ClipKeys: String, CodingKey {
                case x, y, width, height, scale
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(format, forKey: .format)
                try container.encodeIfPresent(quality, forKey: .quality)
                if let clip {
                    var region = container.nestedContainer(keyedBy: ClipKeys.self, forKey: .clip)
                    try region.encode(clip.rect.minX, forKey: .x)
                    try region.encode(clip.rect.minY, forKey: .y)
                    try region.encode(clip.rect.width, forKey: .width)
                    try region.encode(clip.rect.height, forKey: .height)
                    try region.encode(clip.scale, forKey: .scale)
                }
                try container.encodeIfPresent(capturesBeyondViewport, forKey: .captureBeyondViewport)
                try container.encodeIfPresent(optimizesForSpeed, forKey: .optimizeForSpeed)
            }
        }
    }
}

// MARK: - Input

extension CefDevTools {
    /// Commands of the protocol's `Input` domain: input that reaches the
    /// page as if the user gave it, in windowed and offscreen pages alike.
    /// Coordinates are CSS pixels from the viewport's top left.
    public enum Input {
        /// A mouse button.
        public enum MouseButton: String, Sendable, Encodable {
            case none, left, middle, right, back, forward
        }

        /// `Input.dispatchMouseEvent`. A click is a `.pressed` and a
        /// `.released` event at the same point with the same click count.
        public struct DispatchMouseEvent: CefDevToolsCommand {
            public static let method = "Input.dispatchMouseEvent"
            public typealias Result = NoResult

            /// What the mouse did.
            public enum Kind: String, Sendable, Encodable {
                case pressed = "mousePressed"
                case released = "mouseReleased"
                case moved = "mouseMoved"
                case wheel = "mouseWheel"
            }

            public var kind: Kind
            public var location: CGPoint
            public var button: MouseButton?
            /// 1 for a click, 2 for a double click.
            public var clickCount: Int?
            public var modifiers: Modifiers?
            /// For ``Kind/wheel``: how far to scroll, in CSS pixels.
            public var scrollDelta: CGVector?

            public init(
                _ kind: Kind, at location: CGPoint, button: MouseButton? = nil, clickCount: Int? = nil,
                modifiers: Modifiers? = nil, scrollDelta: CGVector? = nil
            ) {
                self.kind = kind
                self.location = location
                self.button = button
                self.clickCount = clickCount
                self.modifiers = modifiers
                self.scrollDelta = scrollDelta
            }

            private enum CodingKeys: String, CodingKey {
                case type, x, y, button, clickCount, modifiers, deltaX, deltaY
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(kind, forKey: .type)
                try container.encode(location.x, forKey: .x)
                try container.encode(location.y, forKey: .y)
                try container.encodeIfPresent(button, forKey: .button)
                try container.encodeIfPresent(clickCount, forKey: .clickCount)
                try container.encodeIfPresent(modifiers, forKey: .modifiers)
                if let scrollDelta {
                    try container.encode(scrollDelta.dx, forKey: .deltaX)
                    try container.encode(scrollDelta.dy, forKey: .deltaY)
                } else if kind == .wheel {
                    // Chromium requires both deltas for a wheel event.
                    try container.encode(0.0, forKey: .deltaX)
                    try container.encode(0.0, forKey: .deltaY)
                }
            }
        }

        /// `Input.dispatchKeyEvent`.
        ///
        /// Typing a character is a `.keyDown` with its `text` and a
        /// `.keyUp`; ``InsertText`` types a string at once. On the Mac,
        /// shortcuts such as ⌘A reach the page's editing only through
        /// `commands` (`["selectAll"]`), as AppKit's selectors without the
        /// colon.
        public struct DispatchKeyEvent: CefDevToolsCommand {
            public static let method = "Input.dispatchKeyEvent"
            public typealias Result = NoResult

            /// What the key did.
            public enum Kind: String, Sendable, Encodable {
                /// A key press that types `text`, if it has any.
                case keyDown
                case keyUp
                /// A key press that types nothing.
                case rawKeyDown
                /// A character typed, without a key press.
                case char
            }

            public var kind: Kind
            /// The DOM `key` value, such as `"Enter"` or `"a"`.
            public var key: String?
            /// The DOM `code` value, such as `"Enter"` or `"KeyA"`.
            public var code: String?
            /// The text the key types.
            public var text: String?
            /// The Windows virtual key code, which some pages read as
            /// `keyCode`: 13 for Enter.
            public var windowsVirtualKeyCode: Int?
            public var modifiers: Modifiers?
            /// Editing commands to run, such as `"selectAll"` or `"copy"`.
            public var commands: [String]?

            public init(
                _ kind: Kind, key: String? = nil, code: String? = nil, text: String? = nil,
                windowsVirtualKeyCode: Int? = nil, modifiers: Modifiers? = nil, commands: [String]? = nil
            ) {
                self.kind = kind
                self.key = key
                self.code = code
                self.text = text
                self.windowsVirtualKeyCode = windowsVirtualKeyCode
                self.modifiers = modifiers
                self.commands = commands
            }

            private enum CodingKeys: String, CodingKey {
                case type, key, code, text, windowsVirtualKeyCode, modifiers, commands
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(kind, forKey: .type)
                try container.encodeIfPresent(key, forKey: .key)
                try container.encodeIfPresent(code, forKey: .code)
                try container.encodeIfPresent(text, forKey: .text)
                try container.encodeIfPresent(windowsVirtualKeyCode, forKey: .windowsVirtualKeyCode)
                try container.encodeIfPresent(modifiers, forKey: .modifiers)
                try container.encodeIfPresent(commands, forKey: .commands)
            }
        }

        /// `Input.insertText`: types `text` into the focused element, as an
        /// input method commits it, without key events.
        public struct InsertText: CefDevToolsCommand {
            public static let method = "Input.insertText"
            public typealias Result = NoResult

            public var text: String

            public init(_ text: String) {
                self.text = text
            }
        }
    }
}

// MARK: - Accessibility

extension CefDevTools {
    /// Commands of the protocol's `Accessibility` domain.
    public enum Accessibility {
        /// `Accessibility.getFullAXTree`: the main frame's accessibility
        /// tree, as assistive apps see it, with roles and names computed.
        ///
        /// It needs no `Accessibility.enable`: Chromium turns accessibility
        /// on for the page for the call. For a large page, limit `depth`.
        public struct GetFullAXTree: CefDevToolsCommand {
            public static let method = "Accessibility.getFullAXTree"

            /// How many levels to return; the whole tree when `nil`.
            public var depth: Int?
            /// The frame whose tree to return; the main frame when `nil`.
            public var frameID: String?

            public init(depth: Int? = nil, frameID: String? = nil) {
                self.depth = depth
                self.frameID = frameID
            }

            private enum CodingKeys: String, CodingKey {
                case depth
                case frameID = "frameId"
            }

            public struct Result: Decodable, Sendable {
                /// The nodes, the root first.
                public var nodes: [Node]

                /// Creates a value of your own, for previews and tests.
                public init(nodes: [Node]) { self.nodes = nodes }
            }
        }

        /// A node of the accessibility tree.
        public struct Node: Decodable, Sendable, Equatable, Identifiable {
            public var id: String
            /// Whether assistive apps skip the node.
            public var isIgnored: Bool
            /// The ARIA role, such as `"button"`, or Chromium's internal
            /// role for a node that has none.
            public var role: String?
            /// The accessible name.
            public var name: String?
            /// The accessible description.
            public var description: String?
            /// The node's value, such as a text field's text.
            public var value: CefJSON?
            public var parentID: String?
            public var childIDs: [String]
            /// The DOM node's identifier, for `DOM` commands such as
            /// `DOM.getBoxModel` and `DOM.focus`.
            public var backendDOMNodeID: Int?

            /// Creates a value of your own, for previews and tests.
            public init(
                id: String, isIgnored: Bool = false, role: String? = nil, name: String? = nil,
                description: String? = nil, value: CefJSON? = nil, parentID: String? = nil,
                childIDs: [String] = [], backendDOMNodeID: Int? = nil
            ) {
                self.id = id
                self.isIgnored = isIgnored
                self.role = role
                self.name = name
                self.description = description
                self.value = value
                self.parentID = parentID
                self.childIDs = childIDs
                self.backendDOMNodeID = backendDOMNodeID
            }

            private enum CodingKeys: String, CodingKey {
                case nodeId, ignored, role, name, description, value, parentId, childIds, backendDOMNodeId
            }

            /// The protocol's `AXValue`, of which only the value is kept.
            private struct Value: Decodable {
                var value: CefJSON?
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .nodeId)
                isIgnored = try container.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
                role = try container.decodeIfPresent(Value.self, forKey: .role)?.value?.stringValue
                name = try container.decodeIfPresent(Value.self, forKey: .name)?.value?.stringValue
                description = try container.decodeIfPresent(Value.self, forKey: .description)?.value?.stringValue
                value = try container.decodeIfPresent(Value.self, forKey: .value)?.value
                parentID = try container.decodeIfPresent(String.self, forKey: .parentId)
                childIDs = try container.decodeIfPresent([String].self, forKey: .childIds) ?? []
                backendDOMNodeID = try container.decodeIfPresent(Int.self, forKey: .backendDOMNodeId)
            }
        }
    }
}

// MARK: - DOMSnapshot

extension CefDevTools {
    /// Commands of the protocol's `DOMSnapshot` domain.
    public enum DOMSnapshot {
        /// `DOMSnapshot.captureSnapshot`: every document of the page, its
        /// frames' included, flattened into tables, with each laid-out
        /// node's bounds and text. Strings are indexes into
        /// ``Result/strings``; ``Result/string(_:)`` reads one.
        ///
        /// It needs no `DOMSnapshot.enable`.
        public struct CaptureSnapshot: CefDevToolsCommand {
            public static let method = "DOMSnapshot.captureSnapshot"

            /// The CSS properties to return for each laid-out node, such as
            /// `"display"`; none when empty.
            public var computedStyles: [String]

            public init(computedStyles: [String] = []) {
                self.computedStyles = computedStyles
            }

            public struct Result: Decodable, Sendable {
                public var documents: [Document]
                /// The strings the tables refer to by index.
                public var strings: [String]

                /// The string at `index`, or `nil` for -1 and indexes out of
                /// range.
                public func string(_ index: Int) -> String? {
                    strings.indices.contains(index) ? strings[index] : nil
                }

                /// Creates a value of your own, for previews and tests.
                public init(documents: [Document], strings: [String]) {
                    self.documents = documents
                    self.strings = strings
                }
            }
        }

        /// One document of a snapshot.
        public struct Document: Decodable, Sendable {
            /// The document's address, as a string index.
            public var url: Int
            /// The document's title, as a string index.
            public var title: Int
            /// The frame's identifier, as a string index.
            public var frameID: Int
            public var nodes: Nodes
            public var layout: Layout

            private enum CodingKeys: String, CodingKey {
                case url = "documentURL", title, frameID = "frameId", nodes, layout
            }
        }

        /// A document's DOM nodes, one column per property, indexed by node.
        public struct Nodes: Decodable, Sendable {
            /// Each node's parent's index, -1 for the root.
            public var parentIndex: [Int]
            /// Each node's DOM `nodeType`: 1 for an element, 3 for text.
            public var nodeType: [Int]
            /// Each node's `nodeName`, as a string index.
            public var nodeName: [Int]
            /// Each node's `nodeValue`, as a string index, -1 for none.
            public var nodeValue: [Int]
            /// Each node's DOM identifier, for `DOM` commands.
            public var backendNodeID: [Int]
            /// Each node's attributes, as string indexes: name, value, name,
            /// value…
            public var attributes: [[Int]]
            /// The indexes of the nodes that handle clicks.
            public var clickableNodes: [Int]

            private enum CodingKeys: String, CodingKey {
                case parentIndex, nodeType, nodeName, nodeValue, backendNodeId, attributes, isClickable
            }

            private struct Indexes: Decodable {
                var index: [Int]
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                parentIndex = try container.decodeIfPresent([Int].self, forKey: .parentIndex) ?? []
                nodeType = try container.decodeIfPresent([Int].self, forKey: .nodeType) ?? []
                nodeName = try container.decodeIfPresent([Int].self, forKey: .nodeName) ?? []
                nodeValue = try container.decodeIfPresent([Int].self, forKey: .nodeValue) ?? []
                backendNodeID = try container.decodeIfPresent([Int].self, forKey: .backendNodeId) ?? []
                attributes = try container.decodeIfPresent([[Int]].self, forKey: .attributes) ?? []
                clickableNodes = try container.decodeIfPresent(Indexes.self, forKey: .isClickable)?.index ?? []
            }
        }

        /// A document's laid-out nodes, one column per property, indexed by
        /// layout object.
        public struct Layout: Decodable, Sendable {
            /// Each layout object's node, as an index into ``Nodes``.
            public var nodeIndex: [Int]
            /// Each layout object's bounds in the document, in device
            /// pixels: CSS pixels times `window.devicePixelRatio`, which
            /// includes the zoom level. Divide by it for the coordinates
            /// ``CefDevTools/Input`` takes.
            public var bounds: [CGRect]
            /// Each layout object's text, as a string index, -1 for none.
            public var text: [Int]
            /// Each layout object's ``CaptureSnapshot/computedStyles``, as
            /// string indexes, in the order asked for.
            public var styles: [[Int]]

            private enum CodingKeys: String, CodingKey {
                case nodeIndex, bounds, text, styles
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                nodeIndex = try container.decodeIfPresent([Int].self, forKey: .nodeIndex) ?? []
                bounds = try (container.decodeIfPresent([[Double]].self, forKey: .bounds) ?? []).map { box in
                    box.count == 4 ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : .null
                }
                text = try container.decodeIfPresent([Int].self, forKey: .text) ?? []
                styles = try container.decodeIfPresent([[Int]].self, forKey: .styles) ?? []
            }
        }
    }
}

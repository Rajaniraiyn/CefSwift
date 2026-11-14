import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import CCef
@testable import CefKit

/// File chooser requests, the frame list and key-view traversal, without
/// Chromium.
@Suite struct FileDialogTests {
    @Test func modesMapFromCEF() {
        #expect(CefFileDialog.Mode(cefValue: FILE_DIALOG_OPEN) == .open)
        #expect(CefFileDialog.Mode(cefValue: FILE_DIALOG_OPEN_MULTIPLE) == .openMultiple)
        #expect(CefFileDialog.Mode(cefValue: FILE_DIALOG_OPEN_FOLDER) == .openFolder)
        #expect(CefFileDialog.Mode(cefValue: FILE_DIALOG_SAVE) == .save)
    }

    @Test func extensionFiltersMapToTypes() {
        #expect(CefFileDialog.AcceptedType(filter: ".txt").contentTypes == [.plainText])
        #expect(CefFileDialog.AcceptedType(filter: ".png").contentTypes == [.png])
    }

    @Test func mimeFiltersMapToTypes() {
        #expect(CefFileDialog.AcceptedType(filter: "image/*").contentTypes == [.image])
        #expect(CefFileDialog.AcceptedType(filter: "application/pdf").contentTypes == [.pdf])
        // Expanded extensions win over the MIME type.
        let expanded = CefFileDialog.AcceptedType(filter: "image/*", extensions: ["png", "jpg", "png"])
        #expect(expanded.contentTypes == [.png, .jpeg])
        #expect(CefFileDialog.AcceptedType(filter: "x-unknown/zzz").contentTypes.isEmpty)
    }

    @Test func dialogTypesAreDeduplicated() {
        let dialog = CefFileDialog(mode: .open, acceptedTypes: [
            .init(filter: ".txt"), .init(filter: "text/plain"), .init(filter: ".txt"),
        ])
        #expect(dialog.contentTypes == [.plainText])
    }

    @MainActor @Test func panelsFollowTheMode() {
        let folder = CefFileDialogPresenter.makePanel(for: CefFileDialog(mode: .openFolder))
        #expect((folder as? NSOpenPanel)?.canChooseDirectories == true)
        #expect((folder as? NSOpenPanel)?.canChooseFiles == false)
        let multiple = CefFileDialogPresenter.makePanel(for: CefFileDialog(mode: .openMultiple))
        #expect((multiple as? NSOpenPanel)?.allowsMultipleSelection == true)
        let save = CefFileDialogPresenter.makePanel(for: CefFileDialog(
            mode: .save, defaultURL: URL(fileURLWithPath: "/tmp/report.txt")))
        #expect(!(save is NSOpenPanel))
        #expect(save.nameFieldStringValue == "report.txt")
    }
}

@MainActor @Suite struct FrameListTests {
    @Test func attachDetachAndMainFrameChanges() {
        let browser = CefBrowser(url: URL(string: "about:blank")!)
        browser.frameDidAttach(CefFrame(id: "child", url: nil, isMain: false, parentID: "main"))
        browser.frameDidAttach(CefFrame(id: "main", url: URL(string: "https://a.example/"), isMain: true))
        #expect(browser.frames.map(\.id) == ["main", "child"])
        #expect(browser.mainFrame?.id == "main")

        browser.frameDidUpdate("child", url: URL(string: "https://b.example/"))
        #expect(browser.frame(withID: "child")?.url?.host == "b.example")

        browser.frameDidAttach(CefFrame(id: "main2", url: nil, isMain: false))
        browser.mainFrameDidChange(from: "main", to: "main2")
        #expect(browser.mainFrame?.id == "main2")
        #expect(browser.frame(withID: "main")?.isMain == false)

        browser.frameDidDetach("child")
        #expect(browser.frame(withID: "child") == nil)
        #expect(browser.frames.count == 2)
    }
}

@MainActor @Suite struct KeyViewTraversalTests {
    final class KeyView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
    }

    @Test func skipsTheBrowsersOwnSubviews() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [], backing: .buffered, defer: true)
        let before = KeyView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let host = KeyView(frame: NSRect(x: 20, y: 0, width: 100, height: 100))
        let inner = KeyView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let after = KeyView(frame: NSRect(x: 200, y: 0, width: 10, height: 10))
        host.addSubview(inner)
        [before, host, after].forEach(window.contentView!.addSubview)
        before.nextKeyView = host
        host.nextKeyView = inner
        inner.nextKeyView = after
        after.nextKeyView = before
        #expect(CefBrowser.keyView(after: host, forward: true) === after)
        #expect(CefBrowser.keyView(after: host, forward: false) === before)
        #expect(CefBrowser.firstAcceptingResponder(in: host) === host)
    }

    @Test func aLoopWithOnlyTheBrowserHasNoTarget() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [], backing: .buffered, defer: true)
        let host = KeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView!.addSubview(host)
        host.nextKeyView = host
        #expect(CefBrowser.keyView(after: host, forward: true) == nil)
    }
}

import CCef
import Foundation
import Testing

@testable import CefKit

/// Exercises ``CefMenuModel`` against a hand-built `cef_menu_model_t` whose
/// callbacks record into process-global counters. No CEF framework needed —
/// the struct is a plain C struct of function pointers we populate ourselves.
/// (C function pointers can't capture, hence the globals; the test is
/// serialized to keep them deterministic.)
@MainActor
struct MenuModelTests {
    @Test func mutationsForwardToTheNativeModel() {
        MenuModelProbe.reset()

        var model = cef_menu_model_t()
        model.clear = { _ in MenuModelProbe.clearCount += 1; return 1 }
        model.add_separator = { _ in MenuModelProbe.separatorCount += 1; return 1 }
        model.add_item = { _, commandID, _ in
            MenuModelProbe.lastAddedCommandID = Int(commandID)
            MenuModelProbe.addItemCount += 1
            return 1
        }
        model.insert_item_at = { _, index, commandID, _ in
            MenuModelProbe.lastInsertIndex = Int(index)
            MenuModelProbe.lastInsertCommandID = Int(commandID)
            return 1
        }
        model.remove = { _, commandID in
            MenuModelProbe.lastRemovedCommandID = Int(commandID)
            return 1
        }
        model.remove_at = { _, index in
            MenuModelProbe.lastRemovedIndex = Int(index)
            return 0  // simulate "not found"
        }
        model.get_count = { _ in 7 }

        withUnsafeMutablePointer(to: &model) { ptr in
            let menu = CefMenuModel(raw: ptr)

            #expect(menu.count == 7)

            menu.clear()
            #expect(MenuModelProbe.clearCount == 1)

            menu.addItem(commandID: CefMenuModel.userCommandIDFirst, title: "Custom")
            #expect(MenuModelProbe.addItemCount == 1)
            #expect(MenuModelProbe.lastAddedCommandID == CefMenuModel.userCommandIDFirst)

            menu.addSeparator()
            #expect(MenuModelProbe.separatorCount == 1)

            menu.insertItem(at: 2, commandID: 26510, title: "Mid")
            #expect(MenuModelProbe.lastInsertIndex == 2)
            #expect(MenuModelProbe.lastInsertCommandID == 26510)

            #expect(menu.remove(commandID: 26510) == true)
            #expect(MenuModelProbe.lastRemovedCommandID == 26510)

            #expect(menu.removeItem(at: 3) == false)  // get returns 0
            #expect(MenuModelProbe.lastRemovedIndex == 3)
        }
    }
}

/// Process-global recorder for the non-capturing C callbacks above.
enum MenuModelProbe {
    nonisolated(unsafe) static var clearCount = 0
    nonisolated(unsafe) static var separatorCount = 0
    nonisolated(unsafe) static var addItemCount = 0
    nonisolated(unsafe) static var lastAddedCommandID = -1
    nonisolated(unsafe) static var lastInsertIndex = -1
    nonisolated(unsafe) static var lastInsertCommandID = -1
    nonisolated(unsafe) static var lastRemovedCommandID = -1
    nonisolated(unsafe) static var lastRemovedIndex = -1

    static func reset() {
        clearCount = 0
        separatorCount = 0
        addItemCount = 0
        lastAddedCommandID = -1
        lastInsertIndex = -1
        lastInsertCommandID = -1
        lastRemovedCommandID = -1
        lastRemovedIndex = -1
    }
}

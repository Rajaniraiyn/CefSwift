import AppKit
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// How Chromium's roles and attributes appear to AppKit.
@MainActor
struct AccessibilityMappingTests {

    static func node(_ role: String, states: [String] = [], attributes: [String: CefJSON] = [:]) -> CefAccessibilityNode {
        let json: CefJSON = [
            "id": 1, "role": .string(role), "state": .array(states.map(CefJSON.string)),
            "location": ["x": 0, "y": 0, "width": 10, "height": 10], "attributes": .object(attributes),
        ]
        return CefAccessibilityNode(json: json, tree: "t")!
    }

    static func role(_ node: CefAccessibilityNode) -> (String, String?) {
        let mapped = CefAccessibilityRoleMapping.role(for: node)
        return (mapped.role.rawValue, mapped.subrole?.rawValue)
    }

    @Test func roles() {
        #expect(Self.role(Self.node("rootWebArea")) == ("AXWebArea", nil))
        #expect(Self.role(Self.node("heading")) == ("AXHeading", nil))
        #expect(Self.role(Self.node("link")) == ("AXLink", nil))
        #expect(Self.role(Self.node("button")) == ("AXButton", nil))
        #expect(Self.role(Self.node("toggleButton")) == ("AXCheckBox", "AXToggle"))
        #expect(Self.role(Self.node("checkBox")) == ("AXCheckBox", nil))
        #expect(Self.role(Self.node("switch")) == ("AXCheckBox", "AXSwitch"))
        #expect(Self.role(Self.node("radioButton")) == ("AXRadioButton", nil))
        #expect(Self.role(Self.node("textField")) == ("AXTextField", nil))
        #expect(Self.role(Self.node("textField", states: ["multiline"])) == ("AXTextArea", nil))
        #expect(Self.role(Self.node("textField", states: ["protected"])) == ("AXTextField", "AXSecureTextField"))
        #expect(Self.role(Self.node("searchBox")) == ("AXTextField", "AXSearchField"))
        #expect(Self.role(Self.node("comboBoxSelect")) == ("AXPopUpButton", nil))
        #expect(Self.role(Self.node("list")) == ("AXList", "AXContentList"))
        #expect(Self.role(Self.node("listItem")) == ("AXGroup", nil))
        #expect(Self.role(Self.node("image")) == ("AXImage", nil))
        #expect(Self.role(Self.node("table")) == ("AXTable", nil))
        #expect(Self.role(Self.node("row")) == ("AXRow", nil))
        #expect(Self.role(Self.node("cell")) == ("AXCell", nil))
        #expect(Self.role(Self.node("tab")) == ("AXRadioButton", "AXTabButton"))
        #expect(Self.role(Self.node("tabList")) == ("AXTabGroup", nil))
        #expect(Self.role(Self.node("slider")) == ("AXSlider", nil))
        #expect(Self.role(Self.node("main")) == ("AXGroup", "AXLandmarkMain"))
        #expect(Self.role(Self.node("navigation")) == ("AXGroup", "AXLandmarkNavigation"))
        #expect(Self.role(Self.node("alert")) == ("AXGroup", "AXApplicationAlert"))
        #expect(Self.role(Self.node("dialog")) == ("AXGroup", "AXApplicationDialog"))
        #expect(Self.role(Self.node("staticText")) == ("AXStaticText", nil))
        #expect(Self.role(Self.node("somethingNew")) == ("AXGroup", nil))
    }

    @Test func values() {
        func value(_ node: CefAccessibilityNode) -> Any? {
            CefAccessibilityRoleMapping.value(for: node) { "text" }
        }
        #expect(value(Self.node("checkBox", attributes: ["checkedState": "true"])) as? Int == 1)
        #expect(value(Self.node("checkBox", attributes: ["checkedState": "mixed"])) as? Int == 2)
        #expect(value(Self.node("radioButton")) as? Int == 0)
        #expect((value(Self.node("heading", attributes: ["hierarchicalLevel": 3])) as? NSNumber)?.intValue == 3)
        #expect((value(Self.node("slider", attributes: ["valueForRange": 42])) as? NSNumber)?.doubleValue == 42)
        #expect(value(Self.node("textField", attributes: ["value": "Ada"])) as? String == "Ada")
        #expect(value(Self.node("textField")) as? String == "")
        #expect(value(Self.node("staticText", attributes: ["name": "Hi"])) as? String == "Hi")
        #expect(value(Self.node("textField", states: ["richlyEditable", "editable"])) as? String == "text")
        #expect(value(Self.node("link", attributes: ["name": "x"])) == nil)
    }

    @Test func namesAndActions() {
        #expect(CefAccessibilityRoleMapping.nameIsTitle(Self.node("button", attributes: ["nameFrom": "contents"])))
        #expect(CefAccessibilityRoleMapping.nameIsTitle(Self.node("textField", attributes: ["nameFrom": "relatedElement"])))
        #expect(!CefAccessibilityRoleMapping.nameIsTitle(Self.node("image", attributes: ["nameFrom": "attribute"])))
        #expect(CefAccessibilityRoleMapping.isPressable(Self.node("button")))
        #expect(CefAccessibilityRoleMapping.isPressable(Self.node("genericContainer", attributes: ["defaultActionVerb": "click"])))
        #expect(!CefAccessibilityRoleMapping.isPressable(Self.node("genericContainer")))
        #expect(CefAccessibilityRoleMapping.isAdjustable(Self.node("slider")))
        #expect(!CefAccessibilityRoleMapping.isAdjustable(Self.node("button")))
    }
}

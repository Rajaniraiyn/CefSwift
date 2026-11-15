import AppKit

/// How Chromium's roles appear to AppKit, following Chromium's own macOS
/// mapping (`AXPlatformNodeCocoa`).
enum CefAccessibilityRoleMapping {
    /// `AXWebArea`, which AppKit has no constant for.
    static let webArea = NSAccessibility.Role(rawValue: "AXWebArea")
    /// `AXHeading`.
    static let heading = NSAccessibility.Role(rawValue: "AXHeading")
    /// `AXListMarker`.
    static let listMarker = NSAccessibility.Role(rawValue: "AXListMarker")
    /// `AXDateTimeArea`.
    static let dateTimeArea = NSAccessibility.Role(rawValue: "AXDateTimeArea")

    /// The AppKit role and subrole for a node.
    static func role(for node: CefAccessibilityNode) -> (role: NSAccessibility.Role, subrole: NSAccessibility.Subrole?) {
        switch node.role {
        case "rootWebArea", "webArea":
            return (webArea, nil)
        case "staticText", "inlineTextBox":
            return (.staticText, nil)
        case "heading":
            return (heading, nil)
        case "link":
            return (.link, nil)
        case "button":
            return node.attributes["hasPopup"] != nil && node.string("hasPopup") != "false"
                ? (.popUpButton, nil) : (.button, nil)
        case "toggleButton":
            return (.checkBox, .toggle)
        case "popUpButton", "comboBoxSelect", "comboBoxMenuButton":
            return (.popUpButton, nil)
        case "checkBox":
            return (.checkBox, nil)
        case "switch":
            return (.checkBox, .switch)
        case "radioButton":
            return (.radioButton, nil)
        case "radioGroup":
            return (.radioGroup, nil)
        case "textField":
            if node.isProtected { return (.textField, .secureTextField) }
            return node.isMultiline ? (.textArea, nil) : (.textField, nil)
        case "searchBox":
            return (.textField, .searchField)
        case "textFieldWithComboBox", "comboBoxGrouping":
            return (.comboBox, nil)
        case "image", "imageMap", "canvas", "graphicsSymbol":
            return (.image, nil)
        case "svgRoot":
            return node.childIDs.isEmpty ? (.image, nil) : (.group, nil)
        case "list":
            return (.list, .contentList)
        case "descriptionList":
            return (.list, .descriptionList)
        case "listItem":
            return (.group, nil)
        case "listMarker":
            return (listMarker, nil)
        case "listBox":
            return (.list, nil)
        case "listBoxOption":
            return (.staticText, nil)
        case "table", "grid", "treeGrid", "layoutTable":
            return (.table, nil)
        case "row", "layoutTableRow":
            return (.row, nil)
        case "column":
            return (.column, nil)
        case "cell", "gridCell", "columnHeader", "rowHeader", "layoutTableCell":
            return (.cell, nil)
        case "tree":
            return (.outline, nil)
        case "treeItem":
            return (.row, .outlineRow)
        case "tabList":
            return (.tabGroup, nil)
        case "tab":
            return (.radioButton, .init(rawValue: "AXTabButton"))
        case "tabPanel":
            return (.group, .init(rawValue: "AXTabPanel"))
        case "menu", "menuListPopup":
            return (.menu, nil)
        case "menuBar":
            return (.menuBar, nil)
        case "menuItem", "menuItemCheckBox", "menuItemRadio", "menuListOption":
            return (.menuItem, nil)
        case "slider":
            return (.slider, nil)
        case "spinButton":
            return (.incrementor, nil)
        case "progressIndicator":
            return (.progressIndicator, nil)
        case "meter":
            return (.levelIndicator, .init(rawValue: "AXMeter"))
        case "scrollBar":
            return (.scrollBar, nil)
        case "splitter":
            return (.splitter, nil)
        case "toolbar":
            return (.toolbar, nil)
        case "colorWell":
            return (.colorWell, nil)
        case "disclosureTriangle", "disclosureTriangleGrouped":
            return (.disclosureTriangle, nil)
        case "date", "dateTime", "inputTime":
            return (dateTimeArea, nil)
        case "alert":
            return (.group, .init(rawValue: "AXApplicationAlert"))
        case "alertDialog":
            return (.group, .init(rawValue: "AXApplicationAlertDialog"))
        case "dialog":
            return (.group, .init(rawValue: "AXApplicationDialog"))
        case "log":
            return (.group, .init(rawValue: "AXApplicationLog"))
        case "marquee":
            return (.group, .init(rawValue: "AXApplicationMarquee"))
        case "status":
            return (.group, .init(rawValue: "AXApplicationStatus"))
        case "timer":
            return (.group, .init(rawValue: "AXApplicationTimer"))
        case "application":
            return (.group, .init(rawValue: "AXLandmarkApplication"))
        case "banner", "header":
            return (.group, .init(rawValue: "AXLandmarkBanner"))
        case "complementary":
            return (.group, .init(rawValue: "AXLandmarkComplementary"))
        case "contentInfo", "footer":
            return (.group, .init(rawValue: "AXLandmarkContentInfo"))
        case "main":
            return (.group, .init(rawValue: "AXLandmarkMain"))
        case "navigation":
            return (.group, .init(rawValue: "AXLandmarkNavigation"))
        case "search":
            return (.group, .init(rawValue: "AXLandmarkSearch"))
        case "region":
            return (.group, .init(rawValue: "AXLandmarkRegion"))
        case "form":
            return (.group, node.name != nil ? .init(rawValue: "AXLandmarkForm") : nil)
        case "article":
            return (.group, .init(rawValue: "AXDocumentArticle"))
        case "document":
            return (.group, .init(rawValue: "AXDocument"))
        case "note":
            return (.group, .init(rawValue: "AXDocumentNote"))
        case "math", "mathMLMath":
            return (.group, .init(rawValue: "AXDocumentMath"))
        case "definition":
            return (.group, .init(rawValue: "AXDefinition"))
        case "term":
            return (.group, .init(rawValue: "AXTerm"))
        case "code":
            return (.group, .init(rawValue: "AXCodeStyleGroup"))
        case "tooltip":
            return (.group, .init(rawValue: "AXUserInterfaceTooltip"))
        case "lineBreak":
            return (.group, nil)
        default:
            return (.group, nil)
        }
    }

    /// Whether the node's accessible name is its title (text it shows) rather
    /// than a label (text that describes it).
    static func nameIsTitle(_ node: CefAccessibilityNode) -> Bool {
        switch node.nameFrom {
        case "contents", "relatedElement", "caption":
            return true
        default:
            return false
        }
    }

    /// Roles whose value is their checked state.
    private static let checkableRoles: Set<String> = [
        "checkBox", "radioButton", "switch", "toggleButton", "menuItemCheckBox", "menuItemRadio",
    ]
    /// Roles whose value is a number in a range.
    private static let rangeRoles: Set<String> = ["slider", "spinButton", "progressIndicator", "meter", "scrollBar"]
    /// Roles whose value is the text they hold.
    private static let textRoles: Set<String> = ["textField", "searchBox", "textFieldWithComboBox", "comboBoxGrouping"]

    /// Whether the node holds editable or selectable text with a value.
    static func isTextRole(_ node: CefAccessibilityNode) -> Bool {
        textRoles.contains(node.role) || node.isRichlyEditable && node.isEditable
    }

    /// The node's `AXValue`, as Chromium exposes it on macOS.
    static func value(for node: CefAccessibilityNode, text: () -> String) -> Any? {
        if checkableRoles.contains(node.role) {
            switch node.checkedState {
            case .checked: return 1
            case .mixed: return 2
            default: return 0
            }
        }
        if rangeRoles.contains(node.role) { return node.rangeValue.map { NSNumber(value: $0) } }
        switch node.role {
        case "heading":
            return node.hierarchicalLevel.map { NSNumber(value: $0) }
        case "staticText", "listMarker", "listBoxOption", "inlineTextBox":
            return node.name ?? ""
        case "tab":
            return NSNumber(value: node.isSelected == true ? 1 : 0)
        case "disclosureTriangle", "disclosureTriangleGrouped":
            return NSNumber(value: node.isExpanded == true ? 1 : 0)
        case "popUpButton", "comboBoxSelect", "comboBoxMenuButton":
            return node.value ?? node.name ?? ""
        default:
            break
        }
        if isTextRole(node) { return node.value ?? (node.isRichlyEditable ? text() : "") }
        return node.value
    }

    /// Whether pressing the node does something.
    static func isPressable(_ node: CefAccessibilityNode) -> Bool {
        if let verb = node.string("defaultActionVerb"), verb != "none" { return true }
        switch node.role {
        case "button", "toggleButton", "link", "checkBox", "radioButton", "switch", "tab", "menuItem",
             "menuItemCheckBox", "menuItemRadio", "menuListOption", "listBoxOption", "popUpButton",
             "comboBoxSelect", "comboBoxMenuButton", "disclosureTriangle", "disclosureTriangleGrouped", "treeItem":
            return true
        default:
            return false
        }
    }

    /// Whether the node steps up and down.
    static func isAdjustable(_ node: CefAccessibilityNode) -> Bool {
        node.role == "slider" || node.role == "spinButton"
    }
}

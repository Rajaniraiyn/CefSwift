import CCef
import CefBase
import Foundation

extension CefContextMenu {
    /// Reads a borrowed `cef_menu_model_t`, submenus included. Hidden items
    /// are left out.
    init(model: UnsafeMutablePointer<cef_menu_model_t>, isChromeStyle: Bool) {
        var items: [Item] = []
        for index in 0..<model.pointee.get_count(model) {
            guard model.pointee.is_visible_at(model, index) != 0 else { continue }
            let type = model.pointee.get_type_at(model, index)
            if type == MENUITEMTYPE_SEPARATOR {
                items.append(.separator)
                continue
            }
            var submenu: CefContextMenu?
            if type == MENUITEMTYPE_SUBMENU, let sub = model.pointee.get_sub_menu_at(model, index) {
                submenu = CefContextMenu(model: sub, isChromeStyle: isChromeStyle)
                cefRelease(sub)
            }
            items.append(Item(
                chromiumID: Int(model.pointee.get_command_id_at(model, index)),
                title: Self.title(fromChromiumLabel: CefStringUtil.takingUserFree(model.pointee.get_label_at(model, index)) ?? ""),
                submenu: submenu ?? (type == MENUITEMTYPE_SUBMENU ? CefContextMenu() : nil),
                isEnabled: model.pointee.is_enabled_at(model, index) != 0,
                isChecked: (type == MENUITEMTYPE_CHECK || type == MENUITEMTYPE_RADIO)
                    && model.pointee.is_checked_at(model, index) != 0,
                kind: Self.kindName(type),
                group: type == MENUITEMTYPE_RADIO ? Int(model.pointee.get_group_id_at(model, index)) : nil,
                isChromeStyle: isChromeStyle))
        }
        self.init(items)
    }

    static func kindName(_ type: cef_menu_item_type_t) -> String {
        switch type {
        case MENUITEMTYPE_CHECK: "check"
        case MENUITEMTYPE_RADIO: "radio"
        case MENUITEMTYPE_SUBMENU: "submenu"
        default: "command"
        }
    }

    /// A label without Chromium's mnemonic markers: `&` marks a mnemonic
    /// and `&&` is a literal ampersand.
    static func title(fromChromiumLabel label: String) -> String {
        label.components(separatedBy: "&&")
            .map { $0.replacingOccurrences(of: "&", with: "") }
            .joined(separator: "&")
    }
}

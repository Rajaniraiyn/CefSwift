import CefKit
import Foundation

extension Bundle {
    /// CefPasskeys' resources: the strings of its passkey sheet.
    static let cefPasskeys = Bundle.cefSwiftResources("CefSwift_CefPasskeys", module: .module)
}

extension CefPasskeyPresenter {
    /// CefPasskeys' resource bundle, for tests.
    @_spi(Testing) public nonisolated static var resourceBundle: Bundle { .cefPasskeys }
}

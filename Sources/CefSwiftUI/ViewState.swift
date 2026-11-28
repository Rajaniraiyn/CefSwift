import SwiftUI

/// `SwiftUI.State` under a name of its own. The Command Line Tools' macOS 27
/// SDK declares a `State` macro beside the property wrapper, and `@State`
/// resolves to the macro, whose plugin (`SwiftUIMacros`) only Xcode ships:
/// without Xcode, `@State` does not compile. Through this alias the
/// attribute names the property wrapper itself, the same type at run time.
/// Remove it, and write `@State` again, once the tools ship the plugin.
typealias ViewState = SwiftUI.State

/// An object that holds CEF references outside any browser, such as a
/// registration or a hidden service host, and must release them before
/// Chromium shuts down: nothing CEF made may outlive `cef_shutdown()`.
///
/// Add one with ``CefRuntime/addShutdownParticipant(_:)``; the runtime
/// holds it weakly. When the app quits, once every browser and window has
/// gone, the runtime calls each participant still alive, in the order they
/// were added, then releases the profiles' request contexts and shuts
/// Chromium down. A participant is called once.
@MainActor
protocol CefShutdownParticipant: AnyObject {
    /// Release every CEF reference held, and stop anything that would
    /// make new ones.
    func runtimeWillShutDown()
}

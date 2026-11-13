import CCef
import Foundation
import Observation
import CefBase

/// A device content can be cast to: a Cast receiver or a DIAL device.
public struct CefMediaSink: Identifiable, Hashable, Sendable {
    /// What protocol the device speaks.
    public enum Kind: Sendable, Hashable {
        case cast
        case dial
        case unknown
    }

    public let id: String
    /// The device's name, as its owner set it.
    public let name: String
    public let kind: Kind
}

/// A connection from a source to a ``CefMediaSink``.
public struct CefMediaRoute: Identifiable, Hashable, Sendable {
    /// Where the route is in its lifetime.
    public enum State: Sendable, Hashable {
        case connecting, connected, closed, terminated, unknown
    }

    public let id: String
    /// The sink's ``CefMediaSink/id``.
    public let sinkID: String
    /// The source's URN, as passed to ``CefMediaRouter/cast(_:to:)``.
    public let source: String
    public internal(set) var state: State
}

/// A failure to start a route.
public struct CefMediaRouteError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Chromium's media router: the Cast and DIAL devices on the network, and
/// the routes to them. For a cast picker of your own in place of
/// Chromium's (``CefChromiumSurface/Kind/cast``).
///
/// ```swift
/// let router = CefMediaRouter.shared
/// router.startDiscovery()
/// // router.sinks fills in as devices are found.
/// let route = try await router.cast("cast:CC1AD845", to: router.sinks[0])
/// ```
///
/// Sources are Cast application URNs (`cast:<app ID>?clientId=<ID>`) and
/// presentation URLs (`https://…`), as the Presentation API uses. Mirroring
/// a tab or the screen is not among them: CEF's media router does not
/// offer it, so Chromium's own Cast dialog stays the way to mirror a tab.
@MainActor
@Observable
public final class CefMediaRouter {
    /// The router for every profile.
    public static let shared = CefMediaRouter()

    /// The devices found, in the order Chromium reports them. Empty until
    /// ``startDiscovery()``.
    public private(set) var sinks: [CefMediaSink] = []
    /// The routes in use.
    public private(set) var routes: [CefMediaRoute] = []
    /// Whether discovery is running.
    public private(set) var isDiscovering = false

    @ObservationIgnored private var router: CefRef<cef_media_router_t>?
    @ObservationIgnored private var registration: CefRef<cef_registration_t>?
    @ObservationIgnored private var sinkObjects: [String: CefRef<cef_media_sink_t>] = [:]
    @ObservationIgnored private var routeObjects: [String: CefRef<cef_media_route_t>] = [:]

    private init() {}

    /// Whether Chromium's media router runs: not when the `MediaRouter`
    /// feature is turned off, as ``CefRuntime/Configuration/embedded`` does.
    public var isAvailable: Bool {
        guard let configuration = CefRuntime.shared.configuration, CefRuntime.shared.isRunning else { return false }
        return !configuration.disabledFeatures.contains("MediaRouter")
    }

    /// Starts looking for devices; ``sinks`` and ``routes`` follow from
    /// then on. Does nothing when the router is not ``isAvailable``.
    public func startDiscovery() {
        guard !isDiscovering, isAvailable,
              let router = router ?? CefRef(adopting: cef_media_router_get_global(nil))
        else { return }
        self.router = router
        isDiscovering = true
        // add_observer takes over the observer reference.
        let observer = MediaObserver(router: self).makeObserver()
        registration = CefRef(adopting: router.pointer.pointee.add_observer(router.pointer, observer))
        router.pointer.pointee.notify_current_sinks(router.pointer)
        router.pointer.pointee.notify_current_routes(router.pointer)
    }

    /// Stops looking for devices.
    public func stopDiscovery() {
        registration = nil
        isDiscovering = false
    }

    /// Releases every Chromium object, before Chromium shuts down.
    func tearDown() {
        stopDiscovery()
        sinkObjects = [:]
        routeObjects = [:]
        router = nil
    }

    /// Whether `sink` can show `source`.
    public func canCast(_ source: String, to sink: CefMediaSink) -> Bool {
        guard let router, let sinkObject = sinkObjects[sink.id],
              let sourceObject = mediaSource(source, router: router)
        else { return false }
        // is_compatible_with takes a reference to the source.
        return sinkObject.pointer.pointee.is_compatible_with(sinkObject.pointer, sourceObject.retainedPointer()) != 0
    }

    /// Connects `source` to `sink`.
    public func cast(_ source: String, to sink: CefMediaSink) async throws -> CefMediaRoute {
        guard let router, let sinkObject = sinkObjects[sink.id],
              let sourceObject = mediaSource(source, router: router)
        else { throw CefMediaRouteError(message: "No such device or source") }
        let (result, error, route) = await withCheckedContinuation { continuation in
            let callback = RouteCreated(continuation).makeCallback()
            router.pointer.pointee.create_route(router.pointer, sourceObject.retainedPointer(), sinkObject.retainedPointer(), callback)
        }
        guard let route, result == CEF_MRCR_OK else {
            throw CefMediaRouteError(message: error.isEmpty ? "Casting failed" : error)
        }
        let value = Self.describe(route.pointer, source: source)
        routeObjects[value.id] = route
        return value
    }

    /// Ends `route`.
    public func stop(_ route: CefMediaRoute) {
        guard let object = routeObjects[route.id] else { return }
        object.pointer.pointee.terminate(object.pointer)
    }

    private func mediaSource(_ urn: String, router: CefRef<cef_media_router_t>) -> CefRef<cef_media_source_t>? {
        CefStringUtil.withCefString(urn) { CefRef(adopting: router.pointer.pointee.get_source(router.pointer, $0)) }
    }

    // MARK: Observer

    fileprivate func update(sinks objects: [CefRef<cef_media_sink_t>]) {
        sinkObjects = [:]
        sinks = objects.map { object in
            let pointer = object.pointer
            let id = CefStringUtil.takingUserFree(pointer.pointee.get_id(pointer)) ?? ""
            let kind: CefMediaSink.Kind = pointer.pointee.is_cast_sink(pointer) != 0
                ? .cast : pointer.pointee.is_dial_sink(pointer) != 0 ? .dial : .unknown
            sinkObjects[id] = object
            return CefMediaSink(id: id, name: CefStringUtil.takingUserFree(pointer.pointee.get_name(pointer)) ?? "", kind: kind)
        }
    }

    fileprivate func update(routes objects: [CefRef<cef_media_route_t>]) {
        routeObjects = [:]
        routes = objects.map { object in
            let route = Self.describe(object.pointer, source: nil)
            routeObjects[route.id] = object
            return routes.first { $0.id == route.id }.map { var known = route; known.state = $0.state; return known } ?? route
        }
    }

    fileprivate func update(route id: String, state: CefMediaRoute.State) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].state = state
    }

    fileprivate static func describe(_ route: UnsafeMutablePointer<cef_media_route_t>, source: String?) -> CefMediaRoute {
        let id = CefStringUtil.takingUserFree(route.pointee.get_id(route)) ?? ""
        let sink = CefRef(adopting: route.pointee.get_sink(route))
        let sinkID = sink.flatMap { CefStringUtil.takingUserFree($0.pointer.pointee.get_id($0.pointer)) } ?? ""
        let sourceObject = CefRef(adopting: route.pointee.get_source(route))
        let urn = source ?? sourceObject.flatMap { CefStringUtil.takingUserFree($0.pointer.pointee.get_id($0.pointer)) } ?? ""
        return CefMediaRoute(id: id, sinkID: sinkID, source: urn, state: .connecting)
    }
}

/// Owner of a `cef_media_observer_t`. Callbacks arrive on the UI thread.
private final class MediaObserver: Sendable {
    private weak let router: CefMediaRouter?

    @MainActor
    init(router: CefMediaRouter) {
        self.router = router
    }

    func makeObserver() -> UnsafeMutablePointer<cef_media_observer_t> {
        let o = cefAllocate(cef_media_observer_t.self, owner: self)
        o.pointee.on_sinks = { s, count, sinks in
            let objects = (0..<count).compactMap { CefRef(adopting: sinks?[$0]) }
            guard let owner = cefOwner(MediaObserver.self, s) else { return }
            MainActor.assumeIsolated { owner.router?.update(sinks: objects) }
        }
        o.pointee.on_routes = { s, count, routes in
            let objects = (0..<count).compactMap { CefRef(adopting: routes?[$0]) }
            guard let owner = cefOwner(MediaObserver.self, s) else { return }
            MainActor.assumeIsolated { owner.router?.update(routes: objects) }
        }
        o.pointee.on_route_state_changed = { s, route, state in
            let id = route.flatMap { CefStringUtil.takingUserFree($0.pointee.get_id($0)) } ?? ""
            cefRelease(route)
            let value: CefMediaRoute.State = switch state {
            case CEF_MRCS_CONNECTING: .connecting
            case CEF_MRCS_CONNECTED: .connected
            case CEF_MRCS_CLOSED: .closed
            case CEF_MRCS_TERMINATED: .terminated
            default: .unknown
            }
            guard let owner = cefOwner(MediaObserver.self, s) else { return }
            MainActor.assumeIsolated { owner.router?.update(route: id, state: value) }
        }
        o.pointee.on_route_message_received = { _, route, _, _ in
            cefRelease(route)
        }
        return o
    }
}

/// Owner of a `cef_media_route_create_callback_t`, which resumes with
/// `CEF_MRCR_UNKNOWN_ERROR` if CEF drops the callback without calling it.
private final class RouteCreated: Sendable {
    typealias Outcome = (cef_media_route_create_result_t, String, CefRef<cef_media_route_t>?)
    private let continuation: CefResumeOnce<Outcome>

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = CefResumeOnce(continuation, fallback: (CEF_MRCR_UNKNOWN_ERROR, "", nil))
    }

    func makeCallback() -> UnsafeMutablePointer<cef_media_route_create_callback_t> {
        let c = cefAllocate(cef_media_route_create_callback_t.self, owner: self)
        c.pointee.on_media_route_create_finished = { s, result, error, route in
            let outcome = (result, CefStringUtil.string(from: error), CefRef(adopting: route))
            cefOwner(RouteCreated.self, s)?.continuation.resume(returning: outcome)
        }
        return c
    }
}

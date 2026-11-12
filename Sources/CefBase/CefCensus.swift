import os

/// Counts of live objects that hold CEF references or other resources,
/// for leak checks: SelfTest compares them with a baseline after each
/// group of checks and before shutdown.
///
/// Off unless enabled; when off, each count costs one atomic load. The
/// helper process never enables it.
package enum CefCensus {
    /// What is counted.
    package enum Kind: Hashable, Sendable {
        /// A `CefRef` holding a reference to a CEF object of this type.
        case reference(String)
        /// A CEF struct CefSwift implements (handler, client, callback),
        /// by the type of its Swift owner.
        case implemented(String)
        /// A received page-scripting payload.
        case wirePayload
        /// A shared memory mapping a payload holds.
        case sharedMemoryMapping
        /// Something CefKit tracks itself (pending operations, bridges).
        case custom(String)
    }

    private static let counts = OSAllocatedUnfairLock(initialState: [Kind: Int]())
    // A cached copy of `enabled`, read without the lock on every count.
    // Written only by `setEnabled`, before the objects it counts exist.
    nonisolated(unsafe) private static var isOn = false

    package static var isEnabled: Bool { isOn }

    /// Turns counting on or off; turn it on before creating CEF objects.
    package static func setEnabled(_ value: Bool) {
        isOn = value
    }

    @inline(__always)
    package static func add(_ kind: @autoclosure () -> Kind, _ delta: Int) {
        guard isOn, delta != 0 else { return }
        let kind = kind()
        counts.withLock { $0[kind, default: 0] += delta }
    }

    /// The live counts that are not zero.
    package static func snapshot() -> [Kind: Int] {
        counts.withLock { $0.filter { $0.value != 0 } }
    }
}

extension CefCensus.Kind: CustomStringConvertible {
    package var description: String {
        switch self {
        case .reference(let type): "CefRef<\(type)>"
        case .implemented(let type): "implemented \(type)"
        case .wirePayload: "wire payload"
        case .sharedMemoryMapping: "shared memory mapping"
        case .custom(let name): name
        }
    }
}

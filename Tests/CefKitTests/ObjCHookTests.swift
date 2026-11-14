import Foundation
import ObjectiveC
import Testing

@testable import CefKit

@objc(CefHookTestWidget)
final class HookTestWidget: NSObject {
    @objc dynamic func width() -> Int { 1 }
    @objc dynamic func height() -> Int { 2 }
    @objc dynamic func area() -> Int { 3 }
    @objc dynamic func resize(_ factor: Double) {}
}

/// Hooks go in a feature at a time, all or nothing.
@MainActor
struct ObjCHookTests {
    private typealias IntGetter = @convention(c) (NSObject, Selector) -> Int

    @Test func aFeatureMissingOneMethodInstallsNothing() {
        let width: @convention(block) (NSObject) -> Int = { _ in 10 }
        let installed = CefObjCHook.installFeature("test partial", overrides: [
            .init(method: .init("CefHookTestWidget", #selector(HookTestWidget.width), types: "q@:"), block: width) { _ in },
            .init(method: .init("CefHookTestWidget", NSSelectorFromString("depth"), types: "q@:"), block: width) { _ in },
        ])
        #expect(!installed)
        #expect(!CefObjCHook.isInstalled("test partial"))
        #expect(HookTestWidget().width() == 1)
        #expect(CefObjCHook.features.first { $0.name == "test partial" }?.missing == ["CefHookTestWidget -depth"])
    }

    @Test func aRequirementWithTheWrongSignatureInstallsNothing() {
        let area: @convention(block) (NSObject) -> Int = { _ in 30 }
        // `resize:` takes a double (`v@:d`), not an object.
        let installed = CefObjCHook.installFeature(
            "test signature",
            requires: [.init("CefHookTestWidget", #selector(HookTestWidget.resize(_:)), types: "v@:@")],
            overrides: [
                .init(method: .init("CefHookTestWidget", #selector(HookTestWidget.area), types: "q@:"), block: area) { _ in },
            ])
        #expect(!installed)
        #expect(HookTestWidget().area() == 3)
    }

    @Test func aCompleteFeatureInstallsEveryOverrideOnce() {
        var original: IntGetter?
        let height: @convention(block) (NSObject) -> Int = { widget in
            (original?(widget, #selector(HookTestWidget.height)) ?? 0) + 100
        }
        let feature = { () -> Bool in
            CefObjCHook.installFeature(
                "test complete",
                requires: [.init("CefHookTestWidget", #selector(HookTestWidget.resize(_:)), types: "v@:d")],
                overrides: [
                    .init(method: .init("CefHookTestWidget", #selector(HookTestWidget.height), types: "q@:"), block: height) {
                        original = unsafeBitCast($0, to: IntGetter.self)
                    },
                ])
        }
        #expect(feature())
        #expect(feature())
        #expect(CefObjCHook.isInstalled("test complete"))
        #expect(HookTestWidget().height() == 102)
    }

    @Test func offsetsAreIgnored() {
        #expect(CefObjCHook.stripOffsets("v32@0:8@16q24") == "v@:@q")
    }
}

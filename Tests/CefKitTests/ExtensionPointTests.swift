import Testing

@testable import CefKit

/// The points optional modules and apps extend CefKit at.
@MainActor
struct ExtensionPointTests {
    final class Attachment: CefPageAttachment {
        let preparesBeforeFirstDocument: Bool
        init(preparesFirst: Bool) { preparesBeforeFirstDocument = preparesFirst }
    }

    final class PlainAttachment: CefPageAttachment {}

    @Test func anAttachmentThatPreparesFirstHoldsTheFirstDocument() {
        #expect(!PlainAttachment().preparesBeforeFirstDocument)
        var configuration = CefPage.Configuration()
        #expect(!CefPage(configuration: configuration).attachmentsPrepareBeforeFirstDocument)
        configuration.attachments = [PlainAttachment()]
        #expect(!CefPage(configuration: configuration).attachmentsPrepareBeforeFirstDocument)
        configuration.attachments.append(Attachment(preparesFirst: true))
        #expect(CefPage(configuration: configuration).attachmentsPrepareBeforeFirstDocument)
    }

    final class State {
        var count = 0
    }

    @Test func moduleStateIsOnePerTypeAndProfile() {
        let profile = CefProfile.incognito()
        var made = 0
        let first = profile.moduleState(State.self) { made += 1; return State() }
        first.count = 3
        let again = profile.moduleState(State.self) { made += 1; return State() }
        #expect(first === again && again.count == 3 && made == 1)
        let other = CefProfile.incognito().moduleState(State.self) { State() }
        #expect(other !== first)
    }
}

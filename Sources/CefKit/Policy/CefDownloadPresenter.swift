import AppKit
import UniformTypeIdentifiers

/// The save panel behind ``CefDownloadDecision/ask``: an `NSSavePanel`
/// named for the download's suggested file and its type. Call it from your
/// own delegate to keep the stock panel for some downloads, or answer
/// ``CefBrowserDelegate/browser(_:decideDestinationFor:)`` with
/// ``CefDownloadDecision/save(to:)`` after showing your own.
@MainActor
public enum CefDownloadPresenter {
    /// Shows a save panel for `download`, as a sheet on `window` when it
    /// is visible, and returns the chosen file, or `nil` when the user
    /// cancels. Cancelling the calling task closes the panel as Cancel.
    public static func present(_ download: CefDownload, in window: NSWindow?) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let panel = makePanel(suggestedFilename: download.suggestedFilename, mimeType: download.mimeType)
        let response = await withTaskCancellationHandler {
            if let window, window.isVisible {
                return await panel.beginSheetModal(for: window)
            }
            return panel.runModal()
        } onCancel: {
            CefDialogPresenter.dismissOnMain { panel.cancel(nil) }
        }
        guard response == .OK else { return nil }
        return panel.url
    }

    /// The panel for a file suggested as `suggestedFilename` of type
    /// `mimeType`: it proposes that name and type, and lets the user pick
    /// another.
    static func makePanel(suggestedFilename: String, mimeType: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CefDownloadDestination.safeFilename(suggestedFilename)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = contentType(suggestedFilename: suggestedFilename, mimeType: mimeType) {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = true
        }
        return panel
    }

    /// The type the panel proposes: the suggested name's extension first,
    /// as the file is saved under it, then the MIME type. `nil` for a type
    /// the system does not know or one that says nothing (raw data).
    static func contentType(suggestedFilename: String, mimeType: String) -> UTType? {
        let ext = (suggestedFilename as NSString).pathExtension
        let candidates = [
            ext.isEmpty ? nil : UTType(filenameExtension: ext),
            mimeType.isEmpty ? nil : UTType(mimeType: mimeType),
        ]
        return candidates.lazy.compactMap { $0 }.first { !$0.isDynamic && $0 != .data && $0 != .item }
    }
}

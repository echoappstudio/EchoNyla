import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

extension View {
    /// Quick Look for a file shown in EchoNyla: click for the full preview (or press Space while the
    /// pointer is on it), double-click to open it, and rest the pointer on it for a larger picture.
    func filePreview(_ url: URL) -> some View {
        modifier(FilePreviewModifier(url: url))
    }
}

struct FilePreviewModifier: ViewModifier {
    let url: URL
    @State private var quickLook: URL?
    @State private var peek: NSImage?
    @State private var peeking = false
    @State private var waiting: Task<Void, Never>?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                closePeek()
                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            }
            .onTapGesture { showQuickLook() }
            .onHover { inside in
                if inside { pointerArrived() } else { pointerLeft() }
            }
            .onDisappear { pointerLeft() }
            .popover(isPresented: $peeking, arrowEdge: .trailing) {
                if let peek {
                    Image(nsImage: peek)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: FilePeekImages.side, maxHeight: FilePeekImages.side)
                        .padding(8)
                }
            }
            .quickLookPreview($quickLook)
    }

    private func showQuickLook() {
        closePeek()
        if FileManager.default.fileExists(atPath: url.path) { quickLook = url } else { NSSound.beep() }
    }

    /// After a short rest, so moving the pointer down a list doesn't flash a picture for every file.
    private func pointerArrived() {
        FilePreviewKeys.shared.hovering(token) { showQuickLook() }
        waiting?.cancel()
        waiting = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let image = await FilePeekImages.image(for: url), !Task.isCancelled else { return }
            peek = image
            peeking = true
        }
    }

    private func pointerLeft() {
        FilePreviewKeys.shared.left(token)
        closePeek()
    }

    private func closePeek() {
        waiting?.cancel()
        waiting = nil
        peeking = false
    }
}

/// Space opens Quick Look for the file under the pointer, as in Finder (unless you're typing).
@MainActor
final class FilePreviewKeys {
    static let shared = FilePreviewKeys()
    private var hovered: (token: UUID, open: () -> Void)?
    private var monitor: Any?

    func hovering(_ token: UUID, open: @escaping () -> Void) {
        hovered = (token, open)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isSpace = event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard isSpace else { return event }
            let opened = MainActor.assumeIsolated { FilePreviewKeys.shared.openHovered() }
            return opened ? nil : event
        }
    }

    func left(_ token: UUID) {
        if hovered?.token == token { hovered = nil }
    }

    /// Opens Quick Look for the file under the pointer; false when there's none or you're typing.
    private func openHovered() -> Bool {
        guard let hovered, !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        hovered.open()
        return true
    }
}

/// Larger pictures of files for the hover preview, from Quick Look, kept while EchoNyla runs.
@MainActor
enum FilePeekImages {
    static let side: CGFloat = 340
    private static var cache: [String: NSImage] = [:]

    /// Nil for files Quick Look can't draw (their icon already says what they are).
    static func image(for url: URL) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        if let cached = cache[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let picture = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = picture.nsImage
        return picture.nsImage
    }
}

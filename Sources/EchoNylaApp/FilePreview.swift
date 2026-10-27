import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

extension View {
    /// Quick Look for a file shown in EchoNyla, on its whole row: one click previews it right away
    /// (as does Space while the pointer is on it), a double-click opens it in its app, and resting
    /// the pointer shows a larger picture. Controls in the row (checkboxes, menus, buttons) keep
    /// working as before. `highlights` lights the row under the pointer (off for rows that already do).
    func filePreview(_ url: URL, highlights: Bool = true) -> some View {
        modifier(FilePreviewModifier(url: url, highlights: highlights))
    }
}

struct FilePreviewModifier: ViewModifier {
    let url: URL
    let highlights: Bool
    /// How long the pointer rests before the larger picture shows. The picture is made from the
    /// moment the pointer arrives, so it's usually ready by then.
    static let restBeforePeek: Duration = .milliseconds(300)

    @State private var quickLook: URL?
    @State private var peek: NSImage?
    @State private var peeking = false
    @State private var waiting: Task<Void, Never>?
    @State private var token = UUID()
    @State private var hovering = false
    @State private var width: CGFloat = 1
    @State private var pointerX: CGFloat = 0
    /// Where along the row the picture points (where the pointer was when it showed).
    @State private var peekX: CGFloat = 0.5

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if highlights {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                        .padding(-2)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            // One tap gesture, not a single and a double one: SwiftUI would hold every single click
            // back to see whether a second follows. The click count tells them apart.
            .onTapGesture { clicked() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointerX = location.x
                    if !hovering { pointerArrived() }
                case .ended:
                    pointerLeft()
                }
            }
            .onDisappear { pointerLeft() }
            .popover(isPresented: $peeking, attachmentAnchor: .point(UnitPoint(x: peekX, y: 0)), arrowEdge: .top) {
                if let peek {
                    Image(nsImage: peek)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: FilePeekImages.side, maxHeight: FilePeekImages.side)
                        .padding(8)
                }
            }
            .quickLookPreview($quickLook)
            .help("Click to preview · Double-click to open")
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The first click previews at once; the second click of a double-click closes the preview and opens the file.
    private func clicked() {
        closePeek()
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            quickLook = nil
            NSWorkspace.shared.open(url)
        } else {
            quickLook = url
        }
    }

    private func showQuickLook() {
        closePeek()
        if FileManager.default.fileExists(atPath: url.path) { quickLook = url } else { NSSound.beep() }
    }

    /// The picture is made straight away and shown after a short rest, so moving the pointer down
    /// a list doesn't flash one for every file.
    private func pointerArrived() {
        hovering = true
        FilePreviewKeys.shared.hovering(token) { showQuickLook() }
        waiting?.cancel()
        let url = url
        waiting = Task { @MainActor in
            async let picture = FilePeekImages.image(for: url)
            try? await Task.sleep(for: Self.restBeforePeek)
            guard !Task.isCancelled, let image = await picture, !Task.isCancelled, quickLook == nil else { return }
            peek = image
            peekX = min(max(pointerX / width, 0.05), 0.95)
            peeking = true
        }
    }

    private func pointerLeft() {
        hovering = false
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

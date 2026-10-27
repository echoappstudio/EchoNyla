import AppKit
import EchoNylaCore
import EchoNylaEngine
import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import Vision

/// A file's facts and, for Bonsai, its picture (only when its words don't say enough), read before asking the model.
struct PreparedFile: Sendable {
    let facts: FileFacts
    let picture: RGBImage?
    let captured: Date?

    static func read(_ url: URL, readContents: Bool, withPicture: Bool) async -> PreparedFile {
        let facts = await FileInspector.facts(for: url, readContents: readContents)
        let picture = withPicture && PictureNeed.wanted(facts) ? await FileInspector.picture(for: url, readContents: readContents) : nil
        return PreparedFile(facts: facts, picture: picture, captured: FileInspector.creationDate(of: url))
    }
}

/// Reads files one step ahead: while the model works on one file, the next one's text and
/// picture are already being read.
@MainActor
final class FilePreparer {
    private let readContents: Bool
    private let withPicture: Bool
    private var ahead: (url: URL, task: Task<PreparedFile, Never>)?

    init(readContents: Bool, withPicture: Bool) {
        self.readContents = readContents
        self.withPicture = withPicture
    }

    /// `url`, read (or waited for, if it was read ahead), and starts reading `next`.
    func prepare(_ url: URL, next: URL?) async -> PreparedFile {
        let current: Task<PreparedFile, Never>
        if let ahead, ahead.url == url { current = ahead.task } else { current = start(url) }
        ahead = next.map { ($0, start($0)) }
        return await current.value
    }

    private func start(_ url: URL) -> Task<PreparedFile, Never> {
        let readContents = readContents
        let withPicture = withPicture
        return Task.detached(priority: .userInitiated) {
            await PreparedFile.read(url, readContents: readContents, withPicture: withPicture)
        }
    }
}

/// Gathers facts about a file, entirely on this Mac. Reading inside files (PDF text, documents,
/// text and objects in images) only happens when "Look inside files" is on in Settings.
enum FileInspector {
    static let textLimit = 4_000
    static let maxBytesToRead: Int64 = 60 * 1024 * 1024

    static func facts(for url: URL, readContents: Bool) async -> FileFacts {
        await Task.detached(priority: .utility) {
            gather(url, readContents: readContents)
        }.value
    }

    private static func gather(_ url: URL, readContents: Bool) -> FileFacts {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var facts = FileFacts(fileName: url.lastPathComponent,
                              byteCount: values?.fileSize.map { Int64($0) },
                              modified: values?.contentModificationDate,
                              isScreenshot: ScreenshotMetadata.isScreenCapture(at: url),
                              downloadedFrom: DownloadSource.hosts(at: url))
        // A zip's table of contents is at its end, so even a big one is quick to read.
        if readContents, facts.fileExtension == "zip", let size = facts.byteCount, let names = zipNames(url, size: size) {
            facts.text = ZipListing.summary(names)
            return facts
        }
        guard readContents, (facts.byteCount ?? 0) <= maxBytesToRead else { return facts }
        switch facts.kind {
        case .pdf:
            if let document = PDFDocument(url: url) {
                facts.pageCount = document.pageCount
                var text = ""
                for index in 0..<min(document.pageCount, 3) {
                    text += (document.page(at: index)?.string ?? "") + "\n"
                    if text.count > textLimit { break }
                }
                facts.text = String(text.prefix(textLimit))
                if facts.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let image = firstPageImage(document) {
                    facts.text = recognizedText(in: image)       // a scanned PDF
                }
            }
        case .document:
            if let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string {
                facts.text = String(text.prefix(textLimit))
            }
        case .text, .code, .spreadsheet:
            if let handle = try? FileHandle(forReadingFrom: url) {
                let data = (try? handle.read(upToCount: 16_384)) ?? Data()
                try? handle.close()
                facts.text = String(String(decoding: data, as: UTF8.self).prefix(textLimit))
            }
        case .image:
            if let image = NSImage(contentsOf: url), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                facts.text = String(recognizedText(in: cgImage).prefix(textLimit))
                facts.imageLabels = imageLabels(in: cgImage)
            }
        default:
            break
        }
        return facts
    }

    /// The names of the files in a zip, read from the end of the file. Nothing is unpacked.
    static func zipNames(_ url: URL, size: Int64) -> [String]? {
        guard size >= 22, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = min(size, Int64(ZipListing.tailBytes))
        guard (try? handle.seek(toOffset: UInt64(size - length))) != nil,
              let data = try? handle.read(upToCount: Int(length)) else { return nil }
        return ZipListing.names(tail: data, fileSize: size)
    }

    static func firstPageImage(_ document: PDFDocument) -> CGImage? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2.0, 1_600 / max(bounds.width, 1))
        let thumbnail = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A picture of the file for the on-device model: the image itself, a PDF's first page, or
    /// macOS's Quick Look preview of a document, presentation, spreadsheet or video. Nil for text
    /// and code (their words are already read) and when "Look inside files" is off.
    static func picture(for url: URL, readContents: Bool) async -> RGBImage? {
        guard readContents else { return nil }
        let kind = FileKind.from(fileExtension: url.pathExtension)
        switch kind {
        case .image:
            return await Task.detached(priority: .utility) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1_280
                      ] as CFDictionary) else { return nil }
                return RGBImage(image)
            }.value
        case .pdf:
            return await Task.detached(priority: .utility) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let document = PDFDocument(url: url), let page = firstPageImage(document) else { return nil }
                return RGBImage(page)
            }.value
        case .document, .presentation, .spreadsheet, .video:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1_024, height: 1_024), scale: 1,
                                                       representationTypes: .thumbnail)
            guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
            return RGBImage(thumbnail.cgImage)
        default:
            return nil
        }
    }

    /// When the file was made (a screenshot's or photo's own date), for a renamed picture's date.
    static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Text in an image (screenshots, photos of receipts, scans), using Apple's on-device Vision.
    /// The accurate setting: documents may go to Bonsai with only this text and no picture.
    static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// What an image shows (e.g. "document", "receipt", "food"), using Apple's on-device Vision.
    static func imageLabels(in image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).filter { $0.confidence >= 0.3 }
        let sorted = observations.sorted { $0.confidence > $1.confidence }
        return sorted.prefix(5).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}

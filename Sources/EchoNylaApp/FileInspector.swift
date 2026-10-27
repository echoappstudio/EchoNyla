import AppKit
import EchoNylaCore
import EchoNylaEngine
import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import Vision

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
    static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
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

import AppKit
import AVFoundation
import EchoNylaCore
import Foundation
import ImageIO
import NaturalLanguage
import PDFKit
import QuickLookThumbnailing
import Speech
import Vision

/// A file's facts and its picture (only on macOS 27 and later, and only when its words don't say
/// enough), read before asking the model.
struct PreparedFile: @unchecked Sendable {
    let facts: FileFacts
    let picture: CGImage?
    let captured: Date?

    static func read(_ url: URL, readContents: Bool) async -> PreparedFile {
        let facts = await FileInspector.facts(for: url, readContents: readContents)
        let picture = OnDeviceModel.seesPictures && PictureNeed.wanted(facts) ? await FileInspector.picture(for: url, readContents: readContents) : nil
        return PreparedFile(facts: facts, picture: picture, captured: FileInspector.creationDate(of: url))
    }
}

/// Reads files one step ahead: while the model works on one file, the next one's text,
/// speech and picture are already being read.
@MainActor
final class FilePreparer {
    private let readContents: Bool
    private var ahead: (url: URL, task: Task<PreparedFile, Never>)?

    init(readContents: Bool) {
        self.readContents = readContents
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
        return Task.detached(priority: .userInitiated) {
            await PreparedFile.read(url, readContents: readContents)
        }
    }
}

/// Gathers facts about a file, entirely on this Mac. Reading inside files (PDF text, documents,
/// text and objects in images, the first minute of recordings) only happens when "Look inside
/// files" is on in Settings.
enum FileInspector {
    static let textLimit = 4_000
    static let maxBytesToRead: Int64 = 60 * 1024 * 1024

    static func facts(for url: URL, readContents: Bool) async -> FileFacts {
        var facts = await Task.detached(priority: .utility) {
            gather(url, readContents: readContents)
        }.value
        if readContents, facts.kind == .audio || facts.kind == .video {
            facts.speech = await SpokenWords.firstMinute(of: url)
        }
        let words = facts.text + " " + facts.speech
        if readContents, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            facts.names = TextNames.names(in: words)
            facts.language = TextNames.language(of: words)
        }
        return facts
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

    /// A picture of the file for Apple Intelligence: the image itself, a PDF's first page, or
    /// macOS's Quick Look preview of a document, presentation, spreadsheet or video. Nil for text
    /// and code (their words are already read) and when "Look inside files" is off.
    static func picture(for url: URL, readContents: Bool) async -> CGImage? {
        guard readContents else { return nil }
        let kind = FileKind.from(fileExtension: url.pathExtension)
        switch kind {
        case .image:
            let image = await Task.detached(priority: .utility) { () -> SendableImage? in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1_280
                      ] as CFDictionary) else { return nil }
                return SendableImage(image: image)
            }.value
            return image?.image
        case .pdf:
            let page = await Task.detached(priority: .utility) { () -> SendableImage? in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let document = PDFDocument(url: url), let page = firstPageImage(document) else { return nil }
                return SendableImage(image: page)
            }.value
            return page?.image
        case .document, .presentation, .spreadsheet, .video:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1_024, height: 1_024), scale: 1,
                                                       representationTypes: .thumbnail)
            guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
            return thumbnail.cgImage
        default:
            return nil
        }
    }

    /// A picture handed from a background task.
    private struct SendableImage: @unchecked Sendable {
        let image: CGImage
    }

    /// When the file was made (a screenshot's or photo's own date), for a renamed picture's date.
    static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Text in an image (screenshots, photos of receipts, scans), using Apple's on-device Vision.
    /// The accurate setting: documents may go to the model with only this text and no picture.
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

/// People, places and companies named in a file's words, and its language, using Apple's on-device
/// Natural Language framework.
enum TextNames {
    /// Enough of the text to find the names that say what a file is about.
    static let readLimit = 2_000

    static func names(in text: String, limit: Int = 8) -> [String] {
        let sample = String(text.prefix(readLimit))
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sample
        var found: [String] = []
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, wanted.contains(tag) {
                let name = TextTools.collapseWhitespace(String(sample[range]))
                if name.count >= 2, !found.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { found.append(name) }
            }
            return found.count < limit
        }
        return found
    }

    /// The language's name in English ("French"), or nil for English and text too short to tell.
    static func language(of text: String) -> String? {
        let sample = String(text.prefix(readLimit))
        guard sample.filter(\.isLetter).count >= 40, let language = NLLanguageRecognizer.dominantLanguage(for: sample),
              language != .english, language != .undetermined else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
    }
}

/// The first minute of a voice memo, recording or video as text, using Apple's on-device speech
/// recognition. Empty when the file has no sound, the language isn't supported, or anything fails.
enum SpokenWords {
    static let listenSeconds: Double = 60

    static func firstMinute(of url: URL) async -> String {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("EchoNyla-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: clip) }
        let text = try? await withModelTimeout(.seconds(60)) {
            try await transcribe(url, clip: clip)
        }
        return String((text ?? "").prefix(FileInspector.textLimit))
    }

    private static func transcribe(_ url: URL, clip: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return "" }
        // Only the first minute is listened to: it's copied out of the file first (the file itself isn't changed).
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return "" }
        let duration = try await asset.load(.duration)
        export.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, CMTime(seconds: listenSeconds, preferredTimescale: 600)))
        try await export.export(to: clip, as: .m4a)

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // Apple's speech model for this language, once (a system download, kept by macOS).
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let audio = try AVAudioFile(forReading: clip)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let words = transcriber.results.reduce(into: "") { text, result in
            if result.isFinal { text += String(result.text.characters) + " " }
        }
        if let end = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            try? await analyzer.cancelAndFinishNow()
        }
        return TextTools.collapseWhitespace(try await words)
    }
}

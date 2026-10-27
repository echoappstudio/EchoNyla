import CoreGraphics
import CoreText
import EchoNylaCore
import EchoNylaEngine
import Foundation

// Proves the whole on-device path end to end: download Ternary Bonsai 2 9B (both files, checked),
// load it in the embedded llama.cpp engine, show it a screenshot it can only understand by looking
// at it, and check the structured answer. Reports time and peak memory.
//
//   swift run -c release EchoNylaModelCheck [--folder <dir>] [--cpu] [--image-tokens <n>]

var folder: URL?
var cpuOnly = false
var imageTokens: Int32 = 1_024
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--folder": folder = arguments.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
    case "--cpu": cpuOnly = true
    case "--image-tokens": imageTokens = arguments.next().flatMap { Int32($0) } ?? imageTokens
    default:
        print("Unknown option \(argument)")
        exit(2)
    }
}

func gigabytes(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

/// A screenshot of an invoice, drawn here so the test needs no files: the words are only in the picture.
func invoiceScreenshot() -> CGImage? {
    let width = 1_200, height = 800
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.12, green: 0.32, blue: 0.62, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 120, width: width, height: 120))
    let lines: [(String, CGFloat, CGFloat, Bool)] = [
        ("Acme Plumbing", 56, CGFloat(height - 90), true),
        ("INVOICE #2231", 44, 560, false),
        ("Service: kitchen sink repair", 34, 470, false),
        ("Date: October 21, 2026", 34, 410, false),
        ("Amount due: $148.20", 40, 330, false),
        ("Thank you for your business!", 30, 200, false)
    ]
    for (text, size, y, white) in lines {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let color = white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        context.textPosition = CGPoint(x: 60, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    return context.makeImage()
}

let folders = [
    Destination(id: "bills", name: "Bills", purpose: "Utility bills, repair invoices and receipts for the apartment"),
    Destination(id: "pics", name: "purevopic", purpose: "Pictures and screen recordings for the Purevo app's website")
]

func report(_ title: String, _ result: LocalResult) {
    let answer = result.answer
    print("""
        \(title)
          what it is:  \(answer.whatItIs)
          name:        \(answer.name) (confidence \(answer.nameConfidence))
          folder:      \(answer.folder) (confidence \(answer.folderConfidence)), quoted "\(answer.noteWords)"
          checked:     folder \(result.decision.decision.destinationID ?? "none"), moves by itself: \(result.decision.decision.isConfident), \
        new name: \(result.decision.decision.proposedName ?? "none"), renames by itself: \(result.decision.renameIsSure)
          time:        \(String(format: "%.1f", result.reply.seconds)) s for \(result.reply.promptTokens) prompt and \(result.reply.generatedTokens) answer tokens
          peak memory: \(gigabytes(result.reply.peakMemoryBytes))
        """)
}

/// Prints each tenth of the download once.
final class ShownSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func next(_ step: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard step != last else { return nil }
        last = step
        return step
    }
}

let semaphore = DispatchSemaphore(value: 0)
var failures: [String] = []
Task {
    do {
        let installer = ModelInstaller(spec: .bonsai9B, folder: folder)
        let planned = try await installer.plannedFiles()
        print("Files: \(planned.model.path) (\(gigabytes(UInt64(planned.model.size)))), \(planned.projector.path) (\(gigabytes(UInt64(planned.projector.size))))")
        let shown = ShownSteps()
        let started = Date()
        let paths = try await installer.install { fraction in
            if let step = shown.next(Int(fraction * 10)) { print("Downloading… \(step * 10)%") }
        }
        print("Installed and checked in \(Int(Date().timeIntervalSince(started))) s: \(paths.model.lastPathComponent)")

        let engine = LlamaEngine()
        engine.options.gpuLayers = cpuOnly ? 0 : -1
        engine.options.imageMaxTokens = imageTokens

        // 1. A screenshot with a meaningless name and no text read from it: only the picture says what it is.
        guard let picture = invoiceScreenshot().flatMap({ RGBImage($0) }) else { throw EngineError.pictureNotRead(-1) }
        let screenshot = FileFacts(fileName: "Screenshot 2026-10-27 at 9.41.02 AM.png", isScreenshot: true)
        let first = try await LocalFileModel.ask(LocalQuestion(facts: screenshot, picture: picture, destinations: folders, locked: []),
                                                 paths: paths, bar: .standard, engine: engine)
        report("1. Invoice screenshot (the picture is the only clue)", first)
        let seen = (first.answer.whatItIs + " " + first.answer.name).lowercased()
        if !["acme", "plumbing", "invoice"].contains(where: seen.contains) { failures.append("it didn't read the screenshot") }
        if first.answer.folder == "purevopic" { failures.append("it put an invoice in the app pictures folder") }

        // 2. The "2 week notice" mistake: a resignation letter must not go to the app pictures folder.
        let notice = FileFacts(fileName: "2 week notice.pages",
                               text: "Dear Ms. Rivera, Please accept this letter as my formal two weeks notice of resignation from my position.")
        let second = try await LocalFileModel.ask(LocalQuestion(facts: notice, picture: nil, destinations: folders, locked: []),
                                                  paths: paths, bar: .standard, engine: engine)
        report("2. Resignation letter (text only)", second)
        if second.decision.decision.destinationID == "pics" { failures.append("the resignation letter passed the safety net for purevopic") }
    } catch {
        failures.append(error.localizedDescription)
    }
    semaphore.signal()
}
semaphore.wait()
if failures.isEmpty {
    print("Model check passed.")
} else {
    print("Model check failed: " + failures.joined(separator: "; "))
    exit(1)
}

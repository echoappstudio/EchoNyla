import CryptoKit
import EchoNylaCore
import Foundation

public enum InstallError: LocalizedError {
    case listingUnavailable
    case filesNotFound
    case downloadFailed(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .listingUnavailable: return "Couldn't reach Hugging Face to find the model files. Check the internet connection and try again."
        case .filesNotFound: return "The model's files weren't where they should be on Hugging Face."
        case .downloadFailed(let reason): return "The download stopped: \(reason)"
        case .checksumMismatch(let name): return "\(name) didn't match its published checksum, so it was deleted. Try again."
        }
    }
}

/// Downloads a model's two files into Application Support, checks each against its published
/// SHA-256, and remembers what's installed. Nothing else ever goes over the network.
public final class ModelInstaller: @unchecked Sendable {
    public let spec: LocalModelSpec
    public let folder: URL

    private struct Manifest: Codable {
        var model: HubFile
        var projector: HubFile
    }

    public init(spec: LocalModelSpec = .bonsai9B, folder: URL? = nil) {
        self.spec = spec
        self.folder = folder ?? Self.defaultFolder(for: spec)
    }

    public static func defaultFolder(for spec: LocalModelSpec) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("EchoNyla/Models/\(spec.id)", isDirectory: true)
    }

    private var manifestURL: URL { folder.appendingPathComponent("manifest.json") }

    /// The installed files, or nil when the model isn't (fully) installed.
    public func installed() -> ModelPaths? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let paths = ModelPaths(model: folder.appendingPathComponent(manifest.model.path),
                               projector: folder.appendingPathComponent(manifest.projector.path))
        guard size(of: paths.model) == manifest.model.size, size(of: paths.projector) == manifest.projector.size else { return nil }
        return paths
    }

    /// How much the download is, in bytes, once the file list is known.
    public func plannedFiles() async throws -> (model: HubFile, projector: HubFile) {
        let (data, response) = try await URLSession.shared.data(from: spec.listingURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.listingUnavailable }
        guard let files = ModelFiles.choose(ModelFiles.parseListing(data)) else { throw InstallError.filesNotFound }
        return files
    }

    /// Downloads and checks both files. `progress` gets 0…1 over the whole download.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws -> ModelPaths {
        if let paths = installed() { return paths }
        let files = try await plannedFiles()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = Double(files.model.size + files.projector.size)
        var done: Int64 = 0
        for file in [files.projector, files.model] {
            let destination = folder.appendingPathComponent(file.path)
            let offset = done
            if size(of: destination) != file.size || (try? Self.sha256(of: destination)) != file.sha256 {
                try? FileManager.default.removeItem(at: destination)
                let downloaded = try await FileDownload(url: spec.downloadURL(for: file)) { written in
                    progress(min(1, Double(offset + written) / max(total, 1)))
                }.run()
                guard (try? Self.sha256(of: downloaded)) == file.sha256 else {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw InstallError.checksumMismatch(file.path)
                }
                try FileManager.default.moveItem(at: downloaded, to: destination)
            }
            done += file.size
            progress(min(1, Double(done) / max(total, 1)))
        }
        try JSONEncoder().encode(Manifest(model: files.model, projector: files.projector)).write(to: manifestURL, options: .atomic)
        guard let paths = installed() else { throw InstallError.filesNotFound }
        return paths
    }

    /// Deletes the model's files.
    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The size of the installed files on disk.
    public func installedBytes() -> Int64 {
        guard let paths = installed() else { return 0 }
        return (size(of: paths.model) ?? 0) + (size(of: paths.projector) ?? 0)
    }

    private func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// SHA-256 of a file, read 8 MB at a time.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file download with progress, into a temporary file the caller moves.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(url: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.progress = progress
    }

    func run() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForResource = 6 * 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it's moved first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("EchoNyla-\(UUID().uuidString).part")
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            finish(.failure(InstallError.downloadFailed("the server answered \(status).")))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(InstallError.downloadFailed(error.localizedDescription))) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}

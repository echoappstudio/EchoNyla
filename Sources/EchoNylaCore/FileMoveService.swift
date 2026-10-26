import Foundation

public struct FileMoveReceipt: Codable, Equatable {
    public let originalURL: URL
    public let movedURL: URL

    public init(originalURL: URL, movedURL: URL) {
        self.originalURL = originalURL
        self.movedURL = movedURL
    }
}

public struct MoveBatchReceipt: Codable, Equatable {
    public let moves: [FileMoveReceipt]
    /// Contains only folders EchoNyla itself created for this approved batch.
    public let createdFolders: [URL]

    public init(moves: [FileMoveReceipt], createdFolders: [URL] = []) {
        self.moves = moves
        self.createdFolders = createdFolders
    }
}

public enum FileMoveError: Error, Equatable {
    case sourceDoesNotExist
    case sourceIsDirectory
    case destinationIsNotDirectory
    case sourceAlreadyInDestination
    case movedFileDoesNotExist
    case originalPathOccupied
    case invalidName
    case nameUnchanged
}

/// Performs one explicit file move and records enough information to undo it.
/// The UI must call `move` only after the user confirms the destination.
public struct FileMoveService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func move(_ sourceURL: URL, to destinationFolderURL: URL) throws -> FileMoveReceipt {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileMoveError.sourceDoesNotExist
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw FileMoveError.sourceDoesNotExist
        }
        guard !isDirectory.boolValue else {
            throw FileMoveError.sourceIsDirectory
        }

        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationFolderURL.path, isDirectory: &destinationIsDirectory),
              destinationIsDirectory.boolValue else {
            throw FileMoveError.destinationIsNotDirectory
        }

        let sourceParent = sourceURL.deletingLastPathComponent().standardizedFileURL
        let destinationParent = destinationFolderURL.standardizedFileURL
        guard sourceParent != destinationParent else {
            throw FileMoveError.sourceAlreadyInDestination
        }

        let targetURL = uniqueDestination(for: sourceURL, in: destinationFolderURL)
        try fileManager.moveItem(at: sourceURL, to: targetURL)
        return FileMoveReceipt(originalURL: sourceURL, movedURL: targetURL)
    }

    /// Renames a file in its own folder after you approve the new name. If the name is taken, a
    /// number is added ("Lease renewal 2.pdf"). Undo puts the old name back.
    public func rename(_ fileURL: URL, to newName: String) throws -> FileMoveReceipt {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw FileMoveError.invalidName
        }
        guard name != fileURL.lastPathComponent else { throw FileMoveError.nameUnchanged }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw FileMoveError.sourceDoesNotExist
        }
        guard !isDirectory.boolValue else { throw FileMoveError.sourceIsDirectory }
        let folder = fileURL.deletingLastPathComponent()
        let target = uniqueDestination(for: folder.appendingPathComponent(name), in: folder)
        try fileManager.moveItem(at: fileURL, to: target)
        return FileMoveReceipt(originalURL: fileURL, movedURL: target)
    }

    public func undo(_ receipt: FileMoveReceipt) throws {
        guard fileManager.fileExists(atPath: receipt.movedURL.path) else {
            throw FileMoveError.movedFileDoesNotExist
        }
        guard !fileManager.fileExists(atPath: receipt.originalURL.path) else {
            throw FileMoveError.originalPathOccupied
        }
        try fileManager.moveItem(at: receipt.movedURL, to: receipt.originalURL)
    }

    public func undo(_ receipt: MoveBatchReceipt) throws {
        for moveReceipt in receipt.moves.reversed() {
            try undo(moveReceipt)
        }
        for folderURL in receipt.createdFolders.reversed() where fileManager.fileExists(atPath: folderURL.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: folderURL.path)
            guard contents.isEmpty else { continue }
            try fileManager.removeItem(at: folderURL)
        }
    }

    private func uniqueDestination(for sourceURL: URL, in folderURL: URL) -> URL {
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let filename = ext.isEmpty ? "\(name) \(suffix)" : "\(name) \(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(filename)
            suffix += 1
        }
        return candidate
    }
}

import AppKit
import EchoNylaCore
import SwiftUI
import UniformTypeIdentifiers

/// A file's type as a picture: the bundled icon for its type (Word, PDF, MP3…), macOS's own artwork
/// for Mac types (Pages, Keynote, apps…), or a blank page with the type's letters. A small tag in the
/// skin's accent names the type ("DOCX") on icons large enough for it.
struct FileTypeIcon: View {
    let fileName: String
    /// Where the file is, so an app shows its own icon.
    var path: String?
    var size: CGFloat
    var showsTag = true

    var body: some View {
        let info = FileTypeCatalog.info(forFileName: fileName)
        let lightSkin = !NylaStyle.isDark
        ZStack {
            if case .letters(let letters) = info.artwork {
                lettersPage(letters)
            } else {
                Image(nsImage: FileTypeImages.image(for: info, path: path, lightSkin: lightSkin))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            if showsTag, size >= 30, let tag = info.tag, !isLetters(info) {
                Text(tag)
                    .font(.system(size: max(7, size * 0.19), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(NylaStyle.onAccent)
                    .padding(.horizontal, size * 0.08)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(NylaStyle.brass))
                    .offset(y: size * 0.14)
            }
        }
        .accessibilityLabel(info.label)
        .help(info.label)
    }

    private func isLetters(_ info: FileTypeInfo) -> Bool {
        if case .letters = info.artwork { return true }
        return false
    }

    /// macOS's blank page with the type's letters across it, in the skin's accent.
    private func lettersPage(_ letters: String) -> some View {
        ZStack {
            Image(nsImage: FileTypeImages.blankPage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            Text(letters)
                .font(.system(size: size * (letters.count > 3 ? 0.2 : 0.25), weight: .heavy, design: .rounded))
                .foregroundStyle(NylaStyle.isDark ? Color(nsColor: .darkGray) : NylaStyle.brass)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size * 0.56)
                .offset(y: size * 0.08)
        }
    }
}

/// Loads and keeps the pictures `FileTypeIcon` draws.
@MainActor
enum FileTypeImages {
    private static var cache: [String: NSImage] = [:]

    static var blankPage: NSImage {
        cached("blank") { NSWorkspace.shared.icon(for: .data) }
    }

    static func image(for info: FileTypeInfo, path: String?, lightSkin: Bool) -> NSImage {
        switch info.artwork {
        case .bundled(let name, let hasLightVersion):
            let resource = hasLightVersion && lightSkin ? "\(name)-light" : name
            return cached("bundled-\(resource)") {
                Bundle.main.url(forResource: resource, withExtension: "png", subdirectory: "FileTypes")
                    .flatMap { NSImage(contentsOf: $0) } ?? NSWorkspace.shared.icon(for: .data)
            }
        case .system(let artwork):
            if artwork == .application, let path, FileManager.default.fileExists(atPath: path) {
                return cached("app-\(path)") { NSWorkspace.shared.icon(forFile: path) }
            }
            return cached("system-\(artwork.rawValue)") { systemImage(artwork) }
        case .letters:
            return blankPage
        }
    }

    /// The owning app's icon when it's installed, otherwise the system's icon for the type.
    private static func systemImage(_ artwork: SystemFileArtwork) -> NSImage {
        for bundleID in artwork.appBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        switch artwork {
        case .application: return NSWorkspace.shared.icon(for: .applicationBundle)
        case .propertyList: return NSImage(named: NSImage.advancedName) ?? NSWorkspace.shared.icon(for: .propertyList)
        case .alias: return NSWorkspace.shared.icon(for: .aliasFile)
        case .pages: return typeIcon("pages")
        case .numbers: return typeIcon("numbers")
        case .keynote: return typeIcon("key")
        case .email: return typeIcon("eml")
        case .calendar: return typeIcon("ics")
        case .contact: return NSWorkspace.shared.icon(for: .vCard)
        case .macIcon: return NSWorkspace.shared.icon(for: .icns)
        }
    }

    private static func typeIcon(_ fileExtension: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: fileExtension) ?? .data)
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }
}

import Foundation

/// The picture EchoNyla shows for a file, chosen from its extension.
public enum FileTypeArtwork: Equatable, Sendable {
    /// One of the bundled icons in Resources/FileTypes (`<name>.png`, plus `<name>-light.png` for
    /// light skins when `hasLightVersion`: icons whose usual colours are too pale or too dark for one
    /// of the two).
    case bundled(name: String, hasLightVersion: Bool)
    /// A Mac file type drawn with macOS's own artwork at run time (never copied into the app).
    case system(SystemFileArtwork)
    /// No icon is known: a blank page with the type's letters on it.
    case letters(String)
}

/// Mac types whose pictures come from macOS itself: the app that owns them when it's installed,
/// otherwise the system's icon for the type.
public enum SystemFileArtwork: String, Equatable, Sendable, CaseIterable {
    case pages, numbers, keynote, email, calendar, contact, application, macIcon, propertyList, alias

    /// Apps whose own icon stands for the type, first one installed wins.
    public var appBundleIDs: [String] {
        switch self {
        case .pages: return ["com.apple.iWork.Pages"]
        case .numbers: return ["com.apple.iWork.Numbers"]
        case .keynote: return ["com.apple.iWork.Keynote"]
        case .email: return ["com.apple.mail"]
        case .calendar: return ["com.apple.iCal"]
        case .contact: return ["com.apple.AddressBook"]
        case .macIcon: return ["com.apple.Preview"]
        case .application, .propertyList, .alias: return []
        }
    }
}

/// A file type: its picture and a short name for it ("Word", "PDF", "MP3 audio").
public struct FileTypeInfo: Equatable, Sendable {
    public let artwork: FileTypeArtwork
    public let label: String
    /// The extension in capitals for the small tag on the icon ("DOCX"), or nil when there is none.
    public let tag: String?

    public init(artwork: FileTypeArtwork, label: String, tag: String?) {
        self.artwork = artwork
        self.label = label
        self.tag = tag
    }
}

public enum FileTypeCatalog {
    /// Icons with a darker version for light skins (their usual colours are pale).
    public static let lightVersions: Set<String> = ["tex", "json", "yaml", "rust", "ini", "font"]

    /// Extension → (bundled icon, label). Related types share a category icon (image, audio, video, zip).
    static let bundled: [String: (String, String)] = [
        // Documents
        "pdf": ("pdf", "PDF"), "docx": ("word", "Word"), "doc": ("word", "Word legacy"), "txt": ("text", "Plain text"),
        "rtf": ("text", "Rich text"), "odt": ("libreoffice_writer", "OpenDocument"), "md": ("markdown", "Markdown"),
        "markdown": ("markdown", "Markdown"), "tex": ("tex", "LaTeX"), "epub": ("epub", "E-book"), "msg": ("outlook", "Outlook message"),
        // Spreadsheets, presentations, data
        "xlsx": ("excel", "Excel"), "xls": ("excel", "Excel legacy"), "csv": ("csv", "Comma-separated"), "tsv": ("csv", "Tab-separated"),
        "ods": ("libreoffice_calc", "OpenDocument"), "pptx": ("powerpoint", "PowerPoint"), "ppt": ("powerpoint", "PowerPoint legacy"),
        "odp": ("libreoffice_impress", "OpenDocument"), "json": ("json", "JSON data"), "xml": ("xml", "XML data"),
        // Images
        "jpg": ("image", "JPEG image"), "jpeg": ("image", "JPEG image"), "png": ("image", "PNG image"), "gif": ("image", "GIF image"),
        "webp": ("image", "WebP image"), "svg": ("svg", "Vector image"), "heic": ("image", "HEIC image"), "heif": ("image", "HEIF image"),
        "avif": ("avif", "AVIF image"), "tiff": ("image", "TIFF image"), "tif": ("image", "TIFF image"), "bmp": ("image", "Bitmap"),
        "ico": ("image", "Icon"),
        // Design
        "psd": ("photoshop", "Photoshop"), "ai": ("ai", "Illustrator"), "eps": ("eps", "PostScript"), "sketch": ("sketch", "Sketch"),
        "blend": ("blender", "Blender"), "fbx": ("fbx", "3D model"), "gltf": ("gltf", "3D scene"), "glb": ("gltf", "3D scene"),
        "xcf": ("gimp", "GIMP"), "pub": ("publisher", "Publisher"), "one": ("onenote", "OneNote"),
        // Audio
        "mp3": ("audio", "MP3 audio"), "wav": ("audio", "Wave audio"), "aac": ("audio", "AAC audio"), "m4a": ("audio", "MPEG-4 audio"),
        "flac": ("audio", "Lossless audio"), "ogg": ("audio", "Ogg audio"), "opus": ("audio", "Opus audio"), "aiff": ("audio", "AIFF audio"),
        "aif": ("audio", "AIFF audio"), "wma": ("audio", "Windows audio"), "mid": ("audio", "MIDI music"), "midi": ("audio", "MIDI music"),
        // Video
        "mp4": ("video", "MPEG-4 video"), "mov": ("video", "QuickTime"), "avi": ("video", "AVI video"), "mkv": ("video", "Matroska"),
        "webm": ("video", "WebM video"), "wmv": ("video", "Windows video"), "mpeg": ("video", "MPEG video"), "mpg": ("video", "MPEG video"),
        "m4v": ("video", "M4V video"), "3gp": ("video", "Mobile video"), "srt": ("text", "Subtitles"), "vtt": ("text", "Subtitles"),
        // Archives and installers
        "zip": ("zip", "ZIP archive"), "rar": ("zip", "RAR archive"), "7z": ("zip", "7-Zip archive"), "tar": ("zip", "TAR archive"),
        "gz": ("zip", "Gzip archive"), "tgz": ("zip", "Gzip archive"), "bz2": ("zip", "Bzip2 archive"), "xz": ("zip", "XZ archive"),
        "iso": ("binary", "Disc image"), "dmg": ("package", "Mac disk image"), "pkg": ("package", "Mac installer"),
        "mpkg": ("package", "Mac installer"),
        // Web and code
        "html": ("html", "HTML page"), "htm": ("html", "HTML page"), "css": ("css", "Stylesheet"), "js": ("js", "JavaScript"),
        "mjs": ("js", "JavaScript"), "ts": ("typescript", "TypeScript"), "jsx": ("reactjs", "React JSX"), "tsx": ("reactts", "React TSX"),
        "scss": ("scss", "Sass styles"), "sass": ("sass", "Sass styles"), "yaml": ("yaml", "YAML data"), "yml": ("yaml", "YAML data"),
        "sql": ("sql", "SQL query"), "db": ("db", "Database"), "sqlite": ("db", "Database"), "py": ("python", "Python"),
        "java": ("java", "Java"), "c": ("c", "C source"), "cpp": ("cpp", "C++ source"), "cc": ("cpp", "C++ source"),
        "h": ("cheader", "C header"), "cs": ("csharp", "C# source"), "go": ("go", "Go"), "rs": ("rust", "Rust"), "php": ("php", "PHP"),
        "rb": ("ruby", "Ruby"),
        // System and other
        "exe": ("binary", "Windows app"), "msi": ("package", "Windows installer"), "dll": ("binary", "Shared library"),
        "bat": ("bat", "Batch script"), "sh": ("shell", "Shell script"), "zsh": ("shell", "Shell script"), "bash": ("shell", "Shell script"),
        "ps1": ("powershell", "PowerShell"), "ini": ("ini", "Configuration"), "cfg": ("ini", "Configuration"), "conf": ("ini", "Configuration"),
        "log": ("log", "Log file"), "ttf": ("font", "TrueType font"), "otf": ("font", "OpenType font"), "woff": ("font", "Web font"),
        "woff2": ("font", "Web font")
    ]

    static let system: [String: (SystemFileArtwork, String)] = [
        "pages": (.pages, "Pages document"), "numbers": (.numbers, "Numbers spreadsheet"), "key": (.keynote, "Keynote presentation"),
        "eml": (.email, "Email message"), "ics": (.calendar, "Calendar event"), "vcf": (.contact, "Contact card"),
        "app": (.application, "Mac application"), "icns": (.macIcon, "Mac icon file"), "plist": (.propertyList, "Property list"),
        "alias": (.alias, "Alias")
    ]

    /// Every bundled icon name, for the packaging check.
    public static var bundledIconNames: Set<String> { Set(bundled.values.map(\.0)) }

    public static func info(forFileName fileName: String) -> FileTypeInfo {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let tag = ext.isEmpty ? nil : String(ext.uppercased().prefix(5))
        if let (name, label) = bundled[ext] {
            return FileTypeInfo(artwork: .bundled(name: name, hasLightVersion: lightVersions.contains(name)), label: label, tag: tag)
        }
        if let (artwork, label) = system[ext] {
            return FileTypeInfo(artwork: .system(artwork), label: label, tag: tag)
        }
        return FileTypeInfo(artwork: .letters(letters(forFileName: fileName)), label: ext.isEmpty ? "File" : "\(ext.uppercased()) file", tag: tag)
    }

    /// Up to four letters for a type nobody listed: the extension ("BIN"), or the first two letters of
    /// a name without one ("RE" for README), or "?" when there is nothing to show.
    public static func letters(forFileName fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension.filter { $0.isLetter || $0.isNumber }
        if !ext.isEmpty { return String(ext.uppercased().prefix(4)) }
        let stem = url.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber }
        return stem.isEmpty ? "?" : String(stem.uppercased().prefix(2))
    }
}

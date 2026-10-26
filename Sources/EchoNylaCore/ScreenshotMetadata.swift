import CoreServices
import Darwin
import Foundation

/// Reads Finder/Spotlight's screen-capture flag locally, without opening or uploading file contents.
public enum ScreenshotMetadata {
    private static let attributeName = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let spotlightName = "kMDItemIsScreenCapture" as CFString

    public static func isScreenCapture(at url: URL) -> Bool {
        if let value = extendedAttributeValue(at: url), value {
            return true
        }

        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, spotlightName) else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func extendedAttributeValue(at url: URL) -> Bool? {
        let size = url.path.withCString { path in
            attributeName.withCString { name in
                getxattr(path, name, nil, 0, 0, 0)
            }
        }
        guard size > 0 else { return nil }

        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { buffer in
            url.path.withCString { path in
                attributeName.withCString { name in
                    getxattr(path, name, buffer.baseAddress, size, 0, 0)
                }
            }
        }
        guard readSize == size,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }
}

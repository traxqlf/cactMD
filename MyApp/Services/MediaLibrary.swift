import AppKit
import Foundation
import ImageIO

nonisolated enum MediaPayload: Sendable {
    case data(Data, suggestedName: String)
    case file(URL)
}

nonisolated enum MediaLibrary {
    static let assetsFolderName = "assets"

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Resolves a Markdown image destination relative to the note, rejecting remote URLs.
    static func resolveImageURL(_ destination: String, baseURL: URL) -> URL? {
        var path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("<"), path.hasSuffix(">") {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            let standardized = url.standardizedFileURL
            return FileManager.default.fileExists(atPath: standardized.path) ? standardized : nil
        }
        if let url = URL(string: path), let scheme = url.scheme, scheme != "file" {
            return nil
        }
        let decoded = path.removingPercentEncoding ?? path
        let candidate = decoded.hasPrefix("/")
            ? URL(fileURLWithPath: decoded)
            : baseURL.appendingPathComponent(decoded)
        let standardized = candidate.standardizedFileURL
        return FileManager.default.fileExists(atPath: standardized.path) ? standardized : nil
    }

    /// Copies the payload into `<note folder>/assets` and returns the Markdown
    /// destination relative to the note.
    static func save(_ payload: MediaPayload, noteDirectory: URL) throws -> String {
        let assetsURL = noteDirectory.appendingPathComponent(assetsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        let destination: URL
        switch payload {
        case .file(let source):
            let extensionName = source.pathExtension.lowercased()
            let stem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
            destination = uniqueURL(
                in: assetsURL,
                stem: stem,
                pathExtension: extensionName.isEmpty ? "png" : extensionName
            )
            try FileManager.default.copyItem(at: source, to: destination)

        case .data(let data, let suggestedName):
            let stem = sanitizedStem((suggestedName as NSString).deletingPathExtension)
            destination = uniqueURL(in: assetsURL, stem: stem, pathExtension: "png")
            guard let png = pngData(from: data) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: destination, options: .atomic)
        }

        return "\(assetsFolderName)/\(destination.lastPathComponent)"
    }

    /// Decodes a bounded thumbnail so a large photo cannot blow the memory budget.
    static func thumbnail(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func pngData(from data: Data) -> Data? {
        if let representation = NSBitmapImageRep(data: data) {
            return representation.representation(using: .png, properties: [:])
        }
        if let image = NSImage(data: data),
           let tiff = image.tiffRepresentation,
           let representation = NSBitmapImageRep(data: tiff) {
            return representation.representation(using: .png, properties: [:])
        }
        return nil
    }

    private static func sanitizedStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let text = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !text.isEmpty else { return "image" }
        return String(text.prefix(80))
    }

    private static func uniqueURL(in directory: URL, stem: String, pathExtension: String) -> URL {
        var index = 1
        while true {
            let name = index == 1 ? "\(stem).\(pathExtension)" : "\(stem)-\(index).\(pathExtension)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}

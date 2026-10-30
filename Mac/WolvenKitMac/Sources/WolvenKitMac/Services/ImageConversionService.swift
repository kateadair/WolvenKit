import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ImageConversionService: Sendable {
    func convert(_ source: URL, to destination: URL, jpegQuality: Double = 0.92) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.convertSynchronously(source, destination: destination, jpegQuality: jpegQuality)
        }.value
    }

    private static func convertSynchronously(_ source: URL, destination: URL, jpegQuality: Double) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil) else {
            throw ImageConversionError.unreadableSource
        }
        let type: UTType
        switch destination.pathExtension.lowercased() {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "tif", "tiff": type = .tiff
        default: throw ImageConversionError.unsupportedDestination
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageConversionError.cannotCreateDestination
        }

        let properties: CFDictionary?
        if type == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, jpegQuality))] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destinationRef, image, properties)
        guard CGImageDestinationFinalize(destinationRef) else { throw ImageConversionError.writeFailed }
    }
}

private enum ImageConversionError: LocalizedError {
    case unreadableSource
    case unsupportedDestination
    case cannotCreateDestination
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: return "The selected image format could not be decoded."
        case .unsupportedDestination: return "Choose a PNG, JPEG, or TIFF output file."
        case .cannotCreateDestination: return "The image destination could not be created."
        case .writeFailed: return "The converted image could not be written."
        }
    }
}

// Copyright (c) 2021 Dmitry Meduho
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
// distribute, sublicense, create a derivative work, and/or sell copies of the
// Software in any work that is designed, intended, or marketed for pedagogical or
// instructional purposes related to programming, coding, application development,
// or information technology.  Permission for such use, copying, modification,
// merger, publication, distribution, sublicensing, creation of derivative works,
// or sale is expressly withheld.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import AppKit
import AVFoundation

// MARK: - Protocols

public typealias ProgressCallback = (Int, Int) -> Void

public protocol ImageCore {
    func createImage(
        from attributes: [ImageAttributes],
        metadata: CGImageMetadata,
        progressCallback: ProgressCallback?
    ) throws -> Data
    func getImageFormat(for url: URL) throws -> ImageFormatType
    func extractHEICFrame(from data: Data, at index: Int) throws -> Data
    func resizeImage(image: NSImage, size: NSSize) -> NSImage
    func validateImage(_ url: URL, imageFormat: [ImageFormatType]) -> Bool
}

// MARK: - Enums, Structs

extension ImageCoreImpl {
    private enum ImageHeaderSignature {
        static let png: [UInt8] = [0x89]
        static let jpeg: [UInt8] = [0xFF]
        static let tiff1: [UInt8] = [0x49]
        static let tiff2: [UInt8] = [0x4D]
        static let heic: [UInt8] = [0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]
    }

    private enum Constants {
        static let heicOffset = 4
    }
}

// MARK: - Class

public final class ImageCoreImpl: ImageCore {
    public init() {
    }
    
    // MARK: - Public

    public func createImage(
        from attributes: [ImageAttributes],
        metadata: CGImageMetadata,
        progressCallback: ProgressCallback?
    ) throws -> Data {
        let destinationType = AVFileType.heic as CFString
        let steps = attributes.count + 1
        if let imageData = try copyExistingHEIC(
            from: attributes,
            metadata: metadata,
            destinationType: destinationType
        ) {
            for index in attributes.indices {
                progressCallback?(index + 1, steps)
            }
            progressCallback?(steps, steps)
            return imageData
        }

        if let imageData = try packHEICFrames(
            from: attributes,
            metadata: metadata
        ) {
            for index in attributes.indices {
                progressCallback?(index + 1, steps)
            }
            progressCallback?(steps, steps)
            return imageData
        }

        return try createImageData(
            from: attributes,
            metadata: metadata,
            destinationType: destinationType,
            progressCallback: progressCallback
        )
    }

    public func extractHEICFrame(from data: Data, at index: Int) throws -> Data {
        guard let imageData = HEIFMuxer.extractImage(in: data, at: index) else {
            throw ImageError.invalidImageFormat
        }
        return imageData
    }
        
    public func resizeImage(image: NSImage, size: NSSize) -> NSImage {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard
            let cgImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ),
            let context = CGContext(
                data: nil,
                width: max(Int(size.width.rounded()), 1),
                height: max(Int(size.height.rounded()), 1),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let resizedImage = context.makeImage() else {
            return image
        }
        return NSImage(cgImage: resizedImage, size: size)
    }
    
    public func getImageFormat(for url: URL) throws -> ImageFormatType {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String? {
            switch type {
            case "public.png":
                return .png
            case "public.jpeg":
                return .jpeg
            case "public.tiff":
                return .tiff
            case "public.heic", "public.heif":
                return .heic
            default:
                break
            }
        }

        var data: Data
        let signatureLength = 1

        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImageError.dataNotObtained
        }

        guard !data.isEmpty else {
            throw ImageError.invalidImageFormat
        }

        var buffer = [UInt8](repeating: 0, count: signatureLength)
        data.copyBytes(to: &buffer, count: signatureLength)

        switch buffer {
        case ImageHeaderSignature.png:
            return .png

        case ImageHeaderSignature.jpeg:
            return .jpeg

        case ImageHeaderSignature.tiff1, ImageHeaderSignature.tiff2:
            return .tiff

        default:
            var heicBuffer = [UInt8](
                repeating: 0,
                count: ImageHeaderSignature.heic.count
            )
            let lowerbound = Constants.heicOffset
            let upperbound = lowerbound + ImageHeaderSignature.heic.count
            guard data.count >= upperbound else {
                throw ImageError.invalidImageFormat
            }
            let range = lowerbound..<upperbound
            data.copyBytes(to: &heicBuffer, from: range)
            if heicBuffer == ImageHeaderSignature.heic {
                return .heic
            }
            throw ImageError.invalidImageFormat
        }
    }

    public func validateImage(_ url: URL, imageFormat: [ImageFormatType]) -> Bool {
        do {
            let format = try getImageFormat(for: url)
            return imageFormat.contains(format)
        } catch {
            return false
        }
    }
    
    // MARK: - Private
    
    private func readImage(from url: URL, index: Int?) throws -> CGImage {
        if let index = index {
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                index >= 0,
                index < CGImageSourceGetCount(source),
                let image = CGImageSourceCreateImageAtIndex(source, index, nil)
            else {
                throw ImageError.invalidImageFormat
            }
            return image
        }
        guard let image = NSImage(contentsOf: url) else {
            throw ImageError.invalidImageFormat
        }
        return try convertImage(image)
    }

    private func packHEICFrames(
        from attributes: [ImageAttributes],
        metadata: CGImageMetadata
    ) throws -> Data? {
        guard attributes.count > 1,
              attributes.allSatisfy({
                  $0.sourceIndex == nil || $0.sourceIndex == 0
              }),
              let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data?
        else {
            return nil
        }

        var sources: [Data] = []
        for attribute in attributes {
            guard try isHEICImage(at: attribute.url),
                  let frame = try? Data(contentsOf: attribute.url) else {
                return nil
            }
            sources.append(frame)
        }

        return HEIFMuxer.pack(sources, xmp: xmp)
    }

    private func createImageData(
        from attributes: [ImageAttributes],
        metadata: CGImageMetadata,
        destinationType: CFString,
        progressCallback: ProgressCallback?
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            destinationType,
            attributes.count,
            nil
        ) else {
            throw ImageError.destinationNotCreated
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: lossyCompressionQuality
        ] as CFDictionary

        for (index, attribute) in attributes.enumerated() {
            if try isHEICImage(at: attribute.url) {
                guard let source = CGImageSourceCreateWithURL(
                    attribute.url as CFURL,
                    nil
                ) else {
                    throw ImageError.invalidImageFormat
                }

                let sourceIndex = attribute.sourceIndex ?? 0
                guard sourceIndex >= 0,
                      sourceIndex < CGImageSourceGetCount(source) else {
                    throw ImageError.invalidImageFormat
                }

                // ImageIO re-encodes HEIC when composing separate sources.
                CGImageDestinationAddImageFromSource(
                    destination,
                    source,
                    sourceIndex,
                    options
                )
            } else {
                let image = try readImage(from: attribute.url,
                                          index: attribute.sourceIndex)

                if index == 0 {
                    CGImageDestinationAddImageAndMetadata(
                        destination,
                        image,
                        metadata,
                        options
                    )
                } else {
                    CGImageDestinationAddImage(destination, image, options)
                }
            }
            progressCallback?(index + 1, attributes.count + 1)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.destinationNotFinalized
        }

        let result: Data
        if try isHEICImage(at: attributes[0].url) {
            result = try copyImageDataWithMetadata(
                mutableData as Data,
                metadata: metadata,
                destinationType: destinationType
            )
        } else {
            result = mutableData as Data
        }

        progressCallback?(attributes.count + 1, attributes.count + 1)
        return result
    }

    private func copyImageDataWithMetadata(
        _ data: Data,
        metadata: CGImageMetadata,
        destinationType: CFString
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            throw ImageError.invalidImageFormat
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            destinationType,
            CGImageSourceGetCount(source),
            nil
        ) else {
            throw ImageError.destinationNotCreated
        }

        let options = [kCGImageDestinationMetadata: metadata] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination,
            source,
            options,
            &error
        ) else {
            error?.release()
            throw ImageError.destinationNotFinalized
        }

        return mutableData as Data
    }

    private func copyExistingHEIC(
        from attributes: [ImageAttributes],
        metadata: CGImageMetadata,
        destinationType: CFString
    ) throws -> Data? {
        guard let first = attributes.first,
              attributes.allSatisfy({ $0.url == first.url }),
              attributes.enumerated().allSatisfy({
                  $0.element.sourceIndex == $0.offset
              }),
              try isHEICImage(at: first.url),
              let source = CGImageSourceCreateWithURL(
                  first.url as CFURL,
                  nil
              ),
              CGImageSourceGetCount(source) == attributes.count else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            destinationType,
            attributes.count,
            nil
        ) else {
            throw ImageError.destinationNotCreated
        }

        let options = [kCGImageDestinationMetadata: metadata] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination,
            source,
            options,
            &error
        ) else {
            error?.release()
            throw ImageError.destinationNotFinalized
        }

        return mutableData as Data
    }

    private func isHEICImage(at url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String? else {
            throw ImageError.invalidImageFormat
        }

        return type == "public.heic" || type == "public.heif"
    }

    private func convertImage(_ image: NSImage) throws -> CGImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageError.imageNotConverted
        }
        return cgImage
    }

    private var lossyCompressionQuality: Double {
        let lossless = 1.0
        let lossy = 0.9999999

        // This works around a bug in macOS 14.4.1 and later where encoding HEIC on Intel devices fails.
        //
        // See https://github.com/rlxone/Equinox/pull/69
        #if arch(x86_64)
        if #unavailable(macOS 14.4.1) {
            return lossless
        }

        if #unavailable(macOS 15) {
            return lossy
        }

        #else
        // Fallthrough

        #endif

        return lossless
    }
}

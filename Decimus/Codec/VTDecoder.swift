import Foundation
import VideoToolbox
import AVFoundation
import CoreImage
import os

/// Provides hardware accelerated decoding.
class VTDecoder {
    typealias DecodedFrameCallback = (CMSampleBuffer) -> Void
    private static let logger = DecimusLogger(VTDecoder.self)

    // Members.
    private var currentFormat: CMFormatDescription?
    private var session: VTDecompressionSession?
    private let callback: DecodedFrameCallback

    /// Stored codec config. Can be updated.
    private var config: VideoCodecConfig

    init(config: VideoCodecConfig, callback: @escaping DecodedFrameCallback) {
        self.config = config
        self.callback = callback
    }

    deinit {
        guard let session = self.session else { return }
        let flush = VTDecompressionSessionWaitForAsynchronousFrames(session)
        if flush != .zero {
            Self.logger.warning("VTDecoder failed to flush frames: \(flush)", alert: true)
        }
        VTDecompressionSessionInvalidate(session)
    }

    /// Write a new frame to the decoder.
    func write(_ sample: CMSampleBuffer) throws {
        guard let format = sample.formatDescription else {
            throw "Sample missing format"
        }

        // Make the decoder if not already.
        if session == nil {
            session = try makeDecoder(format: format)
        }

        // Pass sample to decoder.
        var inputFlags: VTDecodeFrameFlags = .init()
        inputFlags.insert(._EnableAsynchronousDecompression)
        var outputFlags: VTDecodeInfoFlags = .init()
        let decodeError = VTDecompressionSessionDecodeFrame(session!,
                                                            sampleBuffer: sample,
                                                            flags: inputFlags,
                                                            infoFlagsOut: &outputFlags,
                                                            outputHandler: self.frameCallback)

        switch decodeError {
        case kVTFormatDescriptionChangeNotSupportedErr:
            // We need to recreate the decoder because of a format change.
            Self.logger.info("Recreating due to format change")
            session = try makeDecoder(format: format)
            try write(sample)
        case .zero:
            break
        default:
            throw OSStatusError(error: decodeError, message: "Failed to decode frame")
        }
    }

    /// Makes a new decoder for the given format.
    private func makeDecoder(format: CMFormatDescription) throws -> VTDecompressionSession {
        // Output format properties.
        var outputFormat: [String: Any] = [:]
        let targetFormat: OSType?
        switch format.mediaSubType {
        case .h264:
            targetFormat = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        default:
            targetFormat = nil
        }

        if let targetFormat = targetFormat {
            if CVIsCompressedPixelFormatAvailable(targetFormat) {
                outputFormat[kCVPixelBufferPixelFormatTypeKey as String] = targetFormat
            }
        }

        // Create the session.
        var session: VTDecompressionSession?
        let error = VTDecompressionSessionCreate(allocator: nil,
                                                 formatDescription: format,
                                                 decoderSpecification: nil,
                                                 imageBufferAttributes: outputFormat as CFDictionary,
                                                 outputCallback: nil,
                                                 decompressionSessionOut: &session)
        guard error == .zero else {
            throw OSStatusError(error: error, message: "Failed to create VTDecompressionSession")
        }
        self.currentFormat = format

        // Configure for realtime.
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        return session!
    }

    func frameCallback(status: OSStatus,
                       flags: VTDecodeInfoFlags,
                       image: CVImageBuffer?,
                       presentation: CMTime,
                       duration: CMTime) {
        // Check status code.
        guard status == .zero else { Self.logger.error("Bad decode: \(status)"); return }

        // Fire callback with the decoded image.
        guard let image = image else { Self.logger.error("Missing image"); return }
        do {
            let created: CMVideoFormatDescription = try .init(imageBuffer: image)
            let sample: CMSampleBuffer = try .init(imageBuffer: image,
                                                   formatDescription: created,
                                                   sampleTiming: .init(duration: duration,
                                                                       presentationTimeStamp: presentation,
                                                                       decodeTimeStamp: .invalid))
            callback(sample)
        } catch {
            Self.logger.error("Couldn't create CMSampleBuffer: \(error)")
        }
    }
}

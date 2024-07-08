import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation
import os

protocol VideoEncoder {
    typealias EncodedCallback = (CMTime, CMTime, UnsafeRawBufferPointer, Bool) -> Void
    var frameRate: Float64? { get set }
    func write(sample: CMSampleBuffer, captureTime: Date) throws
    func setCallback(_ callback: @escaping EncodedCallback)
}

// swiftlint:disable type_body_length
class VTEncoder: VideoEncoder {
    enum VTEncoderError: Error {
        case unsupportedCodec(CodecType)
    }

    private static let logger = DecimusLogger(VTEncoder.self)

    var frameRate: Float64?
    private var callback: EncodedCallback?
    private let config: VideoCodecConfig
    private var encoder: VTCompressionSession?
    private let verticalMirror: Bool
    private let bufferAllocator: BufferAllocator
    private var sequenceNumber: UInt64 = 0
    private let emitStartCodes: Bool
    private let seiData: ApplicationSeiData

    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]

    private let vtCallback: VTCompressionOutputCallback = { refCon, frameRefCon, status, flags, sample in
        guard let refCon = refCon,
              let frameRefCon = frameRefCon else {
            return
        }
        let instance = Unmanaged<VTEncoder>.fromOpaque(refCon).takeUnretainedValue()
        instance.encoded(frameRefCon: frameRefCon, status: status, flags: flags, sample: sample)
    }

    // swiftlint:disable function_body_length
    init(config: VideoCodecConfig,
         verticalMirror: Bool,
         emitStartCodes: Bool = false) throws {
        self.verticalMirror = verticalMirror
        self.config = config
        self.emitStartCodes = emitStartCodes
        self.bufferAllocator = .init(1*1024*1024, hdrSize: 512)
        let allocator: CFAllocator?
        #if targetEnvironment(macCatalyst)
        allocator = self.bufferAllocator.allocator().takeUnretainedValue()
        #else
        allocator = nil
        #endif

        var compressionSession: VTCompressionSession?
        let codec: CMVideoCodecType
        switch config.codec {
        case .h264:
            self.seiData = ApplicationH264SEIs()
            codec = kCMVideoCodecType_H264
        case .hevc:
            self.seiData = ApplicationHEVCSEIs()
            codec = kCMVideoCodecType_HEVC
        default:
            throw VTEncoderError.unsupportedCodec(config.codec)
        }

        let created = VTCompressionSessionCreate(allocator: nil,
                                                 width: config.width,
                                                 height: config.height,
                                                 codecType: codec,
                                                 encoderSpecification: try Self.makeEncoderSpecification(codec: codec) as CFDictionary,
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: allocator,
                                                 outputCallback: self.vtCallback,
                                                 refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                 compressionSessionOut: &compressionSession)
        guard created == .zero,
              let compressionSession = compressionSession else {
            throw "Compression Session was nil"
        }
        self.encoder = compressionSession

        try OSStatusError.checked("Set realtime") {
            VTSessionSetProperty(compressionSession,
                                 key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue)
        }

        // swiftlint:disable switch_case_alignment
        #if !os(tvOS)
        try OSStatusError.checked("Set Profile Level") {
            return switch config.codec {
            case .h264:
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
            case .hevc:
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_HEVC_Main_AutoLevel)
            default:
                1
            }
        }
        #endif
        // swiftlint:enable switch_case_alignment

        try OSStatusError.checked("Set allow frame reordering") {
            VTSessionSetProperty(compressionSession,
                                 key: kVTCompressionPropertyKey_AllowFrameReordering,
                                 value: kCFBooleanFalse)
        }

        let bitrateKey: CFString
        switch config.bitrateType {
        case .constant:
            bitrateKey = kVTCompressionPropertyKey_ConstantBitRate
        case .average:
            bitrateKey = kVTCompressionPropertyKey_AverageBitRate
        }

        try OSStatusError.checked("Set average bitrate: \(self.config.bitrate)") {
            VTSessionSetProperty(compressionSession,
                                 key: bitrateKey,
                                 value: config.bitrate as CFNumber)
        }

        // Limit to 8 frames of bitrate over 8 frame times.
        let bitrateInBytes = Double(self.config.bitrate) / 8.0
        let eightFrameTimes: TimeInterval = (1.0 / Double(self.config.fps)) * 8.0
        let dataRateLimits: NSArray = [

            NSNumber(value: eightFrameTimes * bitrateInBytes),
            NSNumber(value: eightFrameTimes)
        ]
        try OSStatusError.checked("Set data limit") {
            VTSessionSetProperty(compressionSession,
                                 key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimits as CFArray)
        }

        try OSStatusError.checked("Set expected frame rate: \(self.config.fps)") {
            VTSessionSetProperty(compressionSession,
                                 key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: config.fps as CFNumber)
        }

        try OSStatusError.checked("Set max key frame interval: \(self.config.fps * 5)") {
            VTSessionSetProperty(compressionSession,
                                 key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: config.fps * 5 as CFNumber)
        }

        if config.codec == .hevc {
            try OSStatusError.checked("Color Primaries") {
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_ColorPrimaries,
                                     value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
            }

            try OSStatusError.checked("Transfer Function") {
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_TransferFunction,
                                     value: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
            }

            try OSStatusError.checked("YCbCrMatrix") {
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_YCbCrMatrix,
                                     value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
            }

            try OSStatusError.checked("Preserve Metadata") {
                VTSessionSetProperty(compressionSession,
                                     key: kVTCompressionPropertyKey_PreserveDynamicHDRMetadata,
                                     value: kCFBooleanTrue)
            }
        }

        try OSStatusError.checked("Prepare to encode frames") {
            VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        }
    }
    // swiftlint:enable function_body_length

    deinit {
        guard let encoder = self.encoder else { return }

        // Sync flush all pending frames.
        let flushError = VTCompressionSessionCompleteFrames(encoder,
                                                            untilPresentationTimeStamp: .init())
        if flushError != .zero {
            Self.logger.warning("Encoder failed to flush: \(flushError)", alert: true)
        }

        VTCompressionSessionInvalidate(encoder)
    }

    func write(sample: CMSampleBuffer, captureTime: Date) throws {
        guard let encoder = self.encoder else { throw "Missing encoder" }
        guard let imageBuffer = sample.imageBuffer else { throw "Missing image" }
        let presentation = sample.presentationTimeStamp
        let captureTimeCM = CMTime(seconds: captureTime.timeIntervalSinceReferenceDate,
                                   preferredTimescale: presentation.timescale)
        let time = Unmanaged.passRetained(NSValue(time: captureTimeCM)).toOpaque()
        try OSStatusError.checked("Encode") {
            VTCompressionSessionEncodeFrame(encoder,
                                            imageBuffer: imageBuffer,
                                            presentationTimeStamp: presentation,
                                            duration: .invalid,
                                            frameProperties: nil,
                                            sourceFrameRefcon: time,
                                            infoFlagsOut: nil)
        }
    }

    func setCallback(_ callback: @escaping EncodedCallback) {
        self.callback = callback
    }

    // swiftlint:disable function_body_length
    func encoded(frameRefCon: UnsafeMutableRawPointer?, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        // Check the callback data.
        guard status == .zero else {
            Self.logger.error("Encode failure: \(status)")
            return
        }
        guard !flags.contains(.frameDropped) else {
            Self.logger.warning("Encoder dropped frame")
            return
        }
        guard let sample = sample else {
            Self.logger.error("Encoded sample was empty")
            return
        }

        let buffer: CMBlockBuffer
        #if !targetEnvironment(macCatalyst)
        let bufferSize = sample.dataBuffer!.dataLength
        bufferAllocator.iosDeallocBuffer(nil) // SAH - just resets pointers
        guard let bufferPtr = bufferAllocator.iosAllocBuffer(bufferSize) else {
            Self.logger.error("Failed to allocate ios buffer")
            return
        }
        let rangedBufferPtr = UnsafeMutableRawBufferPointer(start: bufferPtr, count: bufferSize)
        do {
            buffer = try .init(buffer: rangedBufferPtr, deallocator: { _, _ in })
            try sample.dataBuffer!.copyDataBytes(to: rangedBufferPtr)
        } catch {
            Self.logger.error("Failed to copy data buffer: \(error.localizedDescription)")
            return
        }
        #else
        buffer  = sample.dataBuffer!
        #endif

        // Increment frame sequence number
        // Append Timestamp SEI to buffer
        self.sequenceNumber += 1
        let fps = UInt8(self.frameRate ?? Float64(self.config.fps))
        let timestamp = sample.presentationTimeStamp
        prependTimestampSEI(timestamp: timestamp,
                            sequenceNumber: self.sequenceNumber,
                            fps: fps,
                            bufferAllocator: bufferAllocator)

        // Append age related timestamp.
        guard let frameRefCon = frameRefCon else {
            fatalError("Missing frame ref con?")
        }
        let captureTime = Unmanaged<NSValue>.fromOpaque(frameRefCon).takeRetainedValue().timeValue
        prependAgeSEI(timestamp: captureTime,
                      bufferAllocator: bufferAllocator)

        // Append Orientation SEI to buffer
        #if !targetEnvironment(macCatalyst) && !os(tvOS)
        do {
            try prependOrientationSEI(orientation: UIDevice.current.orientation.videoOrientation,
                                      verticalMirror: verticalMirror,
                                      bufferAllocator: bufferAllocator)
        } catch {
            Self.logger.error("Failed to prepend orientation SEI: \(error.localizedDescription)")
        }
        #endif

        // Prepend format data.
        let idr = sample.isIDR()
        if idr {
            // SPS + PPS.
            guard let parameterSets = try? handleParameterSets(sample: sample) else {
                Self.logger.error("Failed to handle parameter sets")
                return
            }

            // append SPS/PPS to beginning of buffer
            let totalSize = parameterSets.reduce(0) { current, set in
                current + set.count + self.startCode.count
            }
            guard let parameterDestinationAddress = bufferAllocator.allocateBufferHeader(totalSize) else {
                Self.logger.error("Couldn't allocate parameters buffer")
                return
            }
            let parameterDestination = UnsafeMutableRawBufferPointer(start: parameterDestinationAddress, count: totalSize)

            var offset = 0
            for set in parameterSets {
                // Copy either start code or UInt32 length.
                if self.emitStartCodes {
                    self.startCode.withUnsafeBytes {
                        parameterDestination.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
                        offset += $0.count
                    }
                } else {
                    let length = UInt32(set.count).bigEndian
                    parameterDestination.storeBytes(of: length, toByteOffset: offset, as: UInt32.self)
                    offset += MemoryLayout<UInt32>.size
                }

                // Copy the parameter data.
                let dest = parameterDestination.baseAddress!.advanced(by: offset)
                let destBuffer = UnsafeMutableRawBufferPointer(start: dest, count: parameterDestination.count - offset)
                destBuffer.copyMemory(from: set)
                offset += set.count
            }
        }

        var offset = 0
        if self.emitStartCodes {
            // Replace buffer data with start code.
            while offset < buffer.dataLength - startCode.count {
                do {
                    try buffer.withUnsafeMutableBytes(atOffset: offset) {
                        // Get the length.
                        let naluLength = $0.loadUnaligned(as: UInt32.self).byteSwapped

                        // Replace with start code.
                        $0.copyBytes(from: self.startCode)

                        // Move to next NALU.
                        offset += startCode.count + Int(naluLength)
                    }
                } catch {
                    Self.logger.error("Failed to get byte pointer: \(error.localizedDescription)")
                    return
                }
            }
        }

        // Callback the full buffer.
        var fullEncodedRawPtr: UnsafeMutableRawPointer?
        var fullEncodedBufferLength: Int = 0
        bufferAllocator.retrieveFullBufferPointer(&fullEncodedRawPtr, len: &fullEncodedBufferLength)
        let fullEncodedBuffer = UnsafeRawBufferPointer(start: fullEncodedRawPtr, count: fullEncodedBufferLength)
        if self.emitStartCodes {
            assert(fullEncodedBuffer.starts(with: self.startCode))
        }
        if let callback = self.callback {
            callback(timestamp, captureTime, fullEncodedBuffer, idr)
        } else {
            Self.logger.warning("Received encoded frame but consumer callback unset")
        }
    }
    // swiftlint:enable function_body_length

    /// Returns the parameter sets contained within the sample's format, if any.
    /// - Parameter sample The sample to extract parameter sets from.
    /// - Returns Array of buffer pointers referencing the data. This is only safe to use during the lifetime of sample.
    private func handleParameterSets(sample: CMSampleBuffer) throws -> [UnsafeRawBufferPointer] {
        // Get number of parameter sets.
        var sets: Int = 0
        try OSStatusError.checked("Get number of SPS/PPS") {
            switch self.config.codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            default:
                1
            }
        }

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafeRawBufferPointer] = []
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            try OSStatusError.checked("Get SPS/PPS data") {
                switch self.config.codec {
                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                case .hevc:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                default:
                    1
                }
            }
            guard naluSizeOut == startCode.count else { throw "Unexpected start code length?" }
            parameterSetPointers.append(.init(start: parameterSet!, count: parameterSize))
        }
        return parameterSetPointers
    }

    private func prependTimestampSEI(timestamp: CMTime,
                                     sequenceNumber: UInt64,
                                     fps: UInt8,
                                     bufferAllocator: BufferAllocator) {
        let bytes = TimestampSei(timestamp: timestamp, sequenceNumber: sequenceNumber, fps: fps).getBytes(self.seiData, startCode: self.emitStartCodes)
        guard let timestampPtr = bufferAllocator.allocateBufferHeader(bytes.count) else {
            Self.logger.error("Couldn't allocate timestamp buffer")
            return
        }

        // Copy to buffer.
        bytes.copyBytes(to: .init(start: timestampPtr, count: bytes.count))
    }

    private func prependAgeSEI(timestamp: CMTime,
                               bufferAllocator: BufferAllocator) {
        let bytes = AgeSei(timestamp: timestamp).getBytes(self.seiData, startCode: self.emitStartCodes)
        guard let timestampPtr = bufferAllocator.allocateBufferHeader(bytes.count) else {
            Self.logger.error("Couldn't allocate age buffer")
            return
        }

        // Copy to buffer.
        bytes.copyBytes(to: .init(start: timestampPtr, count: bytes.count))
    }

    private func prependOrientationSEI(orientation: DecimusVideoRotation,
                                       verticalMirror: Bool,
                                       bufferAllocator: BufferAllocator) throws {
        let bytes = OrientationSei(orientation: orientation, verticalMirror: verticalMirror).getBytes(self.seiData, startCode: self.emitStartCodes)
        guard let orientationPtr = bufferAllocator.allocateBufferHeader(bytes.count) else {
            throw "Failed to allocate orientation header"
        }
        let orientationBufferPtr = UnsafeMutableRawBufferPointer(start: orientationPtr, count: bytes.count)
        bytes.copyBytes(to: orientationBufferPtr)
    }

    private func makeBuffer(totalLength: Int) throws -> CMBlockBuffer {
        var buffer: CMBlockBuffer?
        try OSStatusError.checked("Create memory block") {
            CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                               memoryBlock: nil,
                                               blockLength: totalLength,
                                               blockAllocator: nil,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: totalLength,
                                               flags: 0,
                                               blockBufferOut: &buffer)
        }
        try OSStatusError.checked("Assure memory block") {
            CMBlockBufferAssureBlockMemory(buffer!)
        }
        return buffer!
    }

    /// Try to build an encoder specification dictionary.
    /// Attempts to retrieve the info for a HW encoder, but failing that, defaults to LowLatency.
    private static func makeEncoderSpecification(codec: CMVideoCodecType) throws -> [CFString: Any] {
        // We want low latency mode.
        let defaultSpec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ] as [CFString: Any]

        // Try and get available encoders.
        var availableEncodersPtr: CFArray?
        try OSStatusError.checked("Fetch Encoders") {
            VTCopyVideoEncoderList(nil, &availableEncodersPtr)
        }
        guard let availableEncoders = availableEncodersPtr as? [[CFString: Any]] else {
            Self.logger.warning("Unable to get available encoders, fallback to default spec")
            return defaultSpec
        }

        // Get all matching encoders for this codec.
        let codecEncoders = availableEncoders.filter {
            guard let encoderCodec = $0[kVTVideoEncoderList_CodecType] as? CMVideoCodecType else { return false }
            return encoderCodec == codec
        }

        // Try and find an available hardware encoder.
        let accelerated = codecEncoders.filter {
            Self.logger.debug("Available encoder: \($0)")
            guard let encoderCodec = $0[kVTVideoEncoderList_CodecType] as? CMVideoCodecType else { return false }
            let isHardwareAccelerated = $0[kVTVideoEncoderList_IsHardwareAccelerated] != nil
            return encoderCodec == codec && isHardwareAccelerated
        }

        // No available hardwared encoders, return default.
        guard let selected = accelerated.first else { return defaultSpec }

        // If we got multiple, log.
        if accelerated.count > 1 {
            Self.logger.info("Got multiple matching accelerated encoders")
            for encoderSpec in accelerated {
                Self.logger.debug("\(encoderSpec)")
            }
        }

        // Ensure we can fetch the ID of the target encoder.
        guard let selectedId = selected[kVTVideoEncoderList_EncoderID] else {
            Self.logger.warning("Failed to fetch ID for selected HW encoder: \(selected)")
            return defaultSpec
        }

        Self.logger.info("Requesting specific encoder: \(selected)")
        return [
            kVTVideoEncoderSpecification_EncoderID: selectedId
        ]
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}

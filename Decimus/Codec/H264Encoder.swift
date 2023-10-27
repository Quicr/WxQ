import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation
import os

class H264Encoder {
    typealias EncodedCallback = (UnsafeRawBufferPointer, Bool) -> Void

    private static let logger = DecimusLogger(H264Encoder.self)

    private let callback: EncodedCallback
    private let encoder: VTCompressionSession
    private let verticalMirror: Bool
    private let bufferAllocator: BufferAllocator
    private var sequenceNumber : Int64 = 0

    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]
    
    private let timestampSEIBytes: [UInt8] = [ // total 44
        // Start Code.
        0x00, 0x00, 0x00, 0x01, // 0x28 - size
        // SEI NALU type,
        0x06,
        // Payload type - user_data_unregistered (5)
        0x05,
        // Payload size
        0x25,
        // UUID (User Data Unregistered)
        0x2C, 0xA2, 0xDE, 0x09, 0xB5, 0x17, 0x47, 0xDC,
        0xBB, 0x55, 0xA4, 0xFE, 0x7F, 0xC2, 0xFC, 0x4E,
        // Application specific ID
        0x02, // Time ms --- offset 24 bytes from beginning
        // Time Value Int64
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Time timescale Int32
        0x00, 0x00, 0x00, 0x00,
        // Sequence number
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Stop bit?
        0x80
    ]

    init(config: VideoCodecConfig, verticalMirror: Bool, callback: @escaping EncodedCallback) throws {
        self.verticalMirror = verticalMirror
        self.callback = callback
        self.bufferAllocator = .init(1*1024*1024, hdrSize: 512)
        let allocator: CFAllocator?
        #if targetEnvironment(macCatalyst)
        allocator = self.bufferAllocator.allocator().takeUnretainedValue()
        #else
        allocator = nil
        #endif

        var compressionSession: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: nil,
                                                 width: config.width,
                                                 height: config.height,
                                                 codecType: kCMVideoCodecType_H264,
                                                 encoderSpecification: Self.makeEncoderSpecification(),
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: allocator,
                                                 outputCallback: nil,
                                                 refcon: nil,
                                                 compressionSessionOut: &compressionSession)
        guard created == .zero,
              let compressionSession = compressionSession else {
                  throw "Compression Session was nil"
              }
        self.encoder = compressionSession

        try OSStatusError.checked("Set realtime") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue)
        }

        try OSStatusError.checked("Set Constrained High Autolevel") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        }

        try OSStatusError.checked("Set allow frame reordering") {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        }

        try OSStatusError.checked("Set average bitrate: \(config.bitrate)") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: config.bitrate as CFNumber)
        }

        try OSStatusError.checked("Set expected frame rate: \(config.fps)") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: config.fps as CFNumber)
        }

        try OSStatusError.checked("Set max key frame interval: \(config.fps * 5)") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: config.fps * 5 as CFNumber)
        }

        try OSStatusError.checked("Prepare to encode frames") {
            VTCompressionSessionPrepareToEncodeFrames(encoder)
        }
    }

    deinit {
        // Sync flush all pending frames.
        let flushError = VTCompressionSessionCompleteFrames(encoder,
                                                            untilPresentationTimeStamp: .init())
        if flushError != .zero {
            Self.logger.error("H264 Encoder failed to flush", alert: true)
        }

        VTCompressionSessionInvalidate(encoder)
    }

    func write(sample: CMSampleBuffer) throws {
        guard let imageBuffer = sample.imageBuffer else { throw "Missing image" }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        try OSStatusError.checked("Encode") {
            VTCompressionSessionEncodeFrame(self.encoder,
                                            imageBuffer: imageBuffer,
                                            presentationTimeStamp: timestamp,
                                            duration: .invalid,
                                            frameProperties: nil,
                                            infoFlagsOut: nil,
                                            outputHandler: self.encoded)
        }
    }

    func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
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
            fatalError()
        }
        let rangedBufferPtr = UnsafeMutableRawBufferPointer(start: bufferPtr, count: bufferSize)
        buffer = try! .init(buffer: rangedBufferPtr, deallocator: { _, _ in })
        try! sample.dataBuffer!.copyDataBytes(to: rangedBufferPtr)
        #else
        buffer  = sample.dataBuffer!
        #endif
        
        // Increment frame sequence number
        // Append Timestamp SEI to buffer
        self.sequenceNumber += 1
        prependTimestampSEI(timestamp: sample.presentationTimeStamp,
                            sequenceNumber: self.sequenceNumber,
                            bufferAllocator: bufferAllocator)

        // Append Orientation SEI to buffer
        #if !targetEnvironment(macCatalyst)
        prependOrientationSEI(orientation: UIDevice.current.orientation.videoOrientation,
                              verticalMirror: verticalMirror,
                              bufferAllocator: bufferAllocator)
        #endif

        // Annex B time.
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        guard let sampleAttachments = attachments[0] as? NSDictionary else { fatalError("Failed to get attachements") }
        let key = kCMSampleAttachmentKey_NotSync as NSString
        let foundAttachment = sampleAttachments[key] as? Bool?
        let idr = !(foundAttachment != nil && foundAttachment == true)

        if idr {
            // SPS + PPS.
            guard var parameterSets = try? handleParameterSets(sample: sample) else {
                Self.logger.error("Failed to handle parameter sets")
                return
            }

            // append SPS/PPS to beginning of buffer
            parameterSets.withUnsafeMutableBytes {
                guard let parameterPtr = bufferAllocator.allocateBufferHeader($0.count) else {
                    Self.logger.error("Couldn't allocate parameters buffer")
                    return
                }
                // already Annex-B
                memcpy(parameterPtr, $0.baseAddress!, $0.count)
                assert($0.starts(with: self.startCode))
            }
        }

        var offset = 0
        while offset < buffer.dataLength - startCode.count {
            guard let memory = malloc(startCode.count) else { fatalError("malloc fail") }
            var data: UnsafeMutablePointer<CChar>?
            let accessError = CMBlockBufferAccessDataBytes(buffer,
                                                           atOffset: offset,
                                                           length: startCode.count,
                                                           temporaryBlock: memory,
                                                           returnedPointerOut: &data)
            guard accessError == .zero else { fatalError("Bad access: \(accessError)") }

            var naluLength: UInt32 = 0
            memcpy(&naluLength, data, startCode.count)
            free(memory)
            naluLength = CFSwapInt32BigToHost(naluLength)

            // Replace with start code.
            CMBlockBufferReplaceDataBytes(with: startCode,
                                          blockBuffer: buffer,
                                          offsetIntoDestination: offset,
                                          dataLength: startCode.count)
            assert(try! buffer.dataBytes().starts(with: self.startCode))

            // Carry on.
            offset += startCode.count + Int(naluLength)
        }
        
        var fullEncodedRawPtr: UnsafeMutableRawPointer?
        var fullEncodedBufferLength: Int = 0
        bufferAllocator.retrieveFullBufferPointer(&fullEncodedRawPtr, len: &fullEncodedBufferLength)
        let fullEncodedBuffer = UnsafeRawBufferPointer(start: fullEncodedRawPtr, count: fullEncodedBufferLength)
        assert(fullEncodedBuffer.starts(with: self.startCode))
        callback(fullEncodedBuffer, idr)
    }
    
    func handleParameterSets(sample: CMSampleBuffer) throws -> Data {
        // Get number of parameter sets.
        var sets: Int = 0
        let format = CMSampleBufferGetFormatDescription(sample)
        try OSStatusError.checked("Get number of SPS/PPS") {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                               parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &sets,
                                                               nalUnitHeaderLengthOut: nil)
        }

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafePointer<UInt8>] = .init()
        var parameterSetLengths: [Int] = .init()
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            try OSStatusError.checked("Get SPS/PPS data") {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                                   parameterSetIndex: parameterSetIndex,
                                                                   parameterSetPointerOut: &parameterSet,
                                                                   parameterSetSizeOut: &parameterSize,
                                                                   parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: &naluSizeOut)
            }
            guard naluSizeOut == startCode.count else { throw "Unexpected start code length?" }
            parameterSetPointers.append(parameterSet!)
            parameterSetLengths.append(parameterSize)
        }

        // Compute total ANNEX B parameter set size.
        var totalLength = startCode.count * sets
        totalLength += parameterSetLengths.reduce(0, { running, element in running + element })

        // Make a block buffer for PPS/SPS.
        let buffer = try makeBuffer(totalLength: totalLength)

        var offset = 0
        for parameterSetIndex in 0...sets-1 {
            try OSStatusError.checked("Set SPS/PPS start code") {
                CMBlockBufferReplaceDataBytes(with: startCode,
                                              blockBuffer: buffer,
                                              offsetIntoDestination: offset,
                                              dataLength: startCode.count)
            }
            offset += startCode.count
            try OSStatusError.checked("Copy SPS/PPS data") {
                CMBlockBufferReplaceDataBytes(with: parameterSetPointers[parameterSetIndex],
                                              blockBuffer: buffer,
                                              offsetIntoDestination: offset,
                                              dataLength: parameterSetLengths[parameterSetIndex])
            }
            offset += parameterSetLengths[parameterSetIndex]
        }

        // Return as a sample for easy callback.
        return try makeParameterSampleBuffer(sample: sample, buffer: buffer, totalLength: totalLength)
    }
    
    private func prependTimestampSEI(timestamp: CMTime, sequenceNumber: Int64, bufferAllocator: BufferAllocator) {
        let timestampPtr = bufferAllocator.allocateBufferHeader(timestampSEIBytes.count)
        timestampSEIBytes.withUnsafeBytes { buffer in
            guard let pointer = timestampPtr else { return }
            // convert time fields to network byte order...

            var networkTimeValue = CFSwapInt64HostToBig(UInt64(timestamp.value))
            var networkTimeScale = CFSwapInt32HostToBig(UInt32(timestamp.timescale))
            var seq = CFSwapInt64HostToBig(UInt64(sequenceNumber))
            // copy to buffer
            memcpy(pointer.advanced(by: 0),  buffer.baseAddress!, buffer.count)
            memcpy(pointer.advanced(by: 24), &networkTimeValue, MemoryLayout<Int64>.size)
            memcpy(pointer.advanced(by: 32), &networkTimeScale, MemoryLayout<Int32>.size)
            memcpy(pointer.advanced(by: 36), &seq, MemoryLayout<Int64>.size)
        }
    }
    
    private func prependOrientationSEI(orientation: AVCaptureVideoOrientation,
                                    verticalMirror: Bool, bufferAllocator: BufferAllocator)  {
        let bytes: [UInt8] = [
            // Start Code.
            0x00, 0x00, 0x00, 0x01,
            // SEI NALU type,
            0x06,
            // Display orientation
            0x2f,
            // Payload length
            0x02,
            // Orientation payload.
            UInt8(orientation.rawValue),
            // Device position.
            verticalMirror ? 0x01 : 0x00,
            // Stop bit
            0x80
        ]

        guard let orientationPtr = bufferAllocator.allocateBufferHeader(bytes.count) else { fatalError() }
        let orientationBufferPtr = UnsafeMutableRawBufferPointer(start: orientationPtr, count: bytes.count)
        bytes.copyBytes(to: orientationBufferPtr)
        assert(orientationBufferPtr.starts(with: bytes))
    }
    
    /*

    private func makeOrientationSEI(orientation: AVCaptureVideoOrientation,
                                    verticalMirror: Bool) throws -> CMSampleBuffer {
        let bytes: [UInt8] = [
            // Start Code.
            0x00, 0x00, 0x00, 0x01,

            // SEI NALU type,
            0x06,

            // Display orientation
            0x2f, 0x02,

            // Orientation payload.
            UInt8(orientation.rawValue),

            // Device position.
            verticalMirror ? 0x01 : 0x00,

            // Stop.
            0x80
        ]

        let memBlock = malloc(bytes.count)
        bytes.withUnsafeBytes { buffer in
            _ = memcpy(memBlock, buffer.baseAddress, bytes.count)
        }

        var block: CMBlockBuffer?
        try OSStatusError.checked("Create SEI memory block") {
            CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                               memoryBlock: memBlock,
                                               blockLength: bytes.count,
                                               blockAllocator: nil,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: bytes.count,
                                               flags: 0,
                                               blockBufferOut: &block)
        }
        return try .init(dataBuffer: block,
                         formatDescription: nil,
                         numSamples: 1,
                         sampleTimings: [],
                         sampleSizes: [bytes.count])
    }
     */

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

    private func makeParameterSampleBuffer(sample: CMSampleBuffer,
                                           buffer: CMBlockBuffer,
                                           totalLength: Int) throws -> Data {
        var time: CMSampleTimingInfo = try sample.sampleTimingInfo(at: 0)
        var parameterSample: CMSampleBuffer?
        var length = totalLength
        try OSStatusError.checked("Create SPS/PPS Buffer") {
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                      dataBuffer: buffer,
                                      formatDescription: nil,
                                      sampleCount: 1,
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &time,
                                      sampleSizeEntryCount: 1,
                                      sampleSizeArray: &length,
                                      sampleBufferOut: &parameterSample)
        }
        return try parameterSample!.dataBuffer!.dataBytes()
    }

    /// Try to build an encoder specification dictionary.
    /// Attempts to retrieve the info for a HW encoder, but failing that, defaults to LowLatency.
    private static func makeEncoderSpecification() -> CFDictionary {
        var availableEncodersPtr: CFArray?
        VTCopyVideoEncoderList(nil, &availableEncodersPtr)

        let defaultSpec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary

        guard let availableEncoders = availableEncodersPtr as? [[CFString: Any]] else {
            return defaultSpec
        }

        guard let hwEncoder = availableEncoders.first(where: {
            guard let name = $0[kVTVideoEncoderList_CodecType] as? CMVideoCodecType else { return false }
            let isHardwareAccelerated = $0[kVTVideoEncoderList_IsHardwareAccelerated] != nil
            return name == kCMVideoCodecType_H264 && isHardwareAccelerated
        }) else {
            return defaultSpec
        }

        guard let hwEncoderID = hwEncoder[kVTVideoEncoderList_EncoderID] else {
            return defaultSpec
        }

        return [
            kVTVideoEncoderSpecification_EncoderID: hwEncoderID
        ] as CFDictionary
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}

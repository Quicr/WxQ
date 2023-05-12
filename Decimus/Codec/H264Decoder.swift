import Foundation
import VideoToolbox
import AVFoundation
import CoreImage

/// Provides hardware accelerated H264 decoding.
class H264Decoder: SampleDecoder {

    // H264 constants.
    private let spsType: UInt8 = 7
    private let ppsType: UInt8 = 8
    private let startCodeLength = 4
    private let pFrame = 1
    private let idr = 5
    private let sei = 6

    // Members.
    private var currentFormat: CMFormatDescription?
    private var session: VTDecompressionSession?
    internal var callback: DecodedSampleCallback?
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool = false

    /// Stored codec config. Can be updated.
    private var config: VideoCodecConfig

    init(config: VideoCodecConfig) {
        self.config = config
    }

    deinit {
        guard let session = self.session else { return }
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    func registerCallback(callback: @escaping DecodedSampleCallback) {
        self.callback = callback
    }

    /// Write a new frame to the decoder.
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        // Get NALU type.
        var type = data[startCodeLength] & 0x1F

        // If we don't know the format yet, skip anything except SPS.
        guard self.currentFormat != nil || type == spsType else { return }

        // Extract SPS/PPS if available.
        let paramOutput = checkParameterSets(data: data, length: data.count)
        let offset = paramOutput.0
        let newFormat = paramOutput.1

        // There might not be any more data left.
        guard offset < data.count else { return }

        // Get indexes for all start codes.
        var startCodeIndices: [Int] = []
        for byte in offset...data.count - startCodeLength where isAtStartCode(pointer: data, startIndex: byte) {
            startCodeIndices.append(byte)
        }

        // Handle all remaining NALUs.
        for index in startCodeIndices.indices {
            // Get NALU attributes.
            let thisNaluOffset = startCodeIndices[index]
            var naluTotalLength = data.count - index
            if startCodeIndices.count < index + 1 {
                naluTotalLength = startCodeIndices[index + 1] - thisNaluOffset
            }
            let naluPtr: UnsafeMutableRawPointer = .init(mutating: data.baseAddress!.advanced(by: thisNaluOffset))

            // What type is this NALU?
            type = data[thisNaluOffset + startCodeLength] & 0x1F
            guard type == pFrame || type == idr || type == sei else { print("Unhandled NALU type: \(type)"); continue }

            // Change start code to length
            var naluDataLength = UInt32(naluTotalLength - startCodeLength).bigEndian
            memcpy(naluPtr, &naluDataLength, startCodeLength)

            // Parse any SEIs and move on.
            if type == sei {
                parseSEI(pointer: naluPtr)
                continue
            }

            // Construct a block buffer from this NALU.
            var buffer: CMBlockBuffer?
            var error = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                           memoryBlock: naluPtr,
                                                           blockLength: naluTotalLength,
                                                           blockAllocator: kCFAllocatorNull,
                                                           customBlockSource: nil,
                                                           offsetToData: 0,
                                                           dataLength: naluTotalLength,
                                                           flags: 0,
                                                           blockBufferOut: &buffer)
            guard error == .zero else { fatalError("CMBlockBufferCreateWithMemoryBlock failed: \(error)") }

            // CMTime presentation.
            let time = CMTimeMake(value: Int64(timestamp), timescale: 1000)
            var timeInfo = CMSampleTimingInfo(duration: .invalid,
                                              presentationTimeStamp: time,
                                              decodeTimeStamp: .invalid)

            // Create sample buffer.
            var sampleSize = naluTotalLength
            var sampleBuffer: CMSampleBuffer?
            error = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                         dataBuffer: buffer,
                                         dataReady: true,
                                         makeDataReadyCallback: nil,
                                         refcon: nil,
                                         formatDescription: newFormat,
                                         sampleCount: 1,
                                         sampleTimingEntryCount: 1,
                                         sampleTimingArray: &timeInfo,
                                         sampleSizeEntryCount: 1,
                                         sampleSizeArray: &sampleSize,
                                         sampleBufferOut: &sampleBuffer)
            guard error == .zero else { fatalError("CMSampleBufferCreate failed: \(error)") }

            // Set to display immediately
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self),
                                 unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))

            // Pass sample to decoder.
            var outputFlags: VTDecodeInfoFlags = .init()
            let decodeError = VTDecompressionSessionDecodeFrame(session!,
                                                                sampleBuffer: sampleBuffer!,
                                                                flags: .init(),
                                                                infoFlagsOut: &outputFlags,
                                                                outputHandler: self.frameCallback)

            switch decodeError {
            case kVTFormatDescriptionChangeNotSupportedErr:
                // We need to recreate the decoder because of a format change.
                print("H264Decoder => Recreating due to format change")
                session = makeDecoder(format: newFormat!)
                write(data: data, timestamp: timestamp)
            case .zero:
                break
            default:
                fatalError("Failed to decode frame: \(error)")
            }
        }
    }

    /// Extracts parameter sets from the given pointer, if any.
    private func checkParameterSets(data: UnsafeRawBufferPointer, length: Int) -> (Int, CMFormatDescription?) {

        // Get current frame type.
        let type = data[startCodeLength] & 0x1F

        // Is this SPS?
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == spsType {
            for byte in startCodeLength...length - 1 where isAtStartCode(pointer: data, startIndex: byte) {
                // Find the next start code.
                ppsStartCodeIndex = byte
                spsLength = ppsStartCodeIndex - startCodeLength
                break
            }

            guard ppsStartCodeIndex != 0 else { fatalError("Expected to find PPS start code after SPS") }
        }

        // Check for PPS.
        var idrStartCodeIndex: Int = 0
        let secondType = data[ppsStartCodeIndex + startCodeLength] & 0x1F
        var ppsLength: Int = 0
        guard secondType == ppsType else { return (idrStartCodeIndex, self.currentFormat) }

        // Get PPS.
        for byte in ppsStartCodeIndex + startCodeLength...length + startCodeLength where
            isAtStartCode(pointer: data, startIndex: byte) {
                idrStartCodeIndex = byte
                ppsLength = idrStartCodeIndex - spsLength - (startCodeLength * 2)
                break
        }

        if idrStartCodeIndex == 0 {
            // We made it to the end, PPS must run to end.
            ppsLength = length - ppsStartCodeIndex - startCodeLength
            idrStartCodeIndex = length
        }

        // Collate SPS & PPS.
        let pointerSPS = data.baseAddress!
            .advanced(by: startCodeLength)
            .assumingMemoryBound(to: UInt8.self)
        let pointerPPS = data.baseAddress!
            .advanced(by: ppsStartCodeIndex + startCodeLength)
            .assumingMemoryBound(to: UInt8.self)

        let parameterSetsData = [pointerSPS, pointerPPS]
        let parameterSetsSizes = [spsLength, ppsLength]

        // Create format from parameter sets.
        var format: CMFormatDescription?
        let error = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                                                        parameterSetCount: 2,
                                                                        parameterSetPointers: parameterSetsData,
                                                                        parameterSetSizes: parameterSetsSizes,
                                                                        nalUnitHeaderLength: Int32(startCodeLength),
                                                                        formatDescriptionOut: &format)
        guard error == .zero else { fatalError("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(error)") }

        // Create the decoder with the given format.
        if session == nil {
            session = makeDecoder(format: format!)
        }

        // Return new pointer index.
        return (idrStartCodeIndex, format)
    }

    /// Makes a new decoder for the given format.
    private func makeDecoder(format: CMFormatDescription) -> VTDecompressionSession {
        // Output format properties.
        var formatKeyCallbacks = kCFTypeDictionaryKeyCallBacks
        var formatValueCallbacks = kCFTypeDictionaryValueCallBacks
        let outputFormat = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &formatKeyCallbacks, &formatValueCallbacks)
        if outputFormat == nil {
            fatalError("Failed to create output format dictionary")
        }

        // Create the session.
        var session: VTDecompressionSession?
        let error = VTDecompressionSessionCreate(allocator: nil,
                                                 formatDescription: format,
                                                 decoderSpecification: nil,
                                                 imageBufferAttributes: nil,
                                                 outputCallback: nil,
                                                 decompressionSessionOut: &session)
        guard error == .zero else { fatalError("Failed to create VTDecompressionSession: \(error)") }
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
        guard let callback = callback else { fatalError("Callback not set for decoder") }

        // Check status code.
        guard status == .zero else { print("Bad decode: \(status)"); return }

        // Fire callback with the decoded image.
        let ciImage: CIImage = .init(cvImageBuffer: image!)
        callback(ciImage, presentation.value, orientation, verticalMirror)
    }

    /// Determines if the current pointer is pointing to the start of a NALU start code.
    func isAtStartCode(pointer: UnsafeRawBufferPointer, startIndex: Int) -> Bool {
        guard startIndex <= pointer.count - startCodeLength else { return false }
        return
            pointer[startIndex] == 0x00 &&
            pointer[startIndex + 1] == 0x00 &&
            pointer[startIndex + 2] == 0x00 &&
            pointer[startIndex + 3] == 0x01
    }

    private func parseSEI(pointer: UnsafeMutableRawPointer) {
        let typed: UnsafeMutablePointer<UInt8> = pointer.assumingMemoryBound(to: UInt8.self)
        guard typed[4] == sei else { fatalError("This is not an SEI") }
        let seiType = typed[5]
        switch seiType {
        case 0x2f:
            // Video orientation.
            assert(typed[6] == 2)
            orientation = .init(rawValue: .init(typed[7]))
            verticalMirror = typed[8] == 1
        default:
            print("H264Decoder => Unhandled SEI type: \(seiType)")
        }
    }
}

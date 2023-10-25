import CoreMedia
import AVFoundation

/// Utility functions for working with H264 bitstreams.
class H264Utilities {
    private static let logger = DecimusLogger(H264Utilities.self)
    
    // Bytes that precede every NALU.
    static let naluStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    
    // H264 frame type identifiers.
    enum H264Types: UInt8 {
        case pFrame = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
    }
    
    enum PacketizationError: Error {
        case missingStartCode
    }

    /// Callback type to signal the caller an SEI has been found in the bitstream.
    typealias SEICallback = (Data) -> Void
    
    /// Turns an H264 Annex B bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The H264 data. This is used in place and will be modified, so much outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known. If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    static func depacketize(_ data: Data,
                            timeInfo: inout CMSampleTimingInfo?,
                            format: inout CMFormatDescription?,
                            orientation: inout AVCaptureVideoOrientation?,
                            verticalMirror: inout Bool?) throws -> [CMSampleBuffer] {
        guard data.starts(with: naluStartCode) else {
            throw PacketizationError.missingStartCode
        }
        
        // Identify all NALUs by start code.
        assert(data.starts(with: naluStartCode))
        var ranges: [Range<Data.Index>] = []
        var naluRanges : [Range<Data.Index>] = []
        var startIndex = 0
        var index = 0
        var naluRangesIndex = 0
        while var range = data.range(of: .init(self.naluStartCode), in: startIndex..<data.count) {
            ranges.append(range)
            startIndex = range.upperBound
            if index > 0 {
                // Adjust previous NAL to run up to this one.
                let lastRange = ranges[index - 1]
                
                if naluRangesIndex > 0 {
                    if range.lowerBound <= naluRanges[naluRangesIndex - 1].upperBound  {
                        index += 1
                        continue
                    }
                }

                let type = H264Types(rawValue: data[lastRange.upperBound] & 0x1F)
                
                // RBSP types can have data that might include a "0001". So,
                // use the payload size to get the whole sub buffer.
                if type == .sei { // RBSP
                    let payloadSize = data[lastRange.upperBound + 2]
                    let upperBound = Int(payloadSize) + lastRange.lowerBound + naluStartCode.count + 3
                    naluRanges.append(.init(lastRange.lowerBound...upperBound))
  
                } else {
                    naluRanges.append(.init(lastRange.lowerBound...range.lowerBound - 1))
                }
                naluRangesIndex += 1
            }
            index += 1
        }

        // Adjust the last range to run to the end of data.
        if let lastRange = ranges.last {
            let range = Range<Data.Index>(lastRange.lowerBound...data.count-1)
            naluRanges.append(range)
        }

        // Get NALU data objects (zero copy).
        var nalus: [Data] = []
        let nsData = data as NSData
        for range in naluRanges {
            nalus.append(Data(bytesNoCopy: .init(mutating: nsData.bytes.advanced(by: range.lowerBound)),
                              count: range.count,
                              deallocator: .none))
        }
        
        
        // Finally! We have all of the nalu ranges for this frame...
        var spsData: Data?
        var ppsData: Data?
        var timeValue : UInt64 = 0
        var timeScale : UInt32 = 100000
        var sequenceNumber : UInt64 = 0

        // Create sample buffers from NALUs.
        var results: [CMSampleBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            assert(nalu.starts(with: self.naluStartCode))
            let type = H264Types(rawValue: nalu[naluStartCode.count] & 0x1F)
            
            if type == .sps {
                spsData = nalu.subdata(in: naluStartCode.count..<nalu.count)
            }
            
            if type == .pps {
                ppsData = nalu.subdata(in: naluStartCode.count..<nalu.count)
            }
            
            if type == .sei {
                var seiData = nalu.subdata(in: naluStartCode.count..<nalu.count)
                if seiData.count == 6 { // Orientation
                    if seiData[2] == 0x02 { // yep - orientation
                        orientation = .init(rawValue: .init(Int(data[3])))
                        verticalMirror = data[4] == 1
                    }
                } else if seiData.count == 41 { // timestamp?
                    if seiData[19] == 2 { // good enough - timstamp!
                        seiData.withUnsafeMutableBytes {
                            guard let ptr = $0.baseAddress else { return }
                            memcpy(&timeValue, $0.baseAddress?.advanced(by: 20), MemoryLayout<Int64>.size)
                            memcpy(&timeScale, $0.baseAddress?.advanced(by: 28), MemoryLayout<Int32>.size)
                            memcpy(&sequenceNumber, $0.baseAddress?.advanced(by: 32), MemoryLayout<Int64>.size)
                            timeValue = CFSwapInt64BigToHost(timeValue)
                            timeScale = CFSwapInt32BigToHost(timeScale)
                            sequenceNumber = CFSwapInt64BigToHost(sequenceNumber)
                            let timeStamp = CMTimeMake(value: Int64(timeValue),
                                                  timescale: Int32(timeScale))
                            timeInfo = CMSampleTimingInfo(duration: CMTimeMakeWithSeconds(1.0,      preferredTimescale: 30),
                                                              presentationTimeStamp: timeStamp,
                                                              decodeTimeStamp: .invalid)
                        }
                    } else {
                        print("Unhanbled SEI")
                    }
                }
            }
            

            if spsData != nil && ppsData != nil {
                format = try CMVideoFormatDescription(h264ParameterSets: [spsData!, ppsData!], nalUnitHeaderLength: naluStartCode.count)
            }
        
            if type == .pFrame || type == .idr {
                results.append(try depacketizeNalu(&nalu, timeInfo: timeInfo!, format: format!))
            }
        }
        return results
    }
    
    static func depacketizeNalu(_ nalu: inout Data, timeInfo: CMSampleTimingInfo, format: CMFormatDescription) throws -> CMSampleBuffer {
        guard nalu.starts(with: naluStartCode) else {
            throw PacketizationError.missingStartCode
        }

        // Change start code to length
        var naluDataLength = UInt32(nalu.count - naluStartCode.count).bigEndian
        nalu.replaceSubrange(0..<naluStartCode.count, with: &naluDataLength, count: naluStartCode.count)
        
        // Return the sample buffer.
        let blockBuffer = try CMBlockBuffer(buffer: .init(start: .init(mutating: (nalu as NSData).bytes),
                                                          count: nalu.count)) { _, _ in }
        return try .init(dataBuffer: blockBuffer,
                         formatDescription: format,
                         numSamples: 1,
                         sampleTimings: [timeInfo],
                         sampleSizes: [blockBuffer.dataLength])
    }

    func createFormat() {
        
    }
    
    /// Extracts parameter sets from the given pointer, if any.
    /// - Parameter data Encoded NALU data to check with 4 byte start code / length at the start.
    /// - Returns data read forwards to the next unprocessed start code, if any, and the extracted format, if any.
    private static func checkParameterSets(_ data: Data) throws -> (Data, CMFormatDescription?) {
        assert(data.starts(with: naluStartCode))
        
        // Is this SPS?
        let type = H264Types(rawValue: data[naluStartCode.count] & 0x1F)
        guard type == .sps else {
            return (data, nil)
        }
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == .sps {
            for byte in naluStartCode.count...data.count - 1 where data.advanced(by: byte).starts(with: naluStartCode) {
                // Found the next start code.
                ppsStartCodeIndex = byte
                spsLength = ppsStartCodeIndex
                break
            }
            
            guard ppsStartCodeIndex != 0 else {
                throw "Expected to find PPS start code after SPS"
            }
        }
        let spsRawData = data.subdata(in: naluStartCode.count..<spsLength)
        
        // Check for PPS.
        var idrStartCodeIndex: Int = 0
        var ppsRawData = data.advanced(by: ppsStartCodeIndex).advanced(by: naluStartCode.count)
        let secondType = H264Types(rawValue: ppsRawData[0] & 0x1F)
        guard secondType == .pps else {
            let offsetted = data.advanced(by: ppsStartCodeIndex)
            assert(offsetted.starts(with: self.naluStartCode))
            return (offsetted, nil)
        }
        
        // Is there another start code in this data?
        for byte in 0...ppsRawData.count where
        ppsRawData.advanced(by: byte).starts(with: naluStartCode) {
            idrStartCodeIndex = byte
            break
        }
        if idrStartCodeIndex > 0 {
            ppsRawData = ppsRawData.subdata(in: 0..<idrStartCodeIndex)
        }
        
        // Collate SPS & PPS.
        let format = try CMVideoFormatDescription(h264ParameterSets: [spsRawData, ppsRawData], nalUnitHeaderLength: naluStartCode.count)
        let offsetted = data.advanced(by: idrStartCodeIndex > 0 ? idrStartCodeIndex : data.count)
        if offsetted.count > 0 {
            assert(offsetted.starts(with: self.naluStartCode))
        }
        return (offsetted, format)
    }
}

import AVFoundation
import CoreImage
import Foundation
import os

enum CodecError: Error {
    case unsupportedCodecSet(Set<CodecType>)
    case noCodecFound(CodecType)
    case failedToCreateCodec(CodecType)
    case invalidEntry(String)
    case invalidCodecConfig(Any)
}

/// Codec type mappings.
enum CodecType: UInt8, CaseIterable {
    case unknown

    // Video
    case h264
    case av1

    // Audio
    case opus
    case xcodec

    case hevc
}

/// Abstract configuration for initialising codecs.
protocol CodecConfig {
    var codec: CodecType {get}
    var bitrate: UInt32 {get}
}

/// Unknown code type, intended to be passed to induce exceptions.
struct UnknownCodecConfig: CodecConfig {
    let codec: CodecType = .unknown
    let bitrate: UInt32 = UInt32.max
}

enum BitrateType: Codable, CaseIterable, Identifiable {
    case constant
    case average
    var id: Self { self }
}

/// Video codec specific configuration type.
struct VideoCodecConfig: CodecConfig, Equatable {
    let codec: CodecType
    let bitrate: UInt32
    let fps: UInt16
    let width: Int32
    let height: Int32
    let bitrateType: BitrateType
}

/// Audio codec specific configuration type.
struct AudioCodecConfig: CodecConfig {
    let codec: CodecType
    let bitrate: UInt32
}

class CodecFactory {
    private static let logger = DecimusLogger(CodecFactory.self)

    /// Create a codec config from a quality profile string.
    /// - Parameter qualityProfile The quality profile string provided by the manifest.
    /// - Returns The corresponding codec config.
    static func makeCodecConfig(from qualityProfile: String, bitrateType: BitrateType) -> CodecConfig {
        let elements = qualityProfile.components(separatedBy: ",")

        guard let codec = CodecType.allCases.first(where: {
            String(describing: $0) == elements[0]
        }) else {
            Self.logger.warning("Unknown codec provided from quality profile: \(qualityProfile)", alert: true)
            return UnknownCodecConfig()
        }

        var tokens: [String: String] = [:]
        for token in elements.dropFirst() {
            let subtokens = token.components(separatedBy: "=")
            tokens[subtokens[0]] = subtokens[1]
        }

        return makeCodecConfig(codec: codec, bitrateType: bitrateType, tokens: tokens)
    }

    /// Create a codec config from a dictionary of string tokens.
    /// - Parameter codec The codec type of the config.
    /// - Parameter tokens The dictionary of already parsed tokens.
    /// - Returns The corresponding codec config.
    static func makeCodecConfig(codec: CodecType, bitrateType: BitrateType, tokens: [String: String]) -> CodecConfig {
        do {
            switch codec {
            case .h264, .hevc:
                return try VideoCodecConfig(codec: codec, bitrateType: bitrateType, tokens: tokens)
            case .opus:
                return try AudioCodecConfig(codec: codec, tokens: tokens)
            default:
                return UnknownCodecConfig()
            }
        } catch {
            Self.logger.error("Failed to create codec config: \(error)")
            return UnknownCodecConfig()
        }
    }
}

private func checkEntry<T: LosslessStringConvertible>(_ tokens: [String: String], entry: String) throws -> T {
    guard let token = tokens[entry] else { throw CodecError.invalidEntry(entry) }
    guard let value = T(token) else {
        throw CodecError.invalidEntry(entry)
    }
    return value
}

/// Extension initialiser for video codec configs from token dictionary.
fileprivate extension VideoCodecConfig {
    init(codec: CodecType, bitrateType: BitrateType, tokens: [String: String]) throws {
        self.codec = codec
        self.bitrateType = bitrateType
        self.bitrate = try checkEntry(tokens, entry: "br") * 1000
        self.fps = try checkEntry(tokens, entry: "fps")
        self.width = try checkEntry(tokens, entry: "width")
        self.height = try checkEntry(tokens, entry: "height")
    }
}

/// Extension initialiser for audio codec configs from token dictionary.
fileprivate extension AudioCodecConfig {
    init(codec: CodecType, tokens: [String: String]) throws {
        self.codec = codec
        self.bitrate = try checkEntry(tokens, entry: "br") * 1000
    }
}

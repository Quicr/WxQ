import CoreMedia
import AVFoundation

class PassthroughEncoder: Encoder {

    private let callback: Encoder.EncodedSampleCallback

    init(callback: @escaping Encoder.EncodedSampleCallback) {
        self.callback = callback
    }

    func prepare() {}
    func stop() {}

    func write(sample: CMSampleBuffer) {
        callback(sample)
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation

class PreviewUIView: VideoUIView, FrameListener {
    let queue: DispatchQueue
    let device: AVCaptureDevice
    let codec: VideoCodecConfig? = nil
    let captureManager: CaptureManager

    init(device: AVCaptureDevice, captureManager: CaptureManager, frame: CGRect) {
        self.queue = .global(qos: .default)
        self.device = device
        self.captureManager = captureManager
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func onFrame(_ sampleBuffer: CMSampleBuffer, timestamp: Date) {
        DispatchQueue.main.async {
            guard let layer = self.layer as? AVSampleBufferDisplayLayer else {
                fatalError()
            }
            layer.enqueue(sampleBuffer)
        }
    }
}

#if os(macOS)
struct PreviewView: NSViewRepresentable {

    private static let logger = DecimusLogger(PreviewView.self)
    let view: PreviewUIView
    private let captureManager: CaptureManager

    init(captureManager: CaptureManager, device: AVCaptureDevice) throws {
        self.captureManager = captureManager
        self.view = PreviewUIView(device: device,
                                  captureManager: captureManager,
                                  frame: .zero)
    }

    func makeNSView(context: Context) -> PreviewUIView {
        do {
            try captureManager.addInput(self.view)
        } catch {
            Self.logger.error("Failed to add input for preview: \(error.localizedDescription)")
        }
        return view
    }

    func updateNSView(_ nsView: PreviewUIView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewUIView, coordinator: ()) {
        do {
            try nsView.captureManager.removeInput(listener: nsView)
        } catch {
            Self.logger.error("Failed to remove input for preview: \(error.localizedDescription)")
        }
    }
}
#else
struct PreviewView: UIViewRepresentable {
    private static let logger = DecimusLogger(PreviewView.self)
    let view: PreviewUIView
    private let captureManager: CaptureManager

    init(captureManager: CaptureManager, device: AVCaptureDevice) throws {
        self.captureManager = captureManager
        self.view = PreviewUIView(device: device,
                                  captureManager: captureManager,
                                  frame: .zero)
    }

    func makeUIView(context: Context) -> PreviewUIView {
        do {
            try captureManager.addInput(self.view)
        } catch {
            Self.logger.error("Failed to add input for preview: \(error.localizedDescription)")
        }
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: Self.Coordinator) {
        do {
            try uiView.captureManager.removeInput(listener: uiView)
        } catch {
            Self.logger.error("Failed to remove input for preview: \(error.localizedDescription)")
        }
    }
}
#endif

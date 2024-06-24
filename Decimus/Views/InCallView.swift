import SwiftUI
import AVFoundation
import UIKit
import os

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @State private var connecting: Bool = false
    @State private var noParticipantsDetected = false
    @State private var showPreview = true
    @State private var lastTap: Date = .now
    @State private var isShowingSubscriptions = false
    @State private var isShowingPublications = false
    var noParticipants: Bool {
        viewModel.controller?.subscriberDelegate.participants.participants.isEmpty ?? true
    }

    /// Callback when call is left.
    private let onLeave: () -> Void
    #if !os(tvOS)
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()
    #endif

    init(config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
        _viewModel = .init(wrappedValue: .init(config: config))
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                VStack {
                    Group {
                        if connecting || noParticipantsDetected {
                            // Waiting for other participants / connecting.
                            ZStack {
                                Image("RTMC-Background")
                                    .resizable()
                                    .frame(maxHeight: .infinity,
                                           alignment: .center)
                                    .cornerRadius(12)
                                    .padding([.horizontal, .bottom])
                                if connecting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                }
                            }
                        } else {
                            // Incoming videos.
                            if let controller = viewModel.controller {
                                VideoGrid(participants: controller.subscriberDelegate.participants)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                        }

                        HStack {
                            Button("Alter Subscriptions") {
                                self.isShowingSubscriptions = true
                            }
                            Button("Alter Publications") {
                                self.isShowingPublications = true
                            }
                        }
                    }
                    .sheet(isPresented: $isShowingSubscriptions) {
                        if let controller = viewModel.controller {
                            SubscriptionPopover(controller: controller)
                        }
                        Spacer()
                        Button("Done") {
                            self.isShowingSubscriptions = false
                        }
                        .padding()
                    }
                    .sheet(isPresented: $isShowingPublications) {
                        if let controller = viewModel.controller {
                            PublicationPopover(controller: controller)
                        }
                        Spacer()
                        Button("Done") {
                            self.isShowingPublications = false
                        }
                        .padding()
                    }

                    // Call controls panel.
                    CallControls(captureManager: viewModel.captureManager,
                                 engine: viewModel.engine,
                                 leaving: $leaving)
                        .disabled(leaving)
                        .padding(.bottom)
                        .frame(alignment: .top)
                } // VStack end.

                // Preview / self-view.
                // swiftlint:disable force_try
                if let capture = viewModel.captureManager,
                   let camera = try! capture.activeDevices().first,
                   showPreview {
                    let gWidth = geometry.size.width
                    let gHeight = geometry.size.height
                    let cWidth = gWidth / 7
                    let cHeight = gHeight / 7
                    let pWidth = cWidth / 10
                    let pHeight = cHeight / 10
                    try! PreviewView(captureManager: capture, device: camera)
                        .frame(maxWidth: cWidth)
                        .offset(CGSize(width: gWidth - cWidth - pWidth,
                                       height: gHeight / 2 - (cHeight * 0.75) - pHeight))
                }
                // swiftlint:enable:force_try
            }

            if leaving {
                LeaveModal(leaveAction: {
                    await viewModel.leave()
                    onLeave()
                }, cancelAction: leaving = false)
                .frame(maxWidth: 400, alignment: .center)
            }
        }
        .background(.black)
        .onChange(of: noParticipants) { _, newValue in
            noParticipantsDetected = newValue
        }
        .task {
            connecting = true
            guard await viewModel.join() else {
                await viewModel.leave()
                return onLeave()
            }
            connecting = false
        }.onTapGesture {
            // Show the preview when we tap.
            self.lastTap = .now
            withAnimation {
                self.showPreview.toggle()
            }
        }
        .task {
            // Hide the preview if we didn't tap for a while.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }

                if self.lastTap.timeIntervalSince(.now) < -5 {
                    withAnimation {
                        if self.showPreview {
                            self.showPreview = false
                        }
                    }
                }
            }
        }
        .task {
            // Check connnection status
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }

                if connecting || leaving {
                    continue
                }

                guard await viewModel.connected() else {
                    await viewModel.leave()
                    return onLeave()
                }
            }
        }
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private static let logger = DecimusLogger(InCallView.ViewModel.self)

        let engine: DecimusAudioEngine?
        private(set) var controller: CallController?
        private(set) var captureManager: CaptureManager?
        private let config: CallConfig
        private var appMetricTimer: Task<(), Error>?
        private var measurement: MeasurementRegistration<_Measurement>?
        private var submitter: MetricsSubmitter?
        private var audioCapture = false
        private var videoCapture = false

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        @AppStorage("subscriptionConfig")
        private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

        init(config: CallConfig) {
            self.config = config
            do {
                self.engine = try .init()
            } catch {
                Self.logger.critical("Failed to create AudioEngine: \(error.localizedDescription)")
                self.engine = nil
            }
            let tags: [String: String] = [
                "relay": "\(config.address):\(config.port)",
                "email": config.email,
                "conference": "\(config.conferenceID)",
                "protocol": "\(config.connectionProtocol)"
            ]

            if influxConfig.value.submit {
                let influx = InfluxMetricsSubmitter(config: influxConfig.value, tags: tags)
                submitter = influx
                let measurement = _Measurement()
                self.measurement = .init(measurement: measurement, submitter: influx)
                if influxConfig.value.realtime {
                    // Application metrics timer.
                    self.appMetricTimer = .init(priority: .utility) { [weak self] in
                        while !Task.isCancelled,
                              let self = self {
                            let usage = try cpuUsage()
                            await self.measurement?.measurement.recordCpuUsage(cpuUsage: usage, timestamp: Date.now)

                            await self.submitter?.submit()
                            try? await Task.sleep(for: .seconds(influxConfig.value.intervalSecs), tolerance: .seconds(1))
                        }
                    }
                }
            }

            do {
                self.captureManager = try .init(metricsSubmitter: submitter,
                                                granularMetrics: influxConfig.value.granular)
            } catch {
                Self.logger.error("Failed to create camera manager: \(error.localizedDescription)", alert: true)
            }

            if let captureManager = self.captureManager,
               let engine = self.engine {
                do {
                    self.controller = try .init(metricsSubmitter: submitter,
                                                captureManager: captureManager,
                                                config: subscriptionConfig.value,
                                                engine: engine,
                                                granularMetrics: influxConfig.value.granular)
                } catch {
                    Self.logger.error("CallController failed: \(error.localizedDescription)", alert: true)
                }
            }
        }

        func connected() async -> Bool {
            guard let controller = self.controller else {
                return false
            }
            if !controller.connected() {
                Self.logger.error("Connection to relay disconnected", alert: true)
                return false
            }
            return true
        }

        func join() async -> Bool {
            do {
                try await self.controller?.connect(config: config)
            } catch {
                Self.logger.error("Failed to connect to call: \(error.localizedDescription)", alert: true)
                return false
            }

            do {
                try engine?.start()
                self.audioCapture = true
            } catch {
                Self.logger.warning("Audio failure. Apple requires us to have an aggregate input AND output device", alert: true)
            }

            do {
                try captureManager?.startCapturing()
                self.videoCapture = true
            } catch {
                Self.logger.warning("Camera failure", alert: true)
            }
            return true
        }

        func leave() async {
            // Submit all pending metrics.
            await submitter?.submit()

            do {
                if self.videoCapture {
                    try captureManager?.stopCapturing()
                    self.videoCapture = false
                }
                if self.audioCapture {
                    try engine?.stop()
                    self.audioCapture = false
                }
            } catch {
                Self.logger.error("Error while stopping media: \(error)", alert: true)
            }

            do {
                try controller?.disconnect()
            } catch {
                Self.logger.error("Error while leaving call: \(error)", alert: true)
            }
        }
    }
}

// Metrics.
extension InCallView.ViewModel {
    private actor _Measurement: Measurement {
        let id = UUID()
        var name: String = "ApplicationMetrics"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        func recordCpuUsage(cpuUsage: Double, timestamp: Date?) {
            record(field: "cpuUsage", value: cpuUsage as AnyObject, timestamp: timestamp)
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(config: .init(address: "127.0.0.1",
                                 port: 5001,
                                 connectionProtocol: .QUIC)) { }
    }
}

import SwiftUI
import AVFoundation

struct SubscriptionSettingsView: View {
    static let defaultsKey = "subscriptionConfig"

    @AppStorage(Self.defaultsKey)
    private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    @StateObject private var devices = VideoDevices()
    @State private var preferredCamera: String
    private let noPreference = "None"

    init() {
        if #available(iOS 17.0, *) {
            self.preferredCamera = AVCaptureDevice.userPreferredCamera?.uniqueID ?? self.noPreference
        } else {
            self.preferredCamera = self.noPreference
        }
        self.subscriptionConfig.value.videoJitterBuffer.minDepth = self.subscriptionConfig.value.jitterDepthTime
    }

    var body: some View {
        Section("Subscription Config") {
            Form {
                VideoJitterBufferSettingsView(config: $subscriptionConfig.value.videoJitterBuffer)

                LabeledContent("Jitter Target Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterDepthTime,
                        format: .number)
                        .onChange(of: subscriptionConfig.value.jitterDepthTime) {
                            subscriptionConfig.value.videoJitterBuffer.minDepth = $0
                            subscriptionConfig.value.jitterMaxTime = $0
                        }
                }
                LabeledContent("Video Jitter Capacity (s)") {
                    TextField(
                        "Capacity (s)",
                        value: $subscriptionConfig.value.videoJitterBuffer.capacity,
                        format: .number)
                }
                HStack {
                    Text("Video Jitter - Adaptive")
                    Toggle(isOn: $subscriptionConfig.value.videoJitterBuffer.adaptive) {}
                }
                Picker("Opus Window Size (s)", selection: $subscriptionConfig.value.opusWindowSize) {
                    ForEach(OpusWindowSize.allCases) {
                        Text(String(describing: $0))
                    }
                }
                LabeledContent("Video behaviour") {
                    Picker("Video behaviour", selection: $subscriptionConfig.value.videoBehaviour) {
                        ForEach(VideoBehaviour.allCases) {
                            Text(String(describing: $0))
                        }
                    }.pickerStyle(.segmented)
                }

                LabeledContent("Encoder bitrate") {
                    Picker("Encoder bitrate", selection: $subscriptionConfig.value.bitrateType) {
                        ForEach(BitrateType.allCases) {
                            Text(String(describing: $0))
                        }
                    }.pickerStyle(.segmented)
                }

                if #available(iOS 17.0, *) {
                    Picker("Preferred Camera", selection: $preferredCamera) {
                        Text("None").tag("None")
                        ForEach(devices.cameras, id: \.uniqueID) {
                            Text($0.localizedName)
                                .tag($0.uniqueID)
                        }.onChange(of: preferredCamera) { _ in
                            guard self.preferredCamera != self.noPreference else {
                                AVCaptureDevice.userPreferredCamera = nil
                                return
                            }

                            for camera in devices.cameras where camera.uniqueID == preferredCamera {
                                AVCaptureDevice.userPreferredCamera = camera
                                break
                            }
                        }
                    }
                }

                HStack {
                    Text("Single Publication")
                    Toggle(isOn: $subscriptionConfig.value.isSingleOrderedPub) {}
                }

                HStack {
                    Text("Single Subscription")
                    Toggle(isOn: $subscriptionConfig.value.isSingleOrderedSub) {}
                }

                LabeledContent("Simulreceive") {
                    Picker("Simulreceive", selection: $subscriptionConfig.value.simulreceive) {
                        ForEach(SimulreceiveMode.allCases) {
                            if subscriptionConfig.value.videoJitterBuffer.mode == .layer && $0 != .none {
                                EmptyView()
                            } else {
                                Text(String(describing: $0))
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: subscriptionConfig.value.videoJitterBuffer.mode) {
                        if $0 == .layer && subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                    .onAppear {
                        if subscriptionConfig.value.videoJitterBuffer.mode == .layer && subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                }

                LabeledContent("Quality miss threshold (frames)") {
                    NumberView(value: self.$subscriptionConfig.value.qualityMissThreshold,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Threshold")
                }

                HStack {
                    Text("Do Pause/Resume")
                    Toggle(isOn: $subscriptionConfig.value.pauseResume) {}
                }

                LabeledContent("Pause miss threshold (frames)") {
                    NumberView(value: self.$subscriptionConfig.value.pauseMissThreshold,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Threshold")
                }
            }
            .formStyle(.columns)
        }
        Section("Reliability") {
            HStack {
                Text("Audio Publication")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.audio.publication) {}
                Text("Audio Subscription")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.audio.subscription) {}
            }
            HStack {
                Text("Video Publication")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.video.publication) {}
                Text("Video Subscription")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.video.subscription) {}
            }
        }
        Section("Security") {
            HStack {
                Text("SFrame")
                Toggle(isOn: $subscriptionConfig.value.doSFrame) {}
            }
        }
        Section("Transport") {
            TransportConfigSettings(quicCwinMinimumKiB: $subscriptionConfig.value.quicCwinMinimumKiB,
                                    timeQueueTTL: $subscriptionConfig.value.timeQueueTTL,
                                    chunkSize:
                                        $subscriptionConfig.value.chunkSize,
                                    useResetWaitCC: $subscriptionConfig.value.useResetWaitCC,
                                    useBBR:
                                        $subscriptionConfig.value.useBBR,
                                    quicrLogs: $subscriptionConfig.value.quicrLogs,
                                    enableQlog: $subscriptionConfig.value.enableQlog,
                                    quicPriorityLimit:
                                        $subscriptionConfig.value.quicPriorityLimit)
        }
    }
}

struct SubscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            SubscriptionSettingsView()
        }
    }
}

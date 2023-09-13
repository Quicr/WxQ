import SwiftUI

struct SubscriptionSettingsView: View {

    @AppStorage("subscriptionConfig")
    private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    var body: some View {
        Section("Subscription Config") {
            Form {
                HStack {
                    Text("Use Video Jitter Buffer")
                    Toggle(isOn: $subscriptionConfig.value.videoJitterBuffer) {}
                }
                LabeledContent("Jitter Target Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterDepthTime,
                        format: .number)
                }
                LabeledContent("Jitter Max Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterMaxTime,
                        format: .number)
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
                HStack {
                    Text("Voice Processing")
                    Toggle(isOn: $subscriptionConfig.value.voiceProcessing) {}
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
        Section("Transport") {
            TransportConfigSettings(quicCwinMinimumKiB: $subscriptionConfig.value.quicCwinMinimumKiB)
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

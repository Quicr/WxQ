import SwiftUI

struct PTTSettingsView: View {
    static let defaultsKey = "pttConfig"

    @AppStorage(Self.defaultsKey)
    private var pttConfig: AppStorageWrapper<PTTConfig> = .init(value: .init())

    var body: some View {
        Section("PTT") {
            Form {
                LabeledContent("Address") {
                    TextField("Address", text: self.$pttConfig.value.address, prompt: Text("localhost"))
                        .keyboardType(.URL)
                }
                HStack {
                    Text("Enable")
                    Toggle(isOn: self.$pttConfig.value.enable) {}
                }
            }
            .formStyle(.columns)
        }
    }
}

#Preview() {
    Form {
        PTTSettingsView()
    }
}

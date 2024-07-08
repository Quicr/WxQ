import SwiftUI

struct RelaySettingsView: View {
    static let defaultsKey = "relayConfig"

    @AppStorage(Self.defaultsKey)
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    var body: some View {
        Section("Relay") {
            Form {
                LabeledContent("Address") {
                    TextField("relay_address", text: $relayConfig.value.address, prompt: Text("localhost"))
                        .keyboardType(.URL)
                }

                LabeledContent("Protocol") {
                    Picker("Protocol", selection: $relayConfig.value.connectionProtocol) {
                        ForEach(ProtocolType.allCases) { prot in
                            Text(String(describing: prot)).tag(prot)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: relayConfig.value.connectionProtocol) { _, newValue in
                        relayConfig.value.port = defaultProtocolPorts[newValue] ?? relayConfig.value.port
                    }
                }

                LabeledContent("Port") {
                    NumberView(value: self.$relayConfig.value.port,
                               formatStyle: IntegerFormatStyle<UInt16>.number.grouping(.never),
                               name: "Port")
                }
            }
            .formStyle(.columns)
        }
    }
}

struct RelaySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            RelaySettingsView()
        }
    }
}

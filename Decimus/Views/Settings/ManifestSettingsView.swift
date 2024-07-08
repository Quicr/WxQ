import SwiftUI

enum URLScheme: String, CaseIterable {
    case http
    case https
}

struct ManifestSettingsView: View {
    static let defaultsKey = "manifestConfig"

    @AppStorage(Self.defaultsKey)
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    @State private var configs: [String] = []
    @State private var error: String?
    @State private var showProgressView = false

    var body: some View {
        Section("Manifest") {
            Form {
                LabeledContent("Scheme") {
                    Picker("Scheme", selection: $manifestConfig.value.scheme) {
                        ForEach(URLScheme.allCases, id: \.rawValue) { scheme in
                            Text(scheme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                LabeledContent("Address") {
                    TextField("manifest_address", text: $manifestConfig.value.url, prompt: Text("127.0.0.1"))
                        .keyboardType(.URL)
                }

                LabeledContent("Port") {
                    NumberView(value: $manifestConfig.value.port,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Port")
                }

                HStack {
                    Picker("Config", selection: $manifestConfig.value.config) {
                        ForEach(self.configs, id: \.self) { config in
                            Text(config)
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            self.configs = await self.getConfigs()
                        }
                    } label: {
                        if self.showProgressView {
                            ProgressView()
                        } else {
                            Text("Refresh")
                        }
                    }
                }
                if let error = self.error {
                    HStack {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                        Spacer()
                    }
                }
            }
            .formStyle(.columns)
        }
        .task {
            self.configs = await getConfigs()
        }
        .onChange(of: self.manifestConfig.value) {
            ManifestController.shared.setServer(config: self.manifestConfig.value)
            Task {
                self.configs = await self.getConfigs()
            }
        }
    }

    private func getConfigs() async -> [String] {
        self.showProgressView = true
        defer { self.showProgressView = false }
        do {
            let configs = try await ManifestController.shared.getConfigs()
            self.error = nil
            let sorted = configs.sorted { $0.configProfile < $1.configProfile }
            return sorted.reduce(into: [], { $0.append($1.configProfile) })
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }
}

struct ManifestSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            ManifestSettingsView()
        }
    }
}

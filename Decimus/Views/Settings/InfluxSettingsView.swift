import SwiftUI

struct InfluxSettingsView: View {

    @AppStorage("influxConfig")
    private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

    var body: some View {
        Section("Influx Connection") {
            Form {
                HStack {
                    HStack {
                        Text("Submit Metrics")
                        Toggle(isOn: $influxConfig.value.submit) {}
                    }
                    HStack {
                        Text("Granular")
                        Toggle(isOn: $influxConfig.value.granular) {}
                    }
                    HStack {
                        Text("Realtime")
                        Toggle(isOn: $influxConfig.value.realtime) {}
                    }
                }

                LabeledContent("Interval (s)") {
                    TextField(
                        "Interval (s)",
                        value: $influxConfig.value.intervalSecs,
                        format: .number)
                }

                LabeledContent("URL") {
                    TextField("URL", text: $influxConfig.value.url)
                }

                LabeledContent("Username") {
                    TextField("Username", text: $influxConfig.value.username)
                }

                LabeledContent("Password") {
                    SecureField("Password", text: $influxConfig.value.password)
                }

                LabeledContent("Bucket") {
                    TextField("Bucket", text: $influxConfig.value.bucket)
                }

                LabeledContent("Org") {
                    TextField("Org", text: $influxConfig.value.org)
                }

                LabeledContent("Token") {
                    SecureField("Token", text: $influxConfig.value.token)
                }
            }
            .formStyle(.columns)
        }
    }
}

struct InfluxSettings_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            InfluxSettingsView()
        }
    }
}

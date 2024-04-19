import SwiftUI

struct SettingsView: View {

    @State private var cancelConfirmation = false

    var body: some View {
        // Reset all.
        HStack {
            Spacer()
            let resetString = "Reset to defaults"
            Button(role: .destructive) {
                self.cancelConfirmation = true
            } label: {
                Text(resetString)
            }
            .confirmationDialog(resetString,
                                isPresented: self.$cancelConfirmation) {
                Button("Reset", role: .destructive) {
                    // Reset all settings to defaults.
                    UserDefaults.standard.removeObject(forKey: RelaySettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: ManifestSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: InfluxSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: PTTSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: SubscriptionSettingsView.defaultsKey)
                }
            }
            .buttonStyle(BorderedButtonStyle())
            .padding(.horizontal)
        }

        // Settings.
        Form {
            RelaySettingsView()
                .decimusTextStyle()

            ManifestSettingsView()
                .decimusTextStyle()

            InfluxSettingsView()
                .decimusTextStyle()

            PTTSettingsView()
                .decimusTextStyle()

            SubscriptionSettingsView()
                .decimusTextStyle()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

struct DecimusTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
        #if os(tvOS)
            .textFieldStyle(.plain)
        #else
            .textFieldStyle(.roundedBorder)
        #endif
    }
}

extension View {
    func decimusTextStyle() -> some View {
        modifier(DecimusTextFieldStyle())
    }
}

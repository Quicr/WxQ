import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    @AppStorage("email")
    private var email: String = ""

    @AppStorage("relayConfig")
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    @AppStorage("confId")
    private var confId: Int = 0

    @State private var isLoading: Bool = false
    @State private var isAllowedJoin: Bool = false
    @State private var meetings: [UInt32: String] = [:]

    @State private var callConfig = CallConfig(address: "",
                                               port: 0,
                                               connectionProtocol: .QUIC,
                                               conferenceID: 0)
    @EnvironmentObject private var errorHandler: ObservableError
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
        ManifestController.shared.setServer(config: manifestConfig.value)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Email")
                    TextField("email", text: $callConfig.email, prompt: Text("example@cisco.com"))
                        .keyboardType(.emailAddress)
                        .onChange(of: callConfig.email, perform: { value in
                            email = value
                            Task {
                                do {
                                    try await fetchManifest()
                                } catch {
                                    errorHandler.writeError("Failed to fetch manifest: \(error.localizedDescription)")
                                }
                            }

                            if !meetings.keys.contains(UInt32(confId)) {
                                confId = 1
                                callConfig.conferenceID = 1
                            }
                        })
                        .textFieldStyle(FormInputStyle())
                    if isLoading {
                        Spacer()
                        ProgressView()
                    }
                }

                if email != "" && meetings.keys.contains(UInt32(confId)) {
                    VStack(alignment: .leading) {
                        if meetings.count > 0 {
                            Text("Meeting")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                            Picker("", selection: $callConfig.conferenceID) {
                                ForEach(meetings.sorted(by: <), id: \.key) { id, meeting in
                                    Text(meeting).tag(id)
                                }
                            }
                            .onChange(of: callConfig.conferenceID) { _ in
                                confId = Int(callConfig.conferenceID)
                            }
                            .labelsHidden()
                        } else {
                            Text("No meetings")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                                .onAppear {
                                    callConfig.conferenceID = 0
                                }
                        }
                    }
                }

                if callConfig.conferenceID != 0 {
                    RadioButtonGroup("Protocol",
                                     selection: $callConfig,
                                     labels: ["UDP", "QUIC"],
                                     tags: [
                        .init(address: relayConfig.value.address,
                              port: relayConfig.value.ports[.UDP]!,
                              connectionProtocol: .UDP,
                              email: callConfig.email,
                              conferenceID: callConfig.conferenceID),
                        .init(address: relayConfig.value.address,
                              port: relayConfig.value.ports[.QUIC]!,
                              connectionProtocol: .QUIC,
                              email: callConfig.email,
                              conferenceID: callConfig.conferenceID)
                    ])

                    ActionButton("Join Meeting",
                                 font: Font.system(size: 19, weight: .semibold),
                                 disabled: !isAllowedJoin || callConfig.email == "" || callConfig.conferenceID == 0,
                                 styleConfig: buttonColour,
                                 action: join)
                    .frame(maxWidth: .infinity)
                    .font(Font.system(size: 19, weight: .semibold))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .background(.clear)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 450)
        .scrollDisabled(true)
        .onAppear {
            Task {
                do {
                    try await fetchManifest()
                } catch {
                    errorHandler.writeError("Failed to fetch manifest: \(error.localizedDescription)")
                    return
                }
                if meetings.count > 0 {
                    callConfig = CallConfig(address: relayConfig.value.address,
                                            port: relayConfig.value.ports[.QUIC]!,
                                            connectionProtocol: .QUIC,
                                            email: email,
                                            conferenceID: UInt32(confId))
                }
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                isAllowedJoin = true
            }
        }
    }

    private func fetchManifest() async throws {
        isLoading = true
        let userId = try await ManifestController.shared.getUser(email: email)
        meetings = try await ManifestController.shared.getConferences(for: userId)
        callConfig.conferenceID = UInt32(confId)
        isLoading = false
    }

    func join() {
        joinMeetingCallback(callConfig)
    }
}

struct CallSetupView: View {
    private var joinMeetingCallback: ConfigCallback
    @State private var settingsOpen: Bool = false
    @EnvironmentObject private var errorWriter: ObservableError

    init(_ onJoin: @escaping ConfigCallback) {
        UIApplication.shared.isIdleTimerDisabled = false
        joinMeetingCallback = onJoin
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Image("RTMC-Background")
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.top)
                    #if targetEnvironment(macCatalyst)
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .center)
                    #else
                    .frame(width: UIScreen.main.bounds.width,
                           height: UIScreen.main.bounds.height,
                           alignment: .center)
                    #endif

                VStack {
                    Image("RTMC-Icon")
                    Text("Real Time Media Client")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                        .padding()
                    Text("Join a meeting")
                        .font(.title)
                        .foregroundColor(.white)
                    LoginForm(joinMeetingCallback)
                        .frame(maxWidth: 350)

                    NavigationLink(destination: SettingsView()) {
                        Label("", systemImage: "gearshape").font(.title)
                    }
                    .buttonStyle(ActionButtonStyle(styleConfig: .init(background: .clear, foreground: .white),
                                                   cornerRadius: 50,
                                                   isDisabled: false))
                }

                // Show any errors.
                ErrorView()
            }
        }
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView { _ in }
            .environmentObject(ObservableError())
    }
}

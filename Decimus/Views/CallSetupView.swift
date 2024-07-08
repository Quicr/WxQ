import SwiftUI
import os
import AVKit

typealias ConfigCallback = (_ config: CallConfig) -> Void

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    private static let logger = DecimusLogger(LoginForm.self)

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
    @State private var showContinuityDevicePicker: Bool = false

    @State private var callConfig = CallConfig(address: "",
                                               port: 0,
                                               connectionProtocol: .QUIC,
                                               email: "",
                                               conferenceID: 0)
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
                                    Self.logger.error("Failed to fetch manifest: \(error.localizedDescription)")
                                }
                            }
                        })
                        .onChange(of: meetings) {
                            if meetings.count > 0 {
                                if !meetings.keys.contains(UInt32(confId)) {
                                    confId = Int(meetings.keys.sorted()[0])
                                    callConfig.conferenceID = UInt32(confId)
                                }
                            } else {
                                callConfig.conferenceID = 0
                            }
                        }
                        .textFieldStyle(FormInputStyle())
                    if isLoading {
                        Spacer()
                        ProgressView()
                    }
                }

                if email != "" {
                    VStack(alignment: .leading) {
                        if meetings.count > 0 {
                            HStack {
                                Spacer()
                                Text("Meeting")
                                    .padding(.horizontal)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            HStack {
                                Spacer()
                                Picker("", selection: $callConfig.conferenceID) {
                                    ForEach(meetings.sorted(by: <), id: \.key) { id, meeting in
                                        Text(meeting).tag(id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: callConfig.conferenceID) {
                                    confId = Int(callConfig.conferenceID)
                                }
                                .labelsHidden()
                                Spacer()
                            }
                        } else {
                            Text("No meetings")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                                .onAppear {
                                    callConfig.conferenceID = 0
                                    // confId = 0
                                }
                        }
                    }
                }
                if callConfig.conferenceID != 0 {
                    HStack {
                        Spacer()
                        Button("Join Meeting", action: self.join)
                            .disabled(!isAllowedJoin || callConfig.email == "" || callConfig.conferenceID == 0)
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.clear)
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif
        }
        .background(.clear)
        #if !os(tvOS)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 480)
        #endif
        .scrollDisabled(true)
        .onAppear {
            Task {
                do {
                    try await fetchManifest()
                } catch {
                    Self.logger.error("Failed to fetch manifest: \(error.localizedDescription)")
                    return
                }
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                isAllowedJoin = true
            }
        }
        #if os(tvOS)
        .continuityDevicePicker(isPresented: $showContinuityDevicePicker) { _ in
        print("Selected a device")
        }
        .task {
        showContinuityDevicePicker = AVCaptureDevice.default(.continuityCamera,
        for: .video,
        position: .unspecified) == nil
        }
        #endif
    }

    private func fetchManifest() async throws {
        callConfig = CallConfig(address: relayConfig.value.address,
                                port: relayConfig.value.port,
                                connectionProtocol: relayConfig.value.connectionProtocol,
                                email: email,
                                conferenceID: UInt32(confId))
        isLoading = true
        meetings = try await
            ManifestController.shared.getConferences(for: callConfig.email)
            .reduce(into: [:]) { $0[$1.id] = $1.title }
        isLoading = false
    }

    func join() {
        joinMeetingCallback(callConfig)
    }
}

struct CallSetupView: View {
    private var joinMeetingCallback: ConfigCallback
    @State private var settingsOpen: Bool = false

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
                    #if targetEnvironment(macCatalyst)
                    .frame(maxWidth: 350)
                    #endif

                    NavigationLink(destination: SettingsView()) {
                        Label("", systemImage: "gearshape").font(.title)
                    }
                    .buttonStyle(ActionButtonStyle(styleConfig: .init(background: .clear, foreground: .white),
                                                   cornerRadius: 50,
                                                   isDisabled: false))
                }
            }
        }
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView { _ in }
    }
}

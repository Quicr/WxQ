import SwiftUI
import AVFoundation

@MainActor
struct CallControls: View {
    @EnvironmentObject private var errorHandler: ObservableError
    @StateObject var viewModel: ViewModel

    @Binding var leaving: Bool

    @State private var audioOn: Bool = false
    @State private var videoOn: Bool = true

    @State private var cameraModalExpanded: Bool = false
    @State private var muteModalExpanded: Bool = false

    private var cameras: [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        Task { devices = await viewModel.devices(.video) }
        return devices
    }

    private var audioDevices: [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        Task { devices = await viewModel.devices(.audio) }
        return devices
    }

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    init(errorWriter: ErrorWriter, captureManager: CaptureManager?, leaving: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: ViewModel(errorWriter: errorWriter, captureManager: captureManager))
        _leaving = leaving
    }

    private func toggleVideo() async {
        for camera in await viewModel.devices(.video) {
            _ = await viewModel.toggleDevice(device: camera)
        }
        videoOn = !(await viewModel.activeDevices(.video).isEmpty)
    }

    private func toggleAudio() async {
        // TODO: Mute status needs to come from elsewhere.
        for microphone in await viewModel.devices(.audio) {
            _ = await viewModel.toggleDevice(device: microphone)
        }
        videoOn = !(await viewModel.activeDevices(.video).isEmpty)
    }

    private func openCameraModal() {
        cameraModalExpanded.toggle()
        muteModalExpanded = false
    }

    private func openAudioModal() {
        muteModalExpanded.toggle()
        cameraModalExpanded = false
    }

    var body: some View {
        HStack(alignment: .center) {
            ActionPicker(
                audioOn ? "Mute" : "Unmute",
                icon: audioOn ? "microphone-on" : "microphone-muted",
                role: audioOn ? nil : .destructive,
                expanded: $muteModalExpanded,
                action: toggleAudio,
                pickerAction: openAudioModal
            ) {
                Text("Audio Connection")
                    .foregroundColor(.gray)
                ForEach(audioDevices, id: \.uniqueID) { microphone in
                    ActionButton(
                        disabled: viewModel.isAlteringMicrophone(),
                        cornerRadius: 12,
                        styleConfig: deviceButtonStyleConfig,
                        action: toggleAudio) {
                            HStack {
                                Image(systemName: microphone.deviceType == .builtInMicrophone ?
                                      "mic" : "speaker.wave.2")
                                .renderingMode(.original)
                                .foregroundColor(.gray)
                                Text(microphone.localizedName).tag(microphone)
                            }
                        }
                        .aspectRatio(contentMode: .fill)
                }
            }
            .onChange(of: viewModel.selectedMicrophone) { _ in
                guard viewModel.selectedMicrophone != nil else { return }
                Task { await viewModel.toggleDevice(device: viewModel.selectedMicrophone!) }
            }
            .disabled(viewModel.isAlteringMicrophone())

            ActionPicker(
                videoOn ? "Stop Video" : "Start Video",
                icon: videoOn ? "video-on" : "video-off",
                role: videoOn ? nil : .destructive,
                expanded: $cameraModalExpanded,
                action: toggleVideo,
                pickerAction: openCameraModal
            ) {
                LazyVGrid(columns: [GridItem(.fixed(16)), GridItem(.flexible())],
                          alignment: .leading) {
                    Image("video-on")
                        .renderingMode(.template)
                        .foregroundColor(.gray)
                    Text("Camera")
                        .padding(.leading)
                        .foregroundColor(.gray)
                    ForEach(cameras, id: \.self) { camera in
                        if viewModel.alteringDevice[camera] ?? false {
                            ProgressView()
                        } else if cameras.contains(camera) {
                            Image(systemName: "checkmark")
                        } else {
                            Spacer()
                        }
                        ActionButton(
                            disabled: viewModel.alteringDevice[camera] ?? false,
                            cornerRadius: 10,
                            styleConfig: deviceButtonStyleConfig,
                            action: { await viewModel.toggleDevice(device: camera) },
                            title: {
                                Text(verbatim: camera.localizedName)
                                    .lineLimit(1)
                            }
                        )
                    }
                }
                .frame(maxWidth: 300, alignment: .bottomTrailing)
                .padding(.bottom)
            }
            .disabled(cameras.allSatisfy { !(viewModel.alteringDevice[$0] ?? false) })

            Button(action: {
                leaving = true
                muteModalExpanded = false
                cameraModalExpanded = false
            }, label: {
                Image("cancel")
                    .renderingMode(.template)
                    .foregroundColor(.white)
                    .padding()
            })
            .foregroundColor(.white)
            .background(.red)
            .clipShape(Circle())
        }
        .frame(maxWidth: 650)
        .scaledToFit()
        .task { await viewModel.join() }
        .onDisappear(perform: { Task { await viewModel.leave() }})
    }
}

extension CallControls {
    @MainActor
    class ViewModel: ObservableObject {
        @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
        @Published var selectedMicrophone: AVCaptureDevice?
        private let capture: CaptureManager?
        private let errorWriter: ErrorWriter

        init(errorWriter: ErrorWriter, captureManager: CaptureManager?) {
            self.errorWriter = errorWriter
            self.selectedMicrophone = AVCaptureDevice.default(for: .audio)
            self.capture = captureManager
        }

        func join() async {
            do {
                try await capture?.startCapturing()
            } catch {
                errorWriter.writeError("Couldn't start video capture: \(error.localizedDescription)")
            }
        }

        func leave() async {
            alteringDevice.removeAll()
            do {
                try await capture?.stopCapturing()
            } catch {
                errorWriter.writeError("Couldn't stop video capture: \(error.localizedDescription)")
            }
        }

        func devices(_ type: AVMediaType? = nil) async -> [AVCaptureDevice] {
            var devices = await capture?.devices() ?? []
            if let type = type {
                devices = devices.filter { $0.hasMediaType(type) }
            }
            return devices
        }

        func activeDevices(_ type: AVMediaType? = nil) async -> [AVCaptureDevice] {
            do {
                var devices = try await capture?.activeDevices() ?? []
                if let type = type {
                    devices = devices.filter { $0.hasMediaType(type) }
                }
                return devices
            } catch {
                errorWriter.writeError("Failed to query active devices: \(error.localizedDescription)")
                return []
            }
        }

        func toggleDevice(device: AVCaptureDevice) async {
            guard !(alteringDevice[device] ?? false) else {
                return
            }
            guard let capture = capture else { return }
            alteringDevice[device] = true
            _ = await capture.toggleInput(device: device)
            alteringDevice[device] = false
        }

        func isAlteringMicrophone() -> Bool {
            guard selectedMicrophone != nil else { return false }
            return alteringDevice[selectedMicrophone!] ?? false
        }
    }
}

struct CallControls_Previews: PreviewProvider {
    static var previews: some View {
        let bool: Binding<Bool> = .init(get: { return false }, set: { _ in })
        let errorWriter: ObservableError = .init()
        let capture: CaptureManager? = try? .init()
        CallControls(errorWriter: errorWriter, captureManager: capture, leaving: bool)
    }
}

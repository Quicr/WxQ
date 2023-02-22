import SwiftUI
import AVFoundation

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {

    /// Available input devices.
    @EnvironmentObject var devices: AudioVideoDevices
    /// Local capture manager.
    @EnvironmentObject var capture: ObservableCaptureManager
    /// Images to render.
    @EnvironmentObject var render: VideoParticipants

    /// Currently selected camera.
    @State private var selectedCamera: AVCaptureDevice
    /// Currently selected input microphone.
    @State private var selectedMicrophone: AVCaptureDevice

    /// Callback when call is left.
    private var onLeave: () -> Void
    private let mode: ApplicationModeBase?

    /// Create a new in call view.
    /// - Parameter onLeave: Callback fired when user asks to leave the call.
    init(mode: ApplicationModeBase?, onLeave: @escaping () -> Void) {
        self.onLeave = onLeave
        self.mode = mode
        selectedCamera = AVCaptureDevice.default(for: .video)!
        selectedMicrophone = AVCaptureDevice.default(for: .audio)!
    }

    // Remote grid config to use.
    var columns: [GridItem] { Array(repeating: .init(.flexible()), count: 1) }

    // Show a video player.
    var body: some View {
        VStack {
            // Remote videos.
            ScrollView {
                LazyVGrid(columns: columns) {
                    ForEach(Array(render.participants.values)) { participant in
                        Image(uiImage: participant.decodedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.horizontal)
                    }
                }
            }

            // Local video preview.
            // PreviewView(device: $selectedCamera)

            // Controls.
            HStack {
                // Local camera control.
                Picker("Camera", selection: $selectedCamera) {
                    ForEach(devices.cameras, id: \.self) { camera in
                        Text(camera.localizedName).tag(camera)
                    }
                }.onChange(of: selectedCamera) { [selectedCamera] newCamera in
                    capture.manager!.removeInput(device: selectedCamera)
                    capture.manager!.addInput(device: newCamera)
                }

                // Microphone control.
                Picker("Microphone", selection: $selectedMicrophone) {
                    ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
                        Text(microphone.localizedName).tag(microphone)
                    }
                }.onChange(of: selectedMicrophone) { _ in
                    capture.manager!.addInput(device: selectedMicrophone)
                }

                // Leave.
                Button("Leave", action: leaveCall)
            }
        }.onAppear {
            joinCall()
        }.onDisappear {
            leaveCall()
        }
    }

    private func joinCall() {
        // Bind pipeline to capture manager.
        capture.videoCallback = mode!.encodeCameraFrame
        capture.audioCallback = mode!.encodeAudioSample
        capture.deviceChangeCallback = mode!.onDeviceChange

        // Use default devices.
        capture.manager!.addInput(device: selectedCamera)
        capture.manager!.addInput(device: selectedMicrophone)
    }

    private func leaveCall() {
        // Stop capturing.
        capture.manager!.removeInput(device: selectedCamera)
        capture.manager!.stopCapturing()

        // Unbind pipeline.
        capture.videoCallback = nil
        capture.audioCallback = nil
        capture.deviceChangeCallback = nil

        // Report left.
        onLeave()
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(mode: nil) {}
    }
}

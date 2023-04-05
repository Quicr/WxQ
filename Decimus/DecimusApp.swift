import SwiftUI
import CoreMedia

@MainActor
class ObservableError: ObservableObject, ErrorWriter {
    struct StringError: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published var messages: [StringError] = []
    nonisolated func writeError(message: String) {
        print("[Decimus Error] => \(message)")
        DispatchQueue.main.async {
            self.messages.append(.init(message: message))
       }
    }
}

@main
struct DecimusApp: App {
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .preferredColorScheme(.dark)
                .withHostingWindow { window in
                    #if targetEnvironment(macCatalyst)
                    if let titlebar = window?.windowScene?.titlebar {
                        titlebar.titleVisibility = .hidden
                        titlebar.toolbar = nil
                    }
                    #endif
                }
        }
    }
}

extension View {
    fileprivate func withHostingWindow(_ callback: @escaping (UIWindow?) -> Void) -> some View {
        self.background(HostingWindowFinder(callback: callback))
    }
}

private struct HostingWindowFinder: UIViewRepresentable {
    var callback: (UIWindow?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { [weak view] in
            self.callback(view?.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

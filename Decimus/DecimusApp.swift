import SwiftUI

@main
struct DecimusApp: App {
    @State var columnVisibility = NavigationSplitViewVisibility.detailOnly
    var body: some Scene {
        WindowGroup {
            NavigationSplitView(columnVisibility: $columnVisibility, sidebar: ErrorView.init) {
                ZStack {
                    ConfigCallView()
                    AlertView()
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
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

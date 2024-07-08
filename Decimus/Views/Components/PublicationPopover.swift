import SwiftUI

struct PublicationPopover: View {
    private class Publications: ObservableObject {
        private let controller: CallController
        @Published var publications: [PublicationReport] = []

        init(controller: CallController) {
            self.controller = controller
        }

        func fetch() throws {
            self.publications = try self.controller.fetchPublications()
        }
    }

    @StateObject private var publications: Publications
    @State private var manifest: Manifest?
    @State private var toggleStates: [QuicrNamespace: Bool] = [:]
    private let controller: CallController
    private let logger = DecimusLogger(PublicationPopover.self)

    init(controller: CallController) {
        self.controller = controller
        self._publications = .init(wrappedValue: .init(controller: controller))
    }

    private func updateToggles() {
        for publication in publications.publications {
            self.toggleStates[publication.quicrNamespace] = publication.state == .active
        }
    }

    private func makePublishStateBinding(_ namespace: QuicrNamespace) -> Binding<Bool> {
        return .init(
            get: { self.toggleStates[namespace, default: false] },
            set: { self.toggleStates[namespace] = $0 })
    }

    var body: some View {
        Text("Alter Publications")
            .font(.title)
            .onAppear {
                do {
                    try self.publications.fetch()
                } catch {
                    self.logger.error("Failed to fetch publications: \(error.localizedDescription)")
                }
                self.updateToggles()
            }
            .padding()

        ScrollView {
            ForEach(self.publications.publications, id: \.self) { publication in
                Toggle(isOn: makePublishStateBinding(publication.quicrNamespace)) {
                    if let manifest = self.manifest,
                       let profile = manifest.getPublication(namespace: publication.quicrNamespace) {
                        Text(profile.qualityProfile)
                    } else {
                        Text(publication.quicrNamespace)
                    }
                }
                .padding()
                .onChange(of: self.toggleStates[publication.quicrNamespace]!) {
                    self.controller.setPublicationState(publication.quicrNamespace, publicationState: $0 ? .active : .paused)
                }
            }
        }
        .task {
            if let manifest = await self.controller.manifest.currentManifest {
                self.manifest = manifest
            }
        }
    }
}

extension Manifest {
    func getPublication(namespace: QuicrNamespace) -> Profile? {
        for publication in self.publications {
            for profile in publication.profileSet.profiles {
                let manifestNamespace = profile.namespace
                if namespace == manifestNamespace {
                    return profile
                }
            }
        }
        return nil
    }
}

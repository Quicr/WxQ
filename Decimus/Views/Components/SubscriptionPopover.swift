import SwiftUI

struct SubscriptionPopover: View {
    fileprivate struct SwitchingSet {
        let sourceId: SourceIDType
        let subscriptions: [Subscription]
    }

    fileprivate struct Subscription {
        let namespace: QuicrNamespace
        let state: SubscriptionState
    }

    private class SwitchingSets: ObservableObject {
        private let controller: CallController
        @Published var sets: [SwitchingSet] = []

        init(controller: CallController) {
            self.controller = controller
        }

        func fetch() throws {
            var results: [SwitchingSet] = []
            let sets = try self.controller.fetchSwitchingSets()
            for set in sets {
                var subscriptions: [Subscription] = []
                let subscriptionNamespaces = try self.controller.fetchSubscriptions(sourceId: set)
                for namespace in subscriptionNamespaces {
                    let state = self.controller.getSubscriptionState(namespace)
                    subscriptions.append(.init(namespace: namespace, state: state))
                }
                results.append(.init(sourceId: set, subscriptions: subscriptions))
            }
            self.sets = results
        }
    }

    @StateObject private var switchingSets: SwitchingSets
    @State private var manifest: Manifest?
    @State private var toggleStates: [QuicrNamespace: Bool] = [:]
    private let controller: CallController
    private let logger = DecimusLogger(SubscriptionPopover.self)

    init(controller: CallController) {
        self.controller = controller
        self._switchingSets = .init(wrappedValue: .init(controller: controller))
    }

    private func updateToggles() {
        for set in self.switchingSets.sets {
            for subscription in set.subscriptions {
                self.toggleStates[subscription.namespace] = subscription.state == .ready
            }
        }
    }

    private func makeSubscribeStateBinding(_ namespace: QuicrNamespace) -> Binding<Bool> {
        return .init(
            get: { self.toggleStates[namespace, default: false] },
            set: { self.toggleStates[namespace] = $0 })
    }

    var body: some View {
        Text("Alter Subscriptions")
            .font(.title)
            .onAppear {
                do {
                    try self.switchingSets.fetch()
                } catch {
                    self.logger.error("Failed to fetch switching sets: \(error.localizedDescription)")
                }
                self.updateToggles()
            }
            .padding()

        ScrollView {
            ForEach(self.$switchingSets.sets, id: \.self) { $set in
                VStack {
                    Text(manifest?.getSwitchingSet(sourceId: set.sourceId)?.label ?? set.sourceId)
                        .font(.headline)
                    ForEach(set.subscriptions, id: \.self) { subscription in
                        Toggle(isOn: makeSubscribeStateBinding(subscription.namespace)) {
                            if let manifest = self.manifest,
                               let profile = manifest.getSubscription(sourceId: set.sourceId, namespace: subscription.namespace) {
                                Text(profile.qualityProfile)
                            } else {
                                Text(subscription.namespace)
                            }
                        }
                        .padding()
                        .onChange(of: self.toggleStates[subscription.namespace]!) {
                            self.controller.setSubscriptionState(subscription.namespace, transportMode: $0 ? .resume : .pause)
                        }
                    }
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
    func getSwitchingSet(sourceId: SourceIDType) -> ManifestSubscription? {
        for switchingSet in self.subscriptions where switchingSet.sourceID == sourceId {
            return switchingSet
        }
        return nil
    }

    func getSubscription(sourceId: SourceIDType, namespace: QuicrNamespace) -> Profile? {
        guard let switchingSet = getSwitchingSet(sourceId: sourceId) else { return nil }
        for profile in switchingSet.profileSet.profiles {
            let manifestNamespace = profile.namespace
            if namespace == manifestNamespace {
                return profile
            }
        }
        return nil
    }
}

extension SubscriptionPopover.SwitchingSet: Hashable {
    static func == (lhs: SubscriptionPopover.SwitchingSet, rhs: SubscriptionPopover.SwitchingSet) -> Bool {
        lhs.sourceId == rhs.sourceId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.sourceId)
    }
}

extension SubscriptionPopover.Subscription: Hashable {
    static func == (lhs: SubscriptionPopover.Subscription, rhs: SubscriptionPopover.Subscription) -> Bool {
        lhs.namespace == rhs.namespace
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.namespace)
    }
}

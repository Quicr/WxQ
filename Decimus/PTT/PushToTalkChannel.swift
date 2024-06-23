import UIKit
import PushToTalk

enum CreatedFrom {
    case request
    case restore
}

class PushToTalkChannel {
    let uuid: UUID
    #if os(iOS) && !targetEnvironment(macCatalyst)
    let description: PTChannelDescriptor
    #endif
    weak var publication: OpusPublication?
    private var subscriptions: [QuicrNamespace: Weak<PushToTalkSubscription>] = [:]
    let createdFrom: CreatedFrom
    var joined = false

    init(uuid: UUID, createdFrom: CreatedFrom) {
        let image = UIImage(systemName: "waveform.circle.fill")
        // TODO: Friendly name.
        self.uuid = uuid
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.description = PTChannelDescriptor(name: uuid.uuidString, image: image)
        #endif
        self.createdFrom = createdFrom
    }

    func setSubscription(_ subscription: PushToTalkSubscription) {
        self.subscriptions["1234"] = .init(subscription)
    }
}

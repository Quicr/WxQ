//import Foundation
//
//class PushToTalkPublication : Publication {
//    var transmit = false
//    let namespace: QuicrNamespace
//    weak var publishObjectDelegate: (any QPublishObjectDelegateObjC)?
//    
//    init(namespace: QuicrNamespace, delegate: (any QPublishObjectDelegateObjC)?) {
//        self.namespace = namespace
//        self.publishObjectDelegate = delegate
//    }
//    
//    func prepare(_ sourceID: String!, qualityProfile: String!, transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32 {
//        return 0
//    }
//    
//    func update(_ sourceID: String!, qualityProfile: String!) -> Int32 {
//        return 0
//    }
//    
//    func publish(_ flag: Bool) { }
//}

import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?

    var body: some View {
        if config != nil {
            InCallView(config: config!) { config = nil }
        } else {
            CallSetupView { self.config = $0 }
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView()
    }
}

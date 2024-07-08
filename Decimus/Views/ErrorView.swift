import SwiftUI

private func getLogColour(_ level: DecimusLogger.LogLevel) -> Color {
    switch level {
    case .error:
        return .red
    case .warning:
        return .orange
    case .debug:
        return .indigo
    default:
        return .blue
    }
}

struct AlertView: View {
    @StateObject private var logger = DecimusLogger.shared

    var body: some View {
        VStack {
            if !logger.alerts.isEmpty {
                Text("Alerts:")
                    .font(.title)
                    .foregroundColor(.red)

                // Clear all.
                Button {
                    logger.alerts.removeAll()
                } label: {
                    Text("Clear Alerts")
                }
                .buttonStyle(.borderedProminent)

                // Show the messages.
                ScrollView {
                    ForEach(logger.alerts) { alert in
                        Text(alert.message)
                            .padding()
                            .background(getLogColour(alert.level))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

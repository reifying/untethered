import SwiftUI

struct MainWindowView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isServerConfigured {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)

                    Text("Server not configured")
                        .font(.caption)

                    Spacer()

                    Button("Configure") {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
            }

            VStack {
                Text("Main Window")
                    .font(.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 400, minHeight: 300)
        }
    }
}

#Preview {
    MainWindowView(settings: AppSettings())
}

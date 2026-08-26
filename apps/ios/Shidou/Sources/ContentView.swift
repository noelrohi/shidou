import ShidouProtocol
import SwiftUI

/// Placeholder root view; replaced once pairing and the session list land.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Shidou")
                    .font(.title.bold())
                Text("Not paired with a daemon yet.")
                    .foregroundStyle(.secondary)
                Text("Protocol v\(ShidouWire.protocolVersion)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                NavigationLink("Streaming spike (PROTOTYPE)") {
                    SpikeTranscriptScreen()
                }
                .buttonStyle(.bordered)
                .padding(.top, 24)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}

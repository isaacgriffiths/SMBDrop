import SwiftUI
import AMSMB2

// Placeholder screen for the pipeline-verification build. The real UI arrives
// with the main-app prototype ticket; this exists to prove the app target,
// the AMSMB2 link, and the share-extension embed all survive archiving.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
            Text("SMBDrop")
                .font(.largeTitle.bold())
            Text("Pipeline verification build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(smbClientAvailable ? "SMB engine linked" : "SMB engine missing")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var smbClientAvailable: Bool {
        // Touch the AMSMB2 module so the dynamic framework must actually load.
        String(describing: SMB2Manager.self) == "SMB2Manager"
    }
}

#Preview {
    ContentView()
}

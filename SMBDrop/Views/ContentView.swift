import SwiftUI

enum SMBDropTab: Hashable {
    case photos
    case files
    case settings
}

struct ContentView: View {
    @StateObject private var destinations = DestinationSetupViewModel()
    @StateObject private var transferQueue = TransferQueueViewModel()
    @State private var selectedTab: SMBDropTab = .photos

    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoLibraryView(
                destinations: destinations.destinations,
                transferQueue: transferQueue,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }
            .tag(SMBDropTab.photos)

            FilesBrowserView(
                destinations: destinations.destinations,
                transferQueue: transferQueue,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Files", systemImage: "folder") }
            .tag(SMBDropTab.files)

            SettingsView(
                viewModel: destinations,
                transferQueue: transferQueue
            )
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(SMBDropTab.settings)
        }
        .task {
            await transferQueue.resume()
        }
    }
}

#Preview {
    ContentView()
}

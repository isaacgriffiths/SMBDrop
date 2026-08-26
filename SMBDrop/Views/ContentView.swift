import SwiftUI

enum SMBDropTab: Hashable {
    case photos
    case files
    case imports
    case settings
}

struct ContentView: View {
    @StateObject private var destinations = DestinationSetupViewModel()
    @StateObject private var transferQueue = TransferQueueViewModel()
    @State private var selectedTab: SMBDropTab = .photos
    @AppStorage(SampleContent.defaultsKey) private var isSampleContentOn = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var isShowingOnboarding = false

    private var activeDestinations: [DestinationSummary] {
        isSampleContentOn ? SampleContent.destinations : destinations.destinations
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoLibraryView(
                destinations: activeDestinations,
                transferQueue: transferQueue,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }
            .tag(SMBDropTab.photos)

            FilesBrowserView(
                destinations: activeDestinations,
                transferQueue: transferQueue,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Files", systemImage: "folder") }
            .tag(SMBDropTab.files)

            SMBImportView(
                destinations: activeDestinations,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Import", systemImage: "arrow.down.doc") }
            .tag(SMBDropTab.imports)

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
        .onAppear {
            guard !hasCompletedOnboarding else { return }
            if destinations.destinations.isEmpty {
                isShowingOnboarding = true
            } else {
                // A share already exists (pre-onboarding install), so this
                // user needs no introduction.
                hasCompletedOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            OnboardingView(destinations: destinations) {
                hasCompletedOnboarding = true
                isShowingOnboarding = false
            }
        }
    }
}

#Preview {
    ContentView()
}

import StoreKit
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
    @AppStorage("hasRequestedReview") private var hasRequestedReview = false
    @Environment(\.requestReview) private var requestReview
    @State private var isShowingOnboarding = false
    @State private var completedTransfersAtLaunch: Int?

    private var completedTransferCount: Int {
        transferQueue.transfers.filter { $0.status == .completed }.count
    }

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
                transferQueue: transferQueue,
                isOnboardingActive: isShowingOnboarding
            )
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(SMBDropTab.settings)
        }
        .task {
            await transferQueue.resume()
            // Baseline after history restores so past sends never trigger
            // the rating prompt at launch.
            if completedTransfersAtLaunch == nil {
                completedTransfersAtLaunch = completedTransferCount
            }
        }
        .onChange(of: completedTransferCount) {
            requestReviewAfterFirstSend()
        }
        .onChange(of: transferQueue.isDraining) {
            requestReviewAfterFirstSend()
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
        .onChange(of: hasCompletedOnboarding) {
            // Settings › About › Developer › Show Onboarding clears the flag
            // to replay the first-run flow on demand.
            if !hasCompletedOnboarding {
                isShowingOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            OnboardingView(destinations: destinations) {
                hasCompletedOnboarding = true
                isShowingOnboarding = false
            }
        }
    }

    /// Mirrors the Import tab's one-time prompt: the first successful send
    /// this session is the other moment the app has proven itself. Waits for
    /// the queue to finish draining so the panel never interrupts a batch.
    private func requestReviewAfterFirstSend() {
        guard let baseline = completedTransfersAtLaunch,
              completedTransferCount > baseline,
              !transferQueue.isDraining,
              !hasRequestedReview,
              !isSampleContentOn,
              !isShowingOnboarding else { return }
        hasRequestedReview = true
        Task {
            // Let the completed state land on screen before asking.
            try? await Task.sleep(for: .seconds(1.5))
            requestReview()
        }
    }
}

#Preview {
    ContentView()
}

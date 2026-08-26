import Photos
import SwiftUI

/// First-run flow: short screens explaining the app and requesting photo
/// access, then a required add-your-first-share step using the same verified
/// editor Settings uses. Every step is written to fit on screen without
/// scrolling at default type sizes; the ScrollView only kicks in at
/// accessibility sizes.
struct OnboardingView: View {
    @ObservedObject var destinations: DestinationSetupViewModel
    let onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome
        case howItWorks
        case photos
        case connect
    }

    @State private var step: Step = .welcome
    @State private var isShowingShareEditor = false
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRequestingPhotoAccess = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasConnectedShare: Bool {
        !destinations.destinations.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .howItWorks: howItWorksStep
                    case .photos: photosStep
                    case .connect: connectStep
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareEditor) {
            DestinationEditorView(viewModel: destinations)
        }
        .onChange(of: isShowingShareEditor) {
            // A swipe-down leaves the shared editing state dangling; clear it
            // so Settings opens cleanly later.
            if !isShowingShareEditor, destinations.isEditing {
                destinations.cancelEditing()
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            if step != .welcome {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleOnly)
                }
            }
            Spacer()
            if step != .connect {
                Button("Skip") {
                    withAnimation(stepAnimation) { step = .connect }
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 12) {
            pageIndicator

            switch step {
            case .welcome, .howItWorks:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            case .photos:
                Button {
                    requestPhotoAccess()
                } label: {
                    Group {
                        if isRequestingPhotoAccess {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(photoStatus == .notDetermined ? "Allow Photo Access" : "Continue")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequestingPhotoAccess)
            case .connect:
                if hasConnectedShare {
                    Button("Start Using SMBDrop") { onFinished() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        destinations.beginAdding()
                        isShowingShareEditor = true
                    } label: {
                        Label("Add My First Share", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                Circle()
                    .fill(candidate == step ? Color.accentColor : Color(.systemFill))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(stepAnimation) { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(stepAnimation) { step = previous }
    }

    private var stepAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
    }

    private func requestPhotoAccess() {
        guard photoStatus == .notDetermined, !SampleContent.isEnabled else {
            advance()
            return
        }
        isRequestingPhotoAccess = true
        Task {
            let status = await withCheckedContinuation {
                (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
            photoStatus = status
            isRequestingPhotoAccess = false
            advance()
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        Color.accentColor.gradient,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                Text("Welcome to SMBDrop")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("Move photos and files between this iPhone and your own storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 18) {
                featureRow(
                    symbol: "photo.on.rectangle.angled",
                    color: .blue,
                    title: "Send to Your Server",
                    detail: "Originals go straight to your NAS or any SMB share."
                )
                featureRow(
                    symbol: "arrow.down.doc.fill",
                    color: .green,
                    title: "Import Back",
                    detail: "Save files from your shares onto this iPhone."
                )
                featureRow(
                    symbol: "lock.shield.fill",
                    color: .indigo,
                    title: "Private by Design",
                    detail: "No account, no cloud — passwords stay in your Keychain."
                )
            }
            .padding(.horizontal, 4)
        }
    }

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Send From Anywhere")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("Three steps, from any app on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                numberedRow(
                    number: 1,
                    title: "Pick your files",
                    detail: "Photos, Files, or the Share button in any app."
                )
                numberedRow(
                    number: 2,
                    title: "Choose a share",
                    detail: "Every send asks where the files should go."
                )
                numberedRow(
                    number: 3,
                    title: "Done",
                    detail: "Originals upload safely and never overwrite."
                )
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: photoAccessGranted ? "checkmark.circle.fill" : "photo.stack.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(photoAccessGranted ? Color.green : Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))

                Text(photoAccessGranted ? "Camera Roll Connected" : "Use Your Camera Roll")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(
                    photoAccessGranted
                        ? "Your photos and albums are ready to browse and send."
                        : "Let SMBDrop show your photos and albums so you can send them to your share."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                checklistRow(
                    symbol: "photo.on.rectangle.angled",
                    text: "Browse your library and albums right in the app"
                )
                checklistRow(
                    symbol: "arrow.up.circle",
                    text: "Originals upload in full quality — nothing is compressed"
                )
                checklistRow(
                    symbol: "hand.raised.fill",
                    text: "Nothing leaves this iPhone until you tap Send"
                )
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )

            Text("You can change this anytime in iOS Settings → SMBDrop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var photoAccessGranted: Bool {
        photoStatus == .authorized || photoStatus == .limited
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Image(
                    systemName: hasConnectedShare
                        ? "checkmark.circle.fill"
                        : "externaldrive.badge.plus"
                )
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(hasConnectedShare ? Color.green : Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))

                Text(hasConnectedShare ? "You're Connected" : "Connect Your Share")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(
                    hasConnectedShare
                        ? "Your SMB share is saved and verified. You're ready to send and import files."
                        : "SMBDrop tests the connection before saving. Have these ready:"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if hasConnectedShare {
                connectedShareCard
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    checklistRow(
                        symbol: "network",
                        text: "Your server's address — like 192.168.1.20 or nas.local"
                    )
                    checklistRow(
                        symbol: "person.badge.key.fill",
                        text: "The share's username and password"
                    )
                    checklistRow(
                        symbol: "magnifyingglass",
                        text: "Unsure of the share name? Find Shares lists them."
                    )
                }
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )

                Text("Works with Synology, QNAP, TrueNAS, Windows, and Samba.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var connectedShareCard: some View {
        if let share = destinations.destinations.first {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(
                        Color.green.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(share.displayName)
                        .font(.headline)
                    Text(share.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    // MARK: - Rows

    private func featureRow(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numberedRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checklistRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OnboardingView(destinations: DestinationSetupViewModel()) {}
}

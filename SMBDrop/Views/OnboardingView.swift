import SwiftUI

/// First-run flow: explains the app in two screens, then walks straight into
/// adding the first SMB share with the same verified editor Settings uses.
struct OnboardingView: View {
    @ObservedObject var destinations: DestinationSetupViewModel
    let onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome
        case howItWorks
        case connect
    }

    @State private var step: Step = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasConnectedShare: Bool {
        !destinations.destinations.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch step {
                case .welcome: welcomeStep
                case .howItWorks: howItWorksStep
                case .connect: connectStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .background(Color(.systemGroupedBackground))
        .sheet(
            isPresented: Binding(
                get: { destinations.isEditing },
                set: { isPresented in
                    if !isPresented { destinations.cancelEditing() }
                }
            )
        ) {
            DestinationEditorView(viewModel: destinations)
        }
        .interactiveDismissDisabled()
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
                    advance()
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 14) {
            pageIndicator

            switch step {
            case .welcome:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            case .howItWorks:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            case .connect:
                if hasConnectedShare {
                    Button("Start Using SMBDrop") { onFinished() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        destinations.beginAdding()
                    } label: {
                        Label("Add My First Share", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Set Up Later in Settings") { onFinished() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
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

    // MARK: - Steps

    private var welcomeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(
                            Color.accentColor.gradient,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                    Text("Welcome to SMBDrop")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Move photos, videos, and files between this iPhone and your own network storage.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 24) {
                    featureRow(
                        symbol: "photo.on.rectangle.angled",
                        color: .blue,
                        title: "Send to Your Server",
                        detail: "Pick photos or files and send the original bytes straight to any SMB share — a NAS, a Windows share, or a home server."
                    )
                    featureRow(
                        symbol: "arrow.down.doc.fill",
                        color: .green,
                        title: "Import Back",
                        detail: "Browse your shares from the Import tab and save files onto this iPhone."
                    )
                    featureRow(
                        symbol: "lock.shield.fill",
                        color: .indigo,
                        title: "Private by Design",
                        detail: "No account, no cloud. Transfers go directly to your server and passwords stay in the iPhone's Keychain."
                    )
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var howItWorksStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    Text("Send From Anywhere")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Three steps, from any app on your iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 20) {
                    numberedRow(
                        number: 1,
                        title: "Pick your files",
                        detail: "Use the Photos or Files tab here — or tap Share in any app and choose SMBDrop from the share sheet."
                    )
                    numberedRow(
                        number: 2,
                        title: "Choose a share",
                        detail: "Every export asks which of your saved SMB shares the files should go to."
                    )
                    numberedRow(
                        number: 3,
                        title: "Done",
                        detail: "Files upload one at a time with their original names, and never overwrite anything on your server. Progress and history live in Settings."
                    )
                }
                .padding(18)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

                Label {
                    Text("Tip: in Photos, tap Share on any picture and SMBDrop is right there in the share sheet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var connectStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 10) {
                    Image(
                        systemName: hasConnectedShare
                            ? "checkmark.circle.fill"
                            : "externaldrive.badge.plus"
                    )
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(hasConnectedShare ? Color.green : Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))

                    Text(hasConnectedShare ? "You're Connected" : "Connect Your Share")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text(
                        hasConnectedShare
                            ? "Your SMB share is saved and verified. You're ready to send and import files."
                            : "Add the SMB share you want to send files to. SMBDrop tests the connection before saving, so it only saves details that work."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                if hasConnectedShare {
                    connectedShareCard
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        checklistRow(
                            symbol: "network",
                            text: "The server's address on your network, like 192.168.1.20 or nas.local"
                        )
                        checklistRow(
                            symbol: "person.badge.key.fill",
                            text: "The username and password for the share"
                        )
                        checklistRow(
                            symbol: "magnifyingglass",
                            text: "Not sure of the share name? Find Shares lists them for you."
                        )
                    }
                    .padding(18)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )

                    Text("Works with Synology, QNAP, TrueNAS, Windows shared folders, and any Samba server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
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
            .padding(18)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }

    // MARK: - Rows

    private func featureRow(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numberedRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checklistRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OnboardingView(destinations: DestinationSetupViewModel()) {}
}

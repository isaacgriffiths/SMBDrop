import SwiftUI
import UIKit

/// Settings › "Request a Feature". Sends the message through a small relay
/// (Cloudflare Worker → Resend → the developer's inbox); falls back to the
/// user's own mail app if the relay is unreachable.
struct FeedbackView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case feature
        case problem
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .feature: "Feature"
            case .problem: "Problem"
            case .other: "Other"
            }
        }
    }

    private enum SendState: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    @State private var kind: Kind = .feature
    @State private var message = ""
    @State private var contact = ""
    @State private var sendState: SendState = .idle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sendState != .sending
            && sendState != .sent
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("What Is This About?")
            }

            Section {
                TextEditor(text: $message)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Your message")
            } header: {
                Text("Your Message")
            } footer: {
                Text(
                    kind == .feature
                        ? "What should SMBDrop do next? Every request is read by the developer."
                        : "Describe what happened and what you expected instead."
                )
            }

            Section {
                TextField("Email (optional)", text: $contact)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Only used to reply to you. Leave it empty to send anonymously.")
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Label("Send Feedback", systemImage: "paperplane.fill")
                        Spacer()
                        if sendState == .sending { ProgressView() }
                    }
                }
                .disabled(!canSend)

                switch sendState {
                case .sent:
                    Label("Sent — thank you!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Button {
                        openMailFallback()
                    } label: {
                        Label("Send With Mail Instead", systemImage: "envelope.fill")
                    }
                default:
                    EmptyView()
                }
            } footer: {
                Text("Your message goes straight to the developer, along with the app version so problems are easier to track down.")
            }
        }
        .navigationTitle("Request a Feature")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: sendState) {
            guard sendState == .sent else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }

    private func send() async {
        sendState = .sending
        do {
            try await FeedbackSender.send(
                kind: kind.rawValue,
                message: message,
                contact: contact
            )
            sendState = .sent
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            sendState = .failed("Could not send right now. Check your connection and try again.")
        }
    }

    private func openMailFallback() {
        let subjectPrefix = kind == .feature ? "Feature request" : "Feedback"
        let subject = "[SMBDrop] \(subjectPrefix)"
        let body = "\(message)\n\n—\nSMBDrop \(FeedbackSender.appVersion) (\(FeedbackSender.build)) · iOS \(UIDevice.current.systemVersion)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = FeedbackSender.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            openURL(url)
        }
    }
}

enum FeedbackSender {
    static let supportEmail = "max@wynbrothers.com"
    static let endpoint = URL(string: "https://smbdrop-feedback.isaacgriffiths001.workers.dev/feedback")!

    enum SendError: Error {
        case rejected
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static func send(kind: String, message: String, contact: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("smbdrop-ios-v1", forHTTPHeaderField: "X-SMBDrop-Client")
        request.httpBody = try JSONEncoder().encode(
            Payload(
                kind: kind,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                contact: contact.trimmingCharacters(in: .whitespacesAndNewlines),
                appVersion: appVersion,
                build: build,
                systemVersion: UIDevice.current.systemVersion
            )
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SendError.rejected
        }
    }

    private struct Payload: Encodable {
        let kind: String
        let message: String
        let contact: String
        let appVersion: String
        let build: String
        let systemVersion: String
    }
}

#Preview {
    NavigationStack {
        FeedbackView()
    }
}

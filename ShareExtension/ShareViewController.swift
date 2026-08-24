import UIKit

final class ShareViewController: UIViewController {
    private let icon = UIImageView(
        image: UIImage(systemName: "dot.radiowaves.left.and.right")
    )
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let doneButton = UIButton(configuration: .borderedProminent())
    private var workTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        workTask = Task { [weak self] in
            await self?.stageAndUploadItems()
        }
    }

    deinit {
        workTask?.cancel()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        icon.preferredSymbolConfiguration = .init(pointSize: 40, weight: .medium)
        icon.tintColor = view.tintColor

        titleLabel.text = "SMBDrop"
        titleLabel.font = .preferredFont(forTextStyle: .title1)

        statusLabel.text = "Preparing \(itemCount) item\(itemCount == 1 ? "" : "s")…"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        progressView.progress = 0
        progressView.widthAnchor.constraint(equalToConstant: 220).isActive = true

        doneButton.configuration?.title = "Please Wait"
        doneButton.isEnabled = false
        doneButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)

        let stack = UIStackView(
            arrangedSubviews: [icon, titleLabel, statusLabel, progressView, doneButton]
        )
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func stageAndUploadItems() async {
        do {
            let providers = itemProviders
            guard !providers.isEmpty else {
                throw ShareExtensionError.noItems
            }
            guard let savedDestination = try DestinationStore().load() else {
                throw ShareExtensionError.destinationMissing
            }
            let outbox = try TransferOutbox.shared()
            let loader = ShareItemProviderLoader()
            var stagedIDs = Set<UUID>()

            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                statusLabel.text = "Preparing item \(index + 1) of \(providers.count)…"
                progressView.progress = Float(index) / Float(max(1, providers.count))
                let item = try await loader.load(provider)
                do {
                    let transfer = try await outbox.enqueueFile(
                        at: item.temporaryURL,
                        filename: item.filename,
                        moveSource: true
                    )
                    stagedIDs.insert(transfer.id)
                    try? FileManager.default.removeItem(
                        at: item.temporaryURL.deletingLastPathComponent()
                    )
                } catch {
                    try? FileManager.default.removeItem(
                        at: item.temporaryURL.deletingLastPathComponent()
                    )
                    throw error
                }
            }

            statusLabel.text = "Uploading to \(savedDestination.destination.share)…"
            progressView.progress = 0
            let stagedTransferIDs = stagedIDs
            let result = await SMBTransferWorker().drain(
                outbox: outbox,
                destination: savedDestination.destination,
                password: savedDestination.password
            ) { [weak self] transfer in
                Task { @MainActor in
                    guard let self, stagedTransferIDs.contains(transfer.id) else { return }
                    self.showProgress(transfer)
                }
            }

            let transfers = try await outbox.transfers()
            let stagedTransfers = transfers.filter { stagedTransferIDs.contains($0.id) }
            if let failed = stagedTransfers.first(where: { $0.status == .failed }) ?? result.failed {
                showFailure(
                    "\(failed.filename) could not upload. \(failed.errorMessage ?? "Open SMBDrop to retry it.")"
                )
            } else if stagedTransfers.allSatisfy({ $0.status == .completed }) {
                showSuccess(count: stagedTransfers.count)
            } else {
                showQueued(count: stagedTransfers.count)
            }
        } catch is CancellationError {
            extensionContext?.cancelRequest(withError: CancellationError())
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func showProgress(_ transfer: Transfer) {
        let total = max(1, transfer.byteCount)
        progressView.progress = Float(transfer.bytesTransferred) / Float(total)
        switch transfer.status {
        case .queued:
            statusLabel.text = "Queued \(transfer.filename)…"
        case .uploading:
            statusLabel.text = "Uploading \(transfer.filename)…"
        case .failed:
            statusLabel.text = "Upload failed for \(transfer.filename)."
        case .completed:
            statusLabel.text = "Uploaded \(transfer.remoteFilename ?? transfer.filename)."
        }
    }

    private func showSuccess(count: Int) {
        icon.image = UIImage(systemName: "checkmark.circle.fill")
        icon.tintColor = .systemGreen
        statusLabel.text = "Uploaded \(count) item\(count == 1 ? "" : "s") successfully."
        progressView.progress = 1
        doneButton.configuration?.title = "Done"
        doneButton.isEnabled = true
    }

    private func showQueued(count: Int) {
        icon.image = UIImage(systemName: "clock.arrow.circlepath")
        statusLabel.text = "Queued \(count) item\(count == 1 ? "" : "s"). Open SMBDrop to finish uploading."
        doneButton.configuration?.title = "Done"
        doneButton.isEnabled = true
    }

    private func showFailure(_ message: String) {
        icon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        icon.tintColor = .systemRed
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        doneButton.configuration?.title = "Done"
        doneButton.isEnabled = true
    }

    private var itemProviders: [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
    }

    private var itemCount: Int {
        itemProviders.count
    }
}

private enum ShareExtensionError: LocalizedError {
    case destinationMissing
    case noItems

    var errorDescription: String? {
        switch self {
        case .destinationMissing:
            return "Open SMBDrop and save an SMB destination before sharing."
        case .noItems:
            return "Photos did not pass any items to SMBDrop."
        }
    }
}

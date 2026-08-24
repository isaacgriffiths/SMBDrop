import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private let icon = UIImageView(
        image: UIImage(systemName: "externaldrive.fill.badge.wifi")
    )
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let destinationButton = UIButton(configuration: .bordered())
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(configuration: .borderedProminent())
    private var destinations: [SavedDestination] = []
    private var transferSnapshots: [UUID: Transfer] = [:]
    private var workTask: Task<Void, Never>?
    private var isShowingTerminalState = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        loadDestinations()
    }

    deinit {
        workTask?.cancel()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        icon.preferredSymbolConfiguration = .init(pointSize: 40, weight: .medium)
        icon.tintColor = view.tintColor
        icon.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.text = "Choose an SMB Share"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        statusLabel.text = "Send \(itemCount) item\(itemCount == 1 ? "" : "s") to:"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        destinationButton.showsMenuAsPrimaryAction = true
        destinationButton.accessibilityLabel = "SMB share destination"
        destinationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        progressView.progress = 0
        progressView.isHidden = true
        progressView.widthAnchor.constraint(equalToConstant: 260).isActive = true

        actionButton.isHidden = true

        let stack = UIStackView(
            arrangedSubviews: [
                icon,
                titleLabel,
                statusLabel,
                destinationButton,
                progressView,
                actionButton,
            ]
        )
        stack.axis = .vertical
        stack.spacing = 14
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

    private func loadDestinations() {
        do {
            destinations = try DestinationStore().loadAll()
            guard !destinations.isEmpty else {
                showFailure("Open SMBDrop, go to Settings, and add an SMB share first.")
                return
            }
            destinationButton.configuration?.title = "Choose Share"
            destinationButton.configuration?.subtitle = nil
            destinationButton.menu = UIMenu(
                title: "Choose an SMB Share",
                children: destinations.map { destination in
                    UIAction(
                        title: destination.summary.displayName,
                        subtitle: destination.summary.displayPath,
                        image: UIImage(systemName: "externaldrive.fill"),
                        state: .off
                    ) { [weak self] _ in
                        Task { @MainActor in self?.startUpload(to: destination) }
                    }
                }
            )
            if itemProviders.isEmpty {
                showFailure(ShareExtensionError.noItems.localizedDescription)
            }
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func startUpload(to destination: SavedDestination) {
        guard workTask == nil else { return }
        isShowingTerminalState = false
        destinationButton.configuration?.title = destination.summary.displayName
        destinationButton.configuration?.subtitle = destination.summary.displayPath
        destinationButton.isEnabled = false
        progressView.isHidden = false
        workTask = Task { [weak self] in
            await self?.stageAndUploadItems(to: destination)
        }
    }

    private func stageAndUploadItems(to savedDestination: SavedDestination) async {
        do {
            let providers = itemProviders
            guard !providers.isEmpty else {
                throw ShareExtensionError.noItems
            }
            let outbox = try TransferOutbox.shared()
            let loader = ShareItemProviderLoader()
            let batchID = UUID()
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
                        destinationID: savedDestination.id,
                        batchID: batchID,
                        moveSource: true
                    )
                    stagedIDs.insert(transfer.id)
                    transferSnapshots[transfer.id] = transfer
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

            statusLabel.text = "Uploading 1 of \(stagedIDs.count) to \(savedDestination.summary.displayName)…"
            progressView.progress = 0
            let stagedTransferIDs = stagedIDs
            let result = await SMBTransferWorker().drain(
                outbox: outbox,
                destination: savedDestination.destination,
                password: savedDestination.password,
                destinationID: savedDestination.id,
                transferIDs: stagedTransferIDs
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
            } else if !stagedTransfers.isEmpty,
                      stagedTransfers.allSatisfy({ $0.status == .completed }) {
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
        guard !isShowingTerminalState else { return }
        transferSnapshots[transfer.id] = transfer
        let overall = TransferBatchProgress(transfers: Array(transferSnapshots.values))
        progressView.progress = Float(overall.fractionCompleted)
        let percent = Int(overall.fractionCompleted * 100)
        let itemNumber = overall.itemNumber(for: transfer.id) ?? overall.currentItemNumber
        let itemCount = "\(itemNumber) of \(overall.totalCount)"

        switch transfer.status {
        case .queued:
            statusLabel.text = "Item \(itemCount) · \(percent)% overall\nQueued \(transfer.filename)…"
        case .uploading:
            statusLabel.text = "Item \(itemCount) · \(percent)% overall\nUploading \(transfer.filename)…"
        case .failed:
            statusLabel.text = "Item \(itemCount) · \(percent)% overall\nUpload failed for \(transfer.filename)."
        case .completed:
            let count = overall.isComplete ? overall.totalCount : itemNumber
            statusLabel.text = "Item \(count) of \(overall.totalCount) · \(percent)% overall"
        }
    }

    private func showSuccess(count: Int) {
        isShowingTerminalState = true
        icon.image = UIImage(systemName: "checkmark.circle.fill")
        icon.tintColor = .systemGreen
        statusLabel.text = "Uploaded \(count) of \(count) items successfully."
        statusLabel.textColor = .secondaryLabel
        progressView.progress = 1
        destinationButton.isHidden = true
        actionButton.isHidden = false
        actionButton.configuration?.title = "Done"
        actionButton.isEnabled = true
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)
    }

    private func showQueued(count: Int) {
        isShowingTerminalState = true
        icon.image = UIImage(systemName: "clock.arrow.circlepath")
        statusLabel.text = "Queued \(count) item\(count == 1 ? "" : "s"). Open SMBDrop to finish uploading."
        destinationButton.isHidden = true
        actionButton.isHidden = false
        actionButton.configuration?.title = "Done"
        actionButton.isEnabled = true
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)
    }

    private func showFailure(_ message: String) {
        isShowingTerminalState = true
        icon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        icon.tintColor = .systemRed
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        progressView.isHidden = true
        destinationButton.isHidden = destinations.isEmpty
        actionButton.isHidden = false
        actionButton.configuration?.title = "Done"
        actionButton.isEnabled = true
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)
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
    case noItems

    var errorDescription: String? {
        "The sharing app did not pass any photos, videos, or files to SMBDrop."
    }
}

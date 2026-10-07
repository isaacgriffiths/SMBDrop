import BackgroundTasks
import Combine
import Foundation
import Photos
import UIKit

/// The photos a backup has already handed to the outbox, one identifier per
/// line. Recording a photo appends a line rather than rewriting a list that
/// can hold a whole library.
final class AutomaticBackupLedger {
    let fileURL: URL
    private(set) var assetIDs: Set<String>

    init(fileURL: URL) {
        self.fileURL = fileURL
        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        assetIDs = Set(contents.split(separator: "\n").map(String.init))
    }

    static func standard(fileManager: FileManager = .default) -> AutomaticBackupLedger {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AutomaticBackupLedger(
            fileURL: support.appendingPathComponent("AutomaticBackupLedger.txt", isDirectory: false)
        )
    }

    func contains(_ assetID: String) -> Bool {
        assetIDs.contains(assetID)
    }

    func record(_ assetID: String) {
        guard assetIDs.insert(assetID).inserted else { return }
        let line = Data("\(assetID)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    func reset(to assetIDs: Set<String>) {
        self.assetIDs = assetIDs
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = assetIDs.map { "\($0)\n" }.joined()
        try? Data(contents.utf8).write(to: fileURL, options: .atomic)
    }
}

/// Automatic Backup: every photo and video in the library goes to one chosen
/// share, without the user picking them. iOS gives an app no way to run
/// whenever a photo is taken, so a backup runs when SMBDrop opens, while it
/// stays open, and overnight in a background task while the phone charges.
@MainActor
final class AutomaticBackupController: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = AutomaticBackupController(coordinator: .shared)
    static let taskIdentifier = "com.isaacgriffiths.smbdrop.backup"

    enum Scope {
        /// Everything already in the library, then anything new.
        case wholeLibrary
        /// Only photos and videos added from now on.
        case newItemsOnly
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var destinationID: UUID?
    @Published private(set) var lastRunDate: Date?
    @Published private(set) var handedOffCount: Int
    @Published private(set) var problem: String?

    let coordinator: PhotoExportCoordinator
    private let defaults: UserDefaults
    private let ledger: AutomaticBackupLedger
    private let destinationStore: DestinationStore
    private var changeDebounce: Task<Void, Never>?
    private var isObservingLibrary = false

    private enum Key {
        static let enabled = "automaticBackup.enabled"
        static let destinationID = "automaticBackup.destinationID"
        static let lastRunDate = "automaticBackup.lastRunDate"
    }

    init(
        coordinator: PhotoExportCoordinator,
        defaults: UserDefaults = .standard,
        ledger: AutomaticBackupLedger = .standard(),
        destinationStore: DestinationStore = DestinationStore()
    ) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.ledger = ledger
        self.destinationStore = destinationStore
        isEnabled = defaults.bool(forKey: Key.enabled)
        destinationID = defaults.string(forKey: Key.destinationID).flatMap(UUID.init(uuidString:))
        lastRunDate = defaults.object(forKey: Key.lastRunDate) as? Date
        handedOffCount = ledger.assetIDs.count
        super.init()
        coordinator.onBackupAssetStaged = { [weak self] destinationID, assetID in
            guard let self, destinationID == self.destinationID else { return }
            self.ledger.record(assetID)
            self.handedOffCount = self.ledger.assetIDs.count
        }
        if isEnabled { observeLibrary() }
    }

    /// Only once backup is on, so launching SMBDrop never touches the photo
    /// library before the user has chosen to share it.
    private func observeLibrary() {
        guard !isObservingLibrary else { return }
        isObservingLibrary = true
        PHPhotoLibrary.shared().register(self)
    }

    var pendingCount: Int { coordinator.pendingBackupCount }

    static var hasFullLibraryAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Turns the backup on for a share, or moves it to a different one.
    /// Returns false when the user has not given full photo-library access,
    /// which a backup needs to see new photos.
    func enable(destinationID: UUID, scope: Scope) async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized else { return false }

        coordinator.cancelBackups()
        ledger.reset(to: scope == .newItemsOnly ? Set(libraryAssetIDs()) : [])
        handedOffCount = ledger.assetIDs.count
        self.destinationID = destinationID
        isEnabled = true
        problem = nil
        defaults.set(true, forKey: Key.enabled)
        defaults.set(destinationID.uuidString, forKey: Key.destinationID)
        observeLibrary()
        scheduleBackgroundTask()
        await run(userInitiated: true)
        return true
    }

    func disable() {
        isEnabled = false
        problem = nil
        defaults.set(false, forKey: Key.enabled)
        coordinator.cancelBackups()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    /// Queues anything new and sends it. `userInitiated` is true only for an
    /// explicit tap: iOS keeps Continued Processing for user actions, so an
    /// automatic run uses the ordinary short background window instead.
    func run(userInitiated: Bool) async {
        guard queueNewItems() else { return }
        await coordinator.prepareForRun()
        lastRunDate = Date()
        defaults.set(lastRunDate, forKey: Key.lastRunDate)
        if userInitiated {
            await coordinator.transferQueue.startUserInitiatedTransfer()
        } else {
            await coordinator.transferQueue.startAutomaticTransfer()
        }
    }

    /// Adds library items the backup has not handled yet. Returns false when
    /// backup cannot run at all.
    @discardableResult
    private func queueNewItems() -> Bool {
        guard isEnabled, !SampleContent.isEnabled, let destinationID else { return false }
        guard Self.hasFullLibraryAccess else {
            problem = "Automatic Backup needs access to your full photo library. Allow it in Settings › Apps › SMBDrop › Photos."
            return false
        }
        guard let destinations = try? destinationStore.loadAll(),
              destinations.contains(where: { $0.id == destinationID }) else {
            problem = "The share Automatic Backup used was removed. Choose another share to keep backing up."
            coordinator.cancelBackups()
            return false
        }
        problem = nil
        let newIDs = libraryAssetIDs().filter { !ledger.contains($0) }
        coordinator.enqueueBackup(assetIDs: newIDs, destinationID: destinationID)
        return true
    }

    /// Oldest first, so an interrupted first backup still leaves a complete
    /// run of history on the share.
    private func libraryAssetIDs() -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    @objc nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.libraryDidChange()
        }
    }

    /// New photos taken while SMBDrop is open go straight out. Changes come
    /// in bursts (edits, favourites, iCloud syncing), so wait for a lull.
    private func libraryDidChange() {
        guard isEnabled, UIApplication.shared.applicationState == .active else { return }
        changeDebounce?.cancel()
        changeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            await self.run(userInitiated: false)
        }
    }

    // MARK: Background task

    /// Must run before the app finishes launching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: DispatchQueue.main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                AutomaticBackupController.shared.handle(task)
            }
        }
    }

    /// Asks iOS for a long run while the phone is charging and online. iOS
    /// decides when, usually overnight.
    func scheduleBackgroundTask() {
        guard isEnabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGProcessingTask) {
        scheduleBackgroundTask()
        let transferQueue = coordinator.transferQueue
        task.expirationHandler = {
            Task { @MainActor in
                transferQueue.cancelActiveDrain()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.run(userInitiated: false)
            task.setTaskCompleted(success: self.pendingCount == 0)
        }
    }
}

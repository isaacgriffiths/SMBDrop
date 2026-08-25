import { readFileSync } from "node:fs";

const shareController = readFileSync("ShareExtension/ShareViewController.swift", "utf8");
const contentView = readFileSync("SMBDrop/Views/ContentView.swift", "utf8");
const setupView = readFileSync("SMBDrop/Views/DestinationEditorView.swift", "utf8");
const photosView = readFileSync("SMBDrop/Views/PhotoLibraryView.swift", "utf8");
const importView = readFileSync("SMBDrop/Views/SMBImportView.swift", "utf8");
const importService = readFileSync(
  "SMBDrop/Networking/SMBImportService.swift",
  "utf8",
);
const filesView = readFileSync("SMBDrop/Views/FilesBrowserView.swift", "utf8");
const settingsView = readFileSync("SMBDrop/Views/SettingsView.swift", "utf8");
const transferActivityView = readFileSync(
  "SMBDrop/Views/TransferActivityView.swift",
  "utf8",
);
const transferQueueViewModel = readFileSync(
  "SMBDrop/ViewModels/TransferQueueViewModel.swift",
  "utf8",
);
const setupViewModel = readFileSync(
  "SMBDrop/ViewModels/DestinationSetupViewModel.swift",
  "utf8",
);
const photoLibraryViewModel = readFileSync(
  "SMBDrop/ViewModels/PhotoLibraryViewModel.swift",
  "utf8",
);
const providerLoader = readFileSync(
  "ShareExtension/ShareItemProviderLoader.swift",
  "utf8",
);
const filenameResolver = readFileSync("Shared/ShareItemFilename.swift", "utf8");
const fileStager = readFileSync("Shared/ShareItemFileStager.swift", "utf8");
const uploader = readFileSync("Shared/Transfers/SMBTransferWorker.swift", "utf8");
const destinationStore = readFileSync("Shared/DestinationStore.swift", "utf8");
const outbox = readFileSync("Shared/Transfers/TransferOutbox.swift", "utf8");
const extensionInfo = readFileSync("ShareExtension/Info.plist", "utf8");
const appInfo = readFileSync("SMBDrop/SupportFiles/Info.plist", "utf8");

if (/uploading arrives in the next build/i.test(shareController)) {
  throw new Error("The share extension still displays the upload placeholder.");
}
if (!/Browse Folders/.test(setupView)) {
  throw new Error("Destination setup does not expose the folder browser.");
}
if (!/PhotoLibraryView/.test(contentView) || !/FilesBrowserView/.test(contentView)
    || !/SMBImportView/.test(contentView) || !/SettingsView/.test(contentView)) {
  throw new Error("The main app does not expose Photos, Files, Import, and Settings tabs.");
}
if (!/RecentAlbumPreview/.test(photosView) || !/AlbumPreview/.test(photosView)
    || !/setSelectionRange/.test(photosView) || !/VideoDurationBadge/.test(photosView)) {
  throw new Error("The Photos tab is missing album browsing, drag selection, or video durations.");
}
if (!/Connected Shares/.test(importView) || !/Import .*Item/.test(importView)
    || !/downloadItem/.test(importService) || !/fileAlreadyExists/.test(importService)
    || !/SMBDrop Imports/.test(importService)) {
  throw new Error("The Import tab does not safely browse and download from connected SMB shares.");
}
if (!/PHPhotoLibraryChangeObserver/.test(photoLibraryViewModel) || !/@objc\s+nonisolated\s+func\s+photoLibraryDidChange/.test(photoLibraryViewModel)) {
  throw new Error("The photo library model does not satisfy the Photos change-observer protocol.");
}
if (!/fileImporter/.test(filesView) || !/allowsMultipleSelection: true/.test(filesView)) {
  throw new Error("The Files tab does not use the native multi-select document picker.");
}
if (!/Add SMB Share/.test(settingsView) || !/ForEach\(viewModel\.destinations\)/.test(settingsView)) {
  throw new Error("Settings does not list and add multiple SMB shares.");
}
if (!/ForEach\(removableTransfers\)/.test(transferActivityView)
    || !/requestRemoval/.test(transferQueueViewModel)) {
  throw new Error("Current Transfer does not let people remove individual queued or sending items.");
}
if (!/BGContinuedProcessingTaskRequest/.test(transferQueueViewModel)
    || !/task\.progress/.test(transferQueueViewModel)
    || !/setTaskCompleted/.test(transferQueueViewModel)
    || !/beginBackgroundTask/.test(transferQueueViewModel)
    || !/DispatchQueue\.global/.test(transferQueueViewModel)
    || !/strategy = \.queue/.test(transferQueueViewModel)
    || !/TransferDrainLifetime/.test(transferQueueViewModel)) {
  throw new Error("Main-app transfers do not continue with system progress after backgrounding.");
}
if (!/startUserInitiatedTransfer/.test(photosView + photoLibraryViewModel)
    || !/startUserInitiatedTransfer/.test(filesView)) {
  throw new Error("Photo and file exports do not start a user-initiated continued task.");
}
if (!/BGTaskSchedulerPermittedIdentifiers/.test(appInfo)
    || !/com\.isaacgriffiths\.smbdrop\.transfer\.\*/.test(appInfo)) {
  throw new Error("The app does not permit its continued transfer task identifier.");
}
if (!/loadAll\(\)/.test(destinationStore) || !/savedDestinations\.v2/.test(destinationStore)) {
  throw new Error("Destination storage does not support multi-share migration.");
}
if (!/destinationID/.test(outbox) || !/batchID/.test(outbox) || !/claimNext\(/.test(outbox)) {
  throw new Error("Queued transfers are not bound to a destination and batch.");
}
if (!/requestRemoval/.test(outbox) || !/TransferRemovalResult/.test(outbox)
    || !/isRemovalRequested/.test(outbox) || !/removeClaimed/.test(outbox)
    || !/beginPublishing/.test(outbox) || !/case tooLate/.test(outbox)) {
  throw new Error("The durable outbox cannot safely remove an item from the current transfer.");
}
if (/destinationID: UUID\? = nil/.test(outbox) || /batchID: UUID\? = nil/.test(outbox)) {
  throw new Error("The outbox still allows new transfers without a destination or batch.");
}
if (!/retireDestination/.test(outbox) || !/destinationRemoved/.test(outbox) || !/reconcileRetiredDestinations/.test(outbox)) {
  throw new Error("Destination removal is not coordinated with extension enqueueing.");
}
if (!/ownerSessionID/.test(outbox) || !/SMBDropProcess\.sessionID/.test(outbox)) {
  throw new Error("Destination retirement cannot distinguish an active removal from crash recovery.");
}
if (/try\? await outbox\.restoreDestination/.test(setupViewModel) || !/DestinationRemovalError/.test(setupViewModel)) {
  throw new Error("A failed destination-removal rollback is still being hidden.");
}
if (!/DestinationRemovalResult/.test(setupViewModel) || !/Could Not Remove SMB Share/.test(settingsView)) {
  throw new Error("Settings cannot distinguish pending transfers from a failed destination removal.");
}
if (!/Use & Save/.test(setupView) || !/useBrowsedFolder\(\) async/.test(setupViewModel)) {
  throw new Error("A browsed folder is not verified and saved before the picker closes.");
}
if (!/loadInPlaceFileRepresentation/.test(providerLoader)) {
  throw new Error("The share extension does not request an in-place Photos representation first.");
}
if (!/isPhotosTemporaryCopyName/.test(filenameResolver)) {
  throw new Error("Temporary Photos copy names can leak into SMB filenames.");
}
if (!/originalFilenameUnavailable/.test(filenameResolver)) {
  throw new Error("The share extension invents a name when Photos withholds the original.");
}
if (!/creationDate/.test(fileStager) || !/modificationDate/.test(fileStager)) {
  throw new Error("Share staging does not preserve original file dates.");
}
if (!/enqueueFile/.test(shareController) || !/SMBTransferWorker/.test(shareController)) {
  throw new Error("The share extension does not stage and drain shared items.");
}
if (!/Choose an SMB Share/.test(shareController) || !/TransferBatchProgress/.test(shareController)) {
  throw new Error("The share extension does not choose a destination and show aggregate progress.");
}
if (!/itemNumber\(for: transfer\.id\)/.test(shareController)) {
  throw new Error("Share-extension status can mismatch a transfer filename and its N-of-X position.");
}
if (!/guard !isShowingTerminalState else/.test(shareController)) {
  throw new Error("A delayed progress callback can overwrite terminal share-extension status.");
}
if (!/startUpload\(to: destination\)/.test(shareController) || /Send Items/.test(shareController)) {
  throw new Error("Choosing a share does not start the extension upload immediately.");
}
if (!/uploadItem/.test(uploader) || !/moveItem/.test(uploader)) {
  throw new Error("The SMB uploader does not stream and publish staged files.");
}
if (!/smbdrop-.*\.partial/.test(uploader) || /filename:\s*"\.\\\(makeUUID\(\)\.uuidString\)/.test(uploader)) {
  throw new Error("SMB temporary names can still make published files hidden on Windows shares.");
}
if (!/work\.isRemovalRequested/.test(uploader) || !/case cancelled/.test(uploader)) {
  throw new Error("An active SMB upload does not stop before publishing a removed item.");
}
if (!/outbox\.removeClaimed\(work\)/.test(uploader)) {
  throw new Error("The transfer worker does not remove an actively cancelled queue item.");
}
if (!/func release\(_ work: TransferWork\)/.test(outbox)
    || !/Task\.isCancelled/.test(uploader)) {
  throw new Error("An expired background upload cannot return safely to the durable queue.");
}
if (!/setAttributes/.test(uploader) || /uniqueFilename/.test(uploader)) {
  throw new Error("The SMB uploader does not preserve exact names and timestamps.");
}
if (!/NSLocalNetworkUsageDescription/.test(extensionInfo)) {
  throw new Error("The share extension is missing its local-network privacy description.");
}
if (!/UIFileSharingEnabled/.test(appInfo) || !/LSSupportsOpeningDocumentsInPlace/.test(appInfo)) {
  throw new Error("Imported files are not exposed in the Files app.");
}

console.log("Albums, SMB imports, and multi-share uploads are wired end to end.");

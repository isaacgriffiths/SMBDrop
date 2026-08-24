import { readFileSync } from "node:fs";

const shareController = readFileSync("ShareExtension/ShareViewController.swift", "utf8");
const contentView = readFileSync("SMBDrop/Views/ContentView.swift", "utf8");
const setupView = readFileSync("SMBDrop/Views/DestinationEditorView.swift", "utf8");
const photosView = readFileSync("SMBDrop/Views/PhotoLibraryView.swift", "utf8");
const filesView = readFileSync("SMBDrop/Views/FilesBrowserView.swift", "utf8");
const settingsView = readFileSync("SMBDrop/Views/SettingsView.swift", "utf8");
const setupViewModel = readFileSync(
  "SMBDrop/ViewModels/DestinationSetupViewModel.swift",
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

if (/uploading arrives in the next build/i.test(shareController)) {
  throw new Error("The share extension still displays the upload placeholder.");
}
if (!/Browse Folders/.test(setupView)) {
  throw new Error("Destination setup does not expose the folder browser.");
}
if (!/PhotoLibraryView/.test(contentView) || !/FilesBrowserView/.test(contentView) || !/SettingsView/.test(contentView)) {
  throw new Error("The main app does not expose Photos, Files, and Settings tabs.");
}
if (!/LazyVGrid/.test(photosView) || !/selectedIDs/.test(photosView)) {
  throw new Error("The Photos tab is not a selectable photo-library grid.");
}
if (!/fileImporter/.test(filesView) || !/allowsMultipleSelection: true/.test(filesView)) {
  throw new Error("The Files tab does not use the native multi-select document picker.");
}
if (!/Add SMB Share/.test(settingsView) || !/ForEach\(viewModel\.destinations\)/.test(settingsView)) {
  throw new Error("Settings does not list and add multiple SMB shares.");
}
if (!/loadAll\(\)/.test(destinationStore) || !/savedDestinations\.v2/.test(destinationStore)) {
  throw new Error("Destination storage does not support multi-share migration.");
}
if (!/destinationID/.test(outbox) || !/batchID/.test(outbox) || !/claimNext\(/.test(outbox)) {
  throw new Error("Queued transfers are not bound to a destination and batch.");
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
if (!/startUpload\(to: destination\)/.test(shareController) || /Send Items/.test(shareController)) {
  throw new Error("Choosing a share does not start the extension upload immediately.");
}
if (!/uploadItem/.test(uploader) || !/moveItem/.test(uploader)) {
  throw new Error("The SMB uploader does not stream and publish staged files.");
}
if (!/setAttributes/.test(uploader) || /uniqueFilename/.test(uploader)) {
  throw new Error("The SMB uploader does not preserve exact names and timestamps.");
}
if (!/NSLocalNetworkUsageDescription/.test(extensionInfo)) {
  throw new Error("The share extension is missing its local-network privacy description.");
}

console.log("Multi-share Photos, Files, and share-sheet uploads are wired end to end.");

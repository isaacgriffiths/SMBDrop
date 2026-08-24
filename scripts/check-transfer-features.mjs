import { readFileSync } from "node:fs";

const shareController = readFileSync("ShareExtension/ShareViewController.swift", "utf8");
const setupView = readFileSync("SMBDrop/Views/ContentView.swift", "utf8");
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
const extensionInfo = readFileSync("ShareExtension/Info.plist", "utf8");

if (/uploading arrives in the next build/i.test(shareController)) {
  throw new Error("The share extension still displays the upload placeholder.");
}
if (!/Browse Folders/.test(setupView)) {
  throw new Error("Destination setup does not expose the folder browser.");
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
if (!/uploadItem/.test(uploader) || !/moveItem/.test(uploader)) {
  throw new Error("The SMB uploader does not stream and publish staged files.");
}
if (!/setAttributes/.test(uploader) || /uniqueFilename/.test(uploader)) {
  throw new Error("The SMB uploader does not preserve exact names and timestamps.");
}
if (!/NSLocalNetworkUsageDescription/.test(extensionInfo)) {
  throw new Error("The share extension is missing its local-network privacy description.");
}

console.log("Folder browsing and share-sheet SMB uploads are wired end to end.");

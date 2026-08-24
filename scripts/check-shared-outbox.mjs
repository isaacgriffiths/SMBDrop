import { existsSync, readFileSync } from "node:fs";

const projectPath = process.argv[2] ?? "project.yml";
const project = readFileSync(projectPath, "utf8");

function targetBlock(targetName) {
  const marker = `  ${targetName}:`;
  const start = project.indexOf(marker);
  if (start === -1) {
    throw new Error(`Missing ${targetName} target in ${projectPath}.`);
  }

  const remainder = project.slice(start + marker.length);
  const nextTarget = remainder.search(/\r?\n  [A-Za-z][^:\r\n]*:\r?\n/);
  return nextTarget === -1 ? remainder : remainder.slice(0, nextTarget);
}

for (const targetName of ["SMBDrop", "ShareExtension"]) {
  if (!/^\s*-\s+Shared\s*$/m.test(targetBlock(targetName))) {
    throw new Error(`${targetName} does not compile the shared source directory.`);
  }
}

if (!existsSync("Shared/Transfers/TransferOutbox.swift")) {
  throw new Error("The shared TransferOutbox implementation is missing.");
}

if (existsSync("SMBDrop/Transfers/TransferOutbox.swift")) {
  throw new Error("TransferOutbox is duplicated in the application-only source tree.");
}

console.log("TransferOutbox is shared by the app and extension targets.");

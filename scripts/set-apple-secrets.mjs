#!/usr/bin/env node

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const envPath = join(root, ".env.local");
const repository = "isaacgriffiths/SMBDrop";

const fail = (message) => {
  console.error(`Error: ${message}`);
  process.exit(1);
};

if (!existsSync(envPath)) {
  fail(".env.local was not found. Copy .env.example and fill it in first.");
}

const env = {};
for (const line of readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
  if (match) env[match[1]] = match[2].trim().replace(/^["']|["']$/g, "");
}

const required = (name) => {
  if (!env[name]) fail(`${name} is missing from .env.local.`);
  return env[name];
};

const issuerId = required("ASC_ISSUER_ID");
if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(issuerId)) {
  fail("ASC_ISSUER_ID is not a UUID.");
}

const keyPathValue = required("ASC_KEY_P8_PATH");
const keyPath = isAbsolute(keyPathValue)
  ? keyPathValue
  : resolve(root, keyPathValue);
if (!existsSync(keyPath)) fail(`ASC key file was not found at ${keyPath}.`);

const keyContent = readFileSync(keyPath, "utf8").trim();
if (
  !keyContent.includes("BEGIN PRIVATE KEY") ||
  !keyContent.includes("END PRIVATE KEY")
) {
  fail("ASC_KEY_P8_PATH does not point to an App Store Connect private key.");
}

const keyIdFromName = keyPath.match(/AuthKey_([A-Z0-9]+)\.p8$/i)?.[1];
const keyId = env.ASC_KEY_ID || keyIdFromName;
if (!keyId)
  fail("ASC_KEY_ID is missing and could not be derived from the key filename.");

const ghExecutable = process.platform === "win32" ? "gh.cmd" : "gh";
const gh = (args, input) =>
  execFileSync(ghExecutable, args, {
    cwd: root,
    input,
    encoding: "utf8",
    stdio:
      input === undefined
        ? ["ignore", "pipe", "pipe"]
        : ["pipe", "pipe", "pipe"],
  });

const setVariable = (name, value) => {
  gh(["variable", "set", name, "--repo", repository, "--body", value]);
  console.log(`Set variable ${name}`);
};

const setSecret = (name, value) => {
  // Pass secret material on stdin so it is absent from the process arguments.
  gh(["secret", "set", name, "--repo", repository], value);
  console.log(`Set secret ${name}`);
};

gh(["auth", "status"]);

setVariable("APP_PROJECT", "SMBDrop.xcodeproj");
setVariable("APP_SCHEME", "SMBDrop");
setVariable("APP_BUNDLE_ID", "com.isaacgriffiths.smbdrop");
setVariable("APP_TEAM_ID", "LKAFZ4ANSY");

const username = env.GITHUB_USERNAME || "isaacgriffiths";
const basicAuthorization = Buffer.from(
  `${username}:${required("GITHUB_PAT")}`,
  "utf8",
).toString("base64");

setSecret("ASC_KEY_ID", keyId);
setSecret("ASC_ISSUER_ID", issuerId);
setSecret("ASC_KEY_P8", `${keyContent}\n`);
setSecret(
  "MATCH_GIT_URL",
  "https://github.com/isaacgriffiths/ios-certificates",
);
setSecret("MATCH_PASSWORD", required("MATCH_PASSWORD"));
setSecret("MATCH_GIT_BASIC_AUTHORIZATION", basicAuthorization);

const secretNames = JSON.parse(
  gh(["secret", "list", "--repo", repository, "--json", "name"]),
).map(({ name }) => name);

const expectedSecrets = [
  "ASC_KEY_ID",
  "ASC_ISSUER_ID",
  "ASC_KEY_P8",
  "MATCH_GIT_URL",
  "MATCH_PASSWORD",
  "MATCH_GIT_BASIC_AUTHORIZATION",
];
const missingSecrets = expectedSecrets.filter(
  (name) => !secretNames.includes(name),
);
if (missingSecrets.length > 0)
  fail(`GitHub is still missing: ${missingSecrets.join(", ")}`);

console.log("Apple signing configuration is complete.");
console.log(
  'Next: gh workflow run "Init signing (run once per app)" --repo isaacgriffiths/SMBDrop',
);

import { readFileSync } from "node:fs";

const projectPath = process.argv[2] ?? "project.yml";
const project = readFileSync(projectPath, "utf8");
const dependency = project.match(
  /^\s*-\s+package:\s+AMSMB2\s*$((?:\r?\n[ \t]+[^\r\n]+)*)/m,
);

if (!dependency) {
  console.error("AMSMB2 is not linked by an application target.");
  process.exit(1);
}

if (!/^\s+embed:\s+true\s*$/m.test(dependency[1])) {
  console.error(
    "AMSMB2 is linked but not embedded; a device launch will fail with DYLD 1 Library missing.",
  );
  process.exit(1);
}

console.log("AMSMB2 is configured to be embedded in the application bundle.");

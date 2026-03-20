import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(__dirname, "../..");

async function readWorkspaceVersion() {
  const cargoTomlPath = path.join(workspaceRoot, "Cargo.toml");
  const cargoToml = await readFile(cargoTomlPath, "utf8");
  const match = cargoToml.match(
    /\[workspace\.package\][\s\S]*?^version\s*=\s*"([^"]+)"/m,
  );

  if (!match) {
    throw new Error("Could not find [workspace.package].version in Cargo.toml");
  }

  return match[1];
}

async function updateJsonFile(filePath, updater) {
  const source = await readFile(filePath, "utf8");
  const parsed = JSON.parse(source);
  const updated = updater(parsed);
  const next = `${JSON.stringify(updated, null, 2)}\n`;

  if (next !== source) {
    await writeFile(filePath, next, "utf8");
  }
}

const version = await readWorkspaceVersion();

await updateJsonFile(path.join(workspaceRoot, "opencassava", "package.json"), (json) => ({
  ...json,
  version,
}));

await updateJsonFile(
  path.join(workspaceRoot, "opencassava", "package-lock.json"),
  (json) => ({
    ...json,
    version,
    packages: json.packages
      ? {
          ...json.packages,
          "": json.packages[""]
            ? {
                ...json.packages[""],
                version,
              }
            : json.packages[""],
        }
      : json.packages,
  }),
);

await updateJsonFile(
  path.join(workspaceRoot, "opencassava", "src-tauri", "tauri.conf.json"),
  (json) => ({
    ...json,
    version,
  }),
);

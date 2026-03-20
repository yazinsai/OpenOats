import { spawn } from "node:child_process";
import process from "node:process";

const args = process.argv.slice(2);
const isBuild = args.includes("build");
const powershell = process.platform === "win32" ? "powershell.exe" : "pwsh";
const tauriCommand = process.platform === "win32"
  ? ["cmd.exe", ["/d", "/s", "/c", ".\\node_modules\\.bin\\tauri.cmd", ...args]]
  : ["./node_modules/.bin/tauri", args];

function run(command, commandArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, {
      stdio: "inherit",
      shell: false,
    });

    child.on("exit", (code, signal) => {
      if (signal) {
        reject(new Error(`${command} exited with signal ${signal}`));
        return;
      }
      resolve(code ?? 0);
    });
    child.on("error", reject);
  });
}

async function main() {
  const prepareArgs = ["-ExecutionPolicy", "Bypass", "-File", "./scripts/prepare-whisper.ps1"];
  const cleanupArgs = ["-ExecutionPolicy", "Bypass", "-File", "./scripts/cleanup-whisper.ps1"];

  await run(powershell, prepareArgs);

  let exitCode = 0;
  try {
    exitCode = await run(tauriCommand[0], tauriCommand[1]);
  } finally {
    if (isBuild) {
      await run(powershell, cleanupArgs);
    }
  }

  process.exit(exitCode);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

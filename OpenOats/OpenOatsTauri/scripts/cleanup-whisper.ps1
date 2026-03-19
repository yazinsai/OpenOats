$ErrorActionPreference = "Stop"

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$whisperRoot = Join-Path $workspaceRoot ".build\whisper-rs"

if (Test-Path $whisperRoot) {
  Remove-Item -Recurse -Force $whisperRoot
}

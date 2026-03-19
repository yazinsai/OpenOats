$ErrorActionPreference = "Stop"

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$buildRoot = Join-Path $workspaceRoot ".build"
$whisperRoot = Join-Path $buildRoot "whisper-rs"
$repoUrl = "https://codeberg.org/tazz4843/whisper-rs.git"
$repoCommit = "b202069aa891d8243206f89599c04f0e8e6a3d27"

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

if (Test-Path $whisperRoot) {
  Remove-Item -Recurse -Force $whisperRoot
}

git clone $repoUrl $whisperRoot | Out-Host
git -C $whisperRoot checkout $repoCommit | Out-Host
git -C $whisperRoot submodule update --init --recursive | Out-Host

$sysRoot = Join-Path $whisperRoot "sys"
$sysBuild = Join-Path $sysRoot "build.rs"
$sysBindings = Join-Path $sysRoot "src\bindings.rs"
$commonLogging = Join-Path $whisperRoot "src\common_logging.rs"
$grammar = Join-Path $whisperRoot "src\whisper_grammar.rs"

$buildText = Get-Content $sysBuild -Raw
$buildText = $buildText.Replace(
  'if env::var("WHISPER_DONT_GENERATE_BINDINGS").is_ok() {',
  'if cfg!(target_os = "windows") || env::var("WHISPER_DONT_GENERATE_BINDINGS").is_ok() {'
)
Set-Content -Path $sysBuild -Value $buildText -NoNewline

$bindingsText = Get-Content $sysBindings -Raw
$bindingsText = [regex]::Replace(
  $bindingsText,
  '(?s)const _: \(\) = \{.*?^};\r?\n',
  '',
  [System.Text.RegularExpressions.RegexOptions]::Multiline
)
Set-Content -Path $sysBindings -Value $bindingsText -NoNewline

$commonLoggingText = Get-Content $commonLogging -Raw
$commonLoggingText = $commonLoggingText.Replace("repr(i32)", "repr(u32)")
Set-Content -Path $commonLogging -Value $commonLoggingText -NoNewline

$grammarText = Get-Content $grammar -Raw
$grammarText = $grammarText.Replace("repr(i32)", "repr(u32)")
Set-Content -Path $grammar -Value $grammarText -NoNewline

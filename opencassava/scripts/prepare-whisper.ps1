$ErrorActionPreference = "Stop"

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$buildRoot = Join-Path $workspaceRoot ".build"
$whisperRoot = Join-Path $buildRoot "whisper-rs"
$repoUrl = "https://codeberg.org/tazz4843/whisper-rs.git"
$repoCommit = "b202069aa891d8243206f89599c04f0e8e6a3d27"
$cacheStamp = Join-Path $whisperRoot ".openoats-patched-commit"

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

if (-not (Test-Path $whisperRoot)) {
  git clone $repoUrl $whisperRoot | Out-Host
  git -C $whisperRoot checkout $repoCommit | Out-Host
  git -C $whisperRoot submodule update --init --recursive | Out-Host
} elseif (Test-Path $cacheStamp) {
  $cachedCommit = (Get-Content $cacheStamp -Raw).Trim()
  if ($cachedCommit -ne $repoCommit) {
    Remove-Item -Recurse -Force $whisperRoot
    git clone $repoUrl $whisperRoot | Out-Host
    git -C $whisperRoot checkout $repoCommit | Out-Host
    git -C $whisperRoot submodule update --init --recursive | Out-Host
  }
} elseif (-not (Test-Path (Join-Path $whisperRoot ".git"))) {
  if (Test-Path $whisperRoot) {
    Remove-Item -Recurse -Force $whisperRoot
  }

  git clone $repoUrl $whisperRoot | Out-Host
  git -C $whisperRoot checkout $repoCommit | Out-Host
  git -C $whisperRoot submodule update --init --recursive | Out-Host
}

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
$buildText = $buildText.Replace(
  'let mut bindings = bindgen::Builder::default().header("wrapper.h");',
  'let bindings = bindgen::Builder::default().header("wrapper.h");'
)
Set-Content -Path $sysBuild -Value $buildText -NoNewline

$bindingsText = Get-Content $sysBindings -Raw
$bindingsText = [regex]::Replace(
  $bindingsText,
  '(?s)const _: \(\) = \{.*?^};\r?\n',
  '',
  [System.Text.RegularExpressions.RegexOptions]::Multiline
)
$bindingsText = $bindingsText.Replace(
  'unsafe { ::std::mem::transmute(self._bitfield_1.get(0usize, 24u8) as u32) }',
  'self._bitfield_1.get(0usize, 24u8) as u32 as ::std::os::raw::c_int'
)
$bindingsText = $bindingsText.Replace(
  "unsafe {\r`n            let val: u32 = ::std::mem::transmute(val);\r`n            self._bitfield_1.set(0usize, 24u8, val as u64)\r`n        }",
  "let val = val as u32;\r`n        self._bitfield_1.set(0usize, 24u8, val as u64)"
)
$bindingsText = $bindingsText.Replace(
  "unsafe {\r`n            ::std::mem::transmute(<__BindgenBitfieldUnit<[u8; 3usize]>>::raw_get(\r`n                ::std::ptr::addr_of!((*this)._bitfield_1),\r`n                0usize,\r`n                24u8,\r`n            ) as u32)\r`n        }",
  "<__BindgenBitfieldUnit<[u8; 3usize]>>::raw_get(\r`n            ::std::ptr::addr_of!((*this)._bitfield_1),\r`n            0usize,\r`n            24u8,\r`n        ) as u32 as ::std::os::raw::c_int"
)
$bindingsText = $bindingsText.Replace(
  "unsafe {\r`n            let val: u32 = ::std::mem::transmute(val);\r`n            <__BindgenBitfieldUnit<[u8; 3usize]>>::raw_set(\r`n                ::std::ptr::addr_of_mut!((*this)._bitfield_1),\r`n                0usize,\r`n                24u8,\r`n                val as u64,\r`n            )\r`n        }",
  "let val = val as u32;\r`n        <__BindgenBitfieldUnit<[u8; 3usize]>>::raw_set(\r`n            ::std::ptr::addr_of_mut!((*this)._bitfield_1),\r`n            0usize,\r`n            24u8,\r`n            val as u64,\r`n        )"
)
$bindingsText = $bindingsText.Replace(
  'let _flags2: u32 = unsafe { ::std::mem::transmute(_flags2) };',
  'let _flags2 = _flags2 as u32;'
)
$bindingsText = [regex]::Replace(
  $bindingsText,
  '(?s)pub fn set__flags2\(&mut self, val: ::std::os::raw::c_int\) \{\s*unsafe \{\s*let val: u32 = ::std::mem::transmute\(val\);\s*self\._bitfield_1\.set\(0usize, 24u8, val as u64\)\s*\}\s*\}',
  "pub fn set__flags2(&mut self, val: ::std::os::raw::c_int) {`r`n        let val = val as u32;`r`n        self._bitfield_1.set(0usize, 24u8, val as u64)`r`n    }"
)
$bindingsText = [regex]::Replace(
  $bindingsText,
  '(?s)pub unsafe fn _flags2_raw\(this: \*const Self\) -> ::std::os::raw::c_int \{\s*unsafe \{\s*::std::mem::transmute\(<__BindgenBitfieldUnit<\[u8; 3usize\]>>::raw_get\(\s*::std::ptr::addr_of!\(\(\*this\)\._bitfield_1\),\s*0usize,\s*24u8,\s*\) as u32\)\s*\}\s*\}',
  "pub unsafe fn _flags2_raw(this: *const Self) -> ::std::os::raw::c_int {`r`n        <__BindgenBitfieldUnit<[u8; 3usize]>>::raw_get(`r`n            ::std::ptr::addr_of!((*this)._bitfield_1),`r`n            0usize,`r`n            24u8,`r`n        ) as u32 as ::std::os::raw::c_int`r`n    }"
)
$bindingsText = [regex]::Replace(
  $bindingsText,
  '(?s)pub unsafe fn set__flags2_raw\(this: \*mut Self, val: ::std::os::raw::c_int\) \{\s*unsafe \{\s*let val: u32 = ::std::mem::transmute\(val\);\s*<__BindgenBitfieldUnit<\[u8; 3usize\]>>::raw_set\(\s*::std::ptr::addr_of_mut!\(\(\*this\)\._bitfield_1\),\s*0usize,\s*24u8,\s*val as u64,\s*\)\s*\}\s*\}',
  "pub unsafe fn set__flags2_raw(this: *mut Self, val: ::std::os::raw::c_int) {`r`n        let val = val as u32;`r`n        <__BindgenBitfieldUnit<[u8; 3usize]>>::raw_set(`r`n            ::std::ptr::addr_of_mut!((*this)._bitfield_1),`r`n            0usize,`r`n            24u8,`r`n            val as u64,`r`n        )`r`n    }"
)
Set-Content -Path $sysBindings -Value $bindingsText -NoNewline

$commonLoggingText = Get-Content $commonLogging -Raw
$commonLoggingText = $commonLoggingText.Replace("repr(i32)", "repr(u32)")
Set-Content -Path $commonLogging -Value $commonLoggingText -NoNewline

$grammarText = Get-Content $grammar -Raw
$grammarText = $grammarText.Replace("repr(i32)", "repr(u32)")
Set-Content -Path $grammar -Value $grammarText -NoNewline

Set-Content -Path $cacheStamp -Value $repoCommit -NoNewline

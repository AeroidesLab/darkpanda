[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$V8Archive,
    [Parameter(Mandatory = $true)][string]$V8Version,
    [Parameter(Mandatory = $true)][string]$BoringSslDirectory,
    [Parameter(Mandatory = $true)][string]$CargoVendorDirectory,
    [Parameter(Mandatory = $true)][string]$SkiaSourceDirectory,
    [string]$Zig = "zig",
    [string]$ZigPackageSourceCache = "",
    [string]$Python = "python",
    [string]$CMake = "cmake",
    [string]$Ninja = "ninja",
    [string]$ClangCl = "clang-cl",
    [ValidateSet("ReleaseFast", "ReleaseSafe")][string]$Optimize = "ReleaseFast",
    [ValidateRange(1, 64)][int]$Jobs = 2
)

. (Join-Path $PSScriptRoot "ArtifactSet.Common.ps1")

function Invoke-BuildAcceptanceArtifactSet {
$repoRoot = Resolve-AbsolutePath -Path (Split-Path $PSScriptRoot -Parent) -MustExist
$workspaceRoot = Resolve-AbsolutePath -Path (Split-Path $repoRoot -Parent) -MustExist
$repoDrive = [System.IO.Path]::GetPathRoot($repoRoot)
if ([string]::IsNullOrWhiteSpace($ZigPackageSourceCache)) {
    $ZigPackageSourceCache = Join-Path $workspaceRoot ".cache\zig-windows\p"
}
$zigPath = Resolve-AbsolutePath -Path ((Get-Command $Zig -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$packageSourceCache = Resolve-AbsolutePath -Path $ZigPackageSourceCache -MustExist
$pythonPath = Resolve-AbsolutePath -Path ((Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$cmakePath = Resolve-AbsolutePath -Path ((Get-Command $CMake -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$ninjaPath = Resolve-AbsolutePath -Path ((Get-Command $Ninja -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$clangClPath = Resolve-AbsolutePath -Path ((Get-Command $ClangCl -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$rustcLauncherPath = Resolve-AbsolutePath -Path ((Get-Command rustc -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
$rustSysroot = (& $rustcLauncherPath --print sysroot).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rustSysroot)) { throw "cannot resolve the active Rust sysroot" }
$rustcPath = Resolve-AbsolutePath -Path (Join-Path $rustSysroot "bin\rustc.exe") -MustExist
$cargoPath = Resolve-AbsolutePath -Path (Join-Path $rustSysroot "bin\cargo.exe") -MustExist
$v8Path = Resolve-AbsolutePath -Path $V8Archive -MustExist
$boringRoot = Resolve-AbsolutePath -Path $BoringSslDirectory -MustExist
$cryptoPath = Resolve-AbsolutePath -Path (Join-Path $boringRoot "crypto.lib") -MustExist
$fipsPath = Resolve-AbsolutePath -Path (Join-Path $boringRoot "fipsmodule.lib") -MustExist
$cargoVendorInput = Resolve-AbsolutePath -Path $CargoVendorDirectory -MustExist
$skiaSourcePath = Resolve-AbsolutePath -Path $SkiaSourceDirectory -MustExist
$cacheBackedInputs = @($packageSourceCache, $cargoVendorInput, $skiaSourcePath)
foreach ($path in $cacheBackedInputs) {
    $pathDrive = [System.IO.Path]::GetPathRoot($path)
    if (-not [string]::Equals($pathDrive, $repoDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "cache-backed build input must be on the workspace volume $repoDrive, not $path`: migrate it before building"
    }
}
# rust-skia's Windows GN/Ninja build still passes source paths through
# GetFullPathNameA from a deeply nested Cargo target.  Reject a long input root
# before hashing/copying gigabytes; otherwise the failure appears only when
# compiling Skia encoder sources near the end of the build.
if ($skiaSourcePath.Length -gt 48) {
    throw "SkiaSourceDirectory is too long for the Windows rust-skia build ($($skiaSourcePath.Length) characters); move it to a short path on $repoDrive"
}
if (-not (Test-Path -LiteralPath (Join-Path $skiaSourcePath "bin\gn.exe") -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $skiaSourcePath "src\core\SkCanvas.cpp") -PathType Leaf)) {
    throw "SkiaSourceDirectory is not a complete Skia source/build-tools tree"
}
$boringRepo = Resolve-AbsolutePath -Path (Join-Path $boringRoot "..\..") -MustExist
$contractPath = Resolve-AbsolutePath -Path (Join-Path $repoRoot "artifacts\managed-analysis\turnstile-acceptance-contract-v1.md") -MustExist
$contractExecutable = Resolve-AbsolutePath -Path (Join-Path $repoRoot "tests\ffi_turnstile.py") -MustExist
$v8BuildRepo = Resolve-AbsolutePath -Path (Join-Path $repoRoot "..\zig-v8-fork") -MustExist

if ([string]::IsNullOrWhiteSpace($V8Version)) {
    throw "V8Version must be explicit"
}

$gitHead = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "git rev-parse failed" }
$gitShort = (& git -C $repoRoot rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "git rev-parse --short failed" }
$boringGitHead = (& git -C $boringRepo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "cannot determine the BoringSSL source revision" }
$utc = [DateTime]::UtcNow
$stamp = $utc.ToString("yyyyMMddTHHmmssZ")
$nonce = [Guid]::NewGuid().ToString("N")
$pathNonce = $nonce.Substring(0, 8)
$buildId = "windows-x64-$stamp-$gitShort-$nonce"
$script:CurrentArtifactBuildId = $buildId
$buildVersion = "1.0.0-acceptance.$stamp+$gitShort"
$buildRoot = Join-Path $repoRoot (".a\" + $stamp + "-" + $pathNonce)
$installRoot = Join-Path $buildRoot "i"
$cacheRoot = Join-Path $buildRoot "c"
$globalCacheRoot = Join-Path $buildRoot "g"
$runtimeRoot = Join-Path $buildRoot "r"
$wreqCargoTargetRoot = Join-Path $repoDrive ("dpw\" + $nonce)
$canvasCargoTargetRoot = Join-Path $repoDrive ("dpc\c\" + $nonce)
$activeRoot = Join-Path $repoRoot "artifacts\builds"
New-Item -ItemType Directory -Path $activeRoot -Force -ErrorAction Stop | Out-Null
Write-ArtifactSetState -RepoRoot $repoRoot -State "building" -BuildId $buildId -Detail "fresh source build in progress; no artifact is active"
$activePath = Join-Path $activeRoot "ACTIVE.json"
if (Test-Path -LiteralPath $activePath) {
    $revokedPath = Join-Path $activeRoot ("REVOKED." + $stamp + "." + $nonce + ".json")
    Move-Item -LiteralPath $activePath -Destination $revokedPath -ErrorAction Stop
}

$stopped = @(Stop-ScopedDarkPandaProcesses -RepoRoot $repoRoot)
$sourceBefore = Get-SourceTreeProof -RepoRoot $repoRoot
$v8BuildSourceSelection = @("build.zig", "build.zig.zon", "src", "build-tools")
$boringBuildSourceSelection = @("build.zig", "build.zig.zon")
$v8BuildSourceBefore = Get-SelectedTreeProof -Directory $v8BuildRepo -RelativePaths $v8BuildSourceSelection
$boringBuildSourceBefore = Get-SelectedTreeProof -Directory $boringRepo -RelativePaths $boringBuildSourceSelection
$inputHashesBefore = @{
    v8 = Get-Sha256 -Path $v8Path
    crypto = Get-Sha256 -Path $cryptoPath
    fipsmodule = Get-Sha256 -Path $fipsPath
    cmake = Get-Sha256 -Path $cmakePath
    ninja = Get-Sha256 -Path $ninjaPath
    clangCl = Get-Sha256 -Path $clangClPath
    contract = Get-Sha256 -Path $contractPath
    contractExecutable = Get-Sha256 -Path $contractExecutable
}
$cargoVendorInputBefore = Get-DirectoryTreeProof -Directory $cargoVendorInput
$skiaSourceBefore = Get-DirectoryTreeProof -Directory $skiaSourcePath

foreach ($directory in @($buildRoot, $wreqCargoTargetRoot, $canvasCargoTargetRoot)) {
    if (Test-Path -LiteralPath $directory) {
        throw "unique build directory already exists: $directory"
    }
}
foreach ($directory in @($buildRoot, $installRoot, $cacheRoot, $globalCacheRoot, $runtimeRoot, $wreqCargoTargetRoot, $canvasCargoTargetRoot)) {
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
}

# Reuse only content-addressed dependency sources. Never import compiler
# objects, metadata, binaries, or an earlier install.
$isolatedPackageRoot = Join-Path $globalCacheRoot "p"
New-Item -ItemType Directory -Path $isolatedPackageRoot -ErrorAction Stop | Out-Null
Get-ChildItem -LiteralPath $packageSourceCache -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $isolatedPackageRoot -Recurse -Force -ErrorAction Stop
}
$dependencySourcesBefore = Get-DirectoryTreeProof -Directory $isolatedPackageRoot

# Copy the pre-materialized Cargo.lock-selected source packages into this
# unique build. Acquisition is deliberately outside this script: an
# acceptance build is network-disabled from its first Cargo invocation and
# cannot silently fetch or substitute a package.
$cargoVendorRoot = Join-Path $buildRoot "cv"
$isolatedCargoHome = Join-Path $buildRoot "ch"
$isolatedUserHome = Join-Path $buildRoot "user"
$isolatedLocalAppData = Join-Path $buildRoot "local-app-data"
$isolatedAppData = Join-Path $buildRoot "app-data"
$isolatedTemp = Join-Path $buildRoot "tmp"
$cargoVendorLog = Join-Path $buildRoot "cargo-vendor.log"
New-Item -ItemType Directory -Path $cargoVendorRoot -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $isolatedCargoHome -ErrorAction Stop | Out-Null
foreach ($directory in @($isolatedUserHome, $isolatedLocalAppData, $isolatedAppData, $isolatedTemp)) {
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
}
Get-ChildItem -LiteralPath $cargoVendorInput -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $cargoVendorRoot -Recurse -Force -ErrorAction Stop
}
$cargoVendorBefore = Get-DirectoryTreeProof -Directory $cargoVendorRoot
if ($cargoVendorBefore.digest -ne $cargoVendorInputBefore.digest -or
    $cargoVendorBefore.fileCount -ne $cargoVendorInputBefore.fileCount) {
    throw "copied Cargo vendor tree does not match its proven source input"
}
$cargoVendorPreparationPath = Join-Path $buildRoot "cargo-vendor-preparation.json"
$prepareCargoVendorScript = Resolve-AbsolutePath -Path (Join-Path $repoRoot "tools\prepare_cargo_vendor.py") -MustExist
$cargoVendorPreparationOutput = @(& $pythonPath $prepareCargoVendorScript $cargoVendorRoot 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "deterministic Cargo vendor preparation failed: $($cargoVendorPreparationOutput -join [Environment]::NewLine)"
}
Write-Utf8NoBom -Path $cargoVendorPreparationPath -Text (($cargoVendorPreparationOutput -join "`n") + "`n")
$cargoVendorPreparation = Get-Content -LiteralPath $cargoVendorPreparationPath -Raw | ConvertFrom-Json
if ($cargoVendorPreparation.schema -ne "darkpanda-cargo-vendor-preparation/v1") {
    throw "unexpected Cargo vendor preparation record"
}
$cargoVendorPreparedBefore = Get-DirectoryTreeProof -Directory $cargoVendorRoot
Write-Utf8NoBom -Path $cargoVendorLog -Text ((@(
    "schema=darkpanda-cargo-vendor-import/v1",
    "importedFrom=$cargoVendorInput",
    "sourceDigest=$($cargoVendorInputBefore.digest)",
    "sourceFileCount=$($cargoVendorInputBefore.fileCount)",
    "networkPolicy=offline-only"
) -join "`r`n") + "`r`n")
$skiaBindings = @(Get-ChildItem -LiteralPath $cargoVendorRoot -Directory -Filter "skia-bindings-0.99.0" -ErrorAction Stop)
if ($skiaBindings.Count -ne 1) {
    throw "Cargo vendor input must contain exactly skia-bindings-0.99.0"
}
if (-not (Test-Path -LiteralPath (Join-Path $skiaSourcePath "bin\gn.exe") -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $skiaSourcePath "src\core\SkCanvas.cpp") -PathType Leaf)) {
    throw "SkiaSourceDirectory is not a complete Skia source/build-tools tree"
}
$cargoVendorTomlPath = $cargoVendorRoot.Replace('\', '/')
$cargoConfig = @"
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$cargoVendorTomlPath"

[net]
offline = true
"@
Write-Utf8NoBom -Path (Join-Path $isolatedCargoHome "config.toml") -Text $cargoConfig

$buildLog = Join-Path $buildRoot "build.log"
$zigArgs = @(
    "build",
    "install",
    "canvas-backend",
    "-j$Jobs",
    "-Dtarget=x86_64-windows-msvc",
    "-Doptimize=$Optimize",
    "-Dprebuilt_v8_path=$v8Path",
    "-Dprebuilt_boringssl_dir=$boringRoot",
    "-Dwreq_transport_target_dir=$wreqCargoTargetRoot",
    "-Dcanvas_backend_target_dir=$canvasCargoTargetRoot",
    "-Dcargo_path=$cargoPath",
    "-Dversion=$buildVersion",
    "-p", $installRoot,
    "--cache-dir", $cacheRoot,
    "--global-cache-dir", $globalCacheRoot,
    "--summary", "all"
)

$cargoEnvironmentNames = @(
    "CARGO_HOME",
    "CARGO_INCREMENTAL",
    "CARGO_BUILD_JOBS",
    "CARGO_TARGET_DIR",
    "CARGO_NET_OFFLINE",
    "RUSTC_WRAPPER",
    "RUSTC_WORKSPACE_WRAPPER",
    "RUSTC",
    "RUSTFLAGS",
    "CARGO_ENCODED_RUSTFLAGS",
    "CMAKE",
    "CMAKE_GENERATOR",
    "CMAKE_BUILD_PARALLEL_LEVEL",
    "CC",
    "CXX",
    "SKIA_SOURCE_DIR",
    "FORCE_SKIA_BUILD",
    "SKIA_NINJA_COMMAND",
    "SKIA_GN_COMMAND",
    "PATH",
    "LOCALAPPDATA",
    "APPDATA",
    "USERPROFILE",
    "HOME",
    "TEMP",
    "TMP",
    "XDG_CACHE_HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "NO_PROXY",
    "no_proxy",
    "GIT_TERMINAL_PROMPT"
)
$cargoEnvironmentBefore = @{}
foreach ($name in $cargoEnvironmentNames) {
    $cargoEnvironmentBefore[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
}
[System.Environment]::SetEnvironmentVariable("CARGO_HOME", $isolatedCargoHome, "Process")
[System.Environment]::SetEnvironmentVariable("CARGO_INCREMENTAL", "0", "Process")
[System.Environment]::SetEnvironmentVariable("CARGO_BUILD_JOBS", [string]$Jobs, "Process")
[System.Environment]::SetEnvironmentVariable("CARGO_TARGET_DIR", $null, "Process")
[System.Environment]::SetEnvironmentVariable("CARGO_NET_OFFLINE", "true", "Process")
[System.Environment]::SetEnvironmentVariable("RUSTC_WRAPPER", $null, "Process")
[System.Environment]::SetEnvironmentVariable("RUSTC_WORKSPACE_WRAPPER", $null, "Process")
[System.Environment]::SetEnvironmentVariable("RUSTC", $rustcPath, "Process")
[System.Environment]::SetEnvironmentVariable("RUSTFLAGS", $null, "Process")
[System.Environment]::SetEnvironmentVariable("CARGO_ENCODED_RUSTFLAGS", $null, "Process")
[System.Environment]::SetEnvironmentVariable("CMAKE", $cmakePath, "Process")
[System.Environment]::SetEnvironmentVariable("CMAKE_GENERATOR", "Ninja", "Process")
[System.Environment]::SetEnvironmentVariable("CMAKE_BUILD_PARALLEL_LEVEL", [string]$Jobs, "Process")
[System.Environment]::SetEnvironmentVariable("CC", $clangClPath, "Process")
[System.Environment]::SetEnvironmentVariable("CXX", $clangClPath, "Process")
[System.Environment]::SetEnvironmentVariable("SKIA_SOURCE_DIR", $skiaSourcePath, "Process")
[System.Environment]::SetEnvironmentVariable("FORCE_SKIA_BUILD", "1", "Process")
[System.Environment]::SetEnvironmentVariable("SKIA_NINJA_COMMAND", $ninjaPath, "Process")
[System.Environment]::SetEnvironmentVariable("SKIA_GN_COMMAND", (Join-Path $skiaSourcePath "bin\gn.exe"), "Process")
$buildToolPath = @((Split-Path $ninjaPath -Parent), (Split-Path $clangClPath -Parent)) -join [System.IO.Path]::PathSeparator
[System.Environment]::SetEnvironmentVariable("PATH", ($buildToolPath + [System.IO.Path]::PathSeparator + $cargoEnvironmentBefore["PATH"]), "Process")
[System.Environment]::SetEnvironmentVariable("LOCALAPPDATA", $isolatedLocalAppData, "Process")
[System.Environment]::SetEnvironmentVariable("APPDATA", $isolatedAppData, "Process")
[System.Environment]::SetEnvironmentVariable("USERPROFILE", $isolatedUserHome, "Process")
[System.Environment]::SetEnvironmentVariable("HOME", $isolatedUserHome, "Process")
[System.Environment]::SetEnvironmentVariable("TEMP", $isolatedTemp, "Process")
[System.Environment]::SetEnvironmentVariable("TMP", $isolatedTemp, "Process")
[System.Environment]::SetEnvironmentVariable("XDG_CACHE_HOME", $isolatedLocalAppData, "Process")
$offlineProxy = "http://127.0.0.1:9"
foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")) {
    [System.Environment]::SetEnvironmentVariable($name, $offlineProxy, "Process")
}
[System.Environment]::SetEnvironmentVariable("NO_PROXY", "", "Process")
[System.Environment]::SetEnvironmentVariable("no_proxy", "", "Process")
[System.Environment]::SetEnvironmentVariable("GIT_TERMINAL_PROMPT", "0", "Process")

try {
    $buildResult = Invoke-RecordedProcess `
        -FilePath $zigPath `
        -Arguments $zigArgs `
        -WorkingDirectory $repoRoot `
        -LogPath $buildLog
    $buildExit = $buildResult.ExitCode
    $buildExitHex = $buildResult.ExitCodeHex
    Write-Host "ZIG_BUILD_EXIT=$buildExit ($buildExitHex) LOG=$buildLog"
} finally {
    foreach ($name in $cargoEnvironmentNames) {
        [System.Environment]::SetEnvironmentVariable($name, $cargoEnvironmentBefore[$name], "Process")
    }
}
if ($buildExit -ne 0) {
    throw "clean acceptance build failed with exit code $buildExit ($buildExitHex); log=$buildLog; no artifact set was activated"
}

$sourceAfter = Get-SourceTreeProof -RepoRoot $repoRoot
if ($sourceAfter.digest -ne $sourceBefore.digest -or $sourceAfter.fileCount -ne $sourceBefore.fileCount) {
    throw "source build inputs changed while compiling; no artifact set was activated"
}
$v8BuildSourceAfter = Get-SelectedTreeProof -Directory $v8BuildRepo -RelativePaths $v8BuildSourceSelection
$boringBuildSourceAfter = Get-SelectedTreeProof -Directory $boringRepo -RelativePaths $boringBuildSourceSelection
if ($v8BuildSourceAfter.digest -ne $v8BuildSourceBefore.digest -or
    $v8BuildSourceAfter.fileCount -ne $v8BuildSourceBefore.fileCount -or
    $boringBuildSourceAfter.digest -ne $boringBuildSourceBefore.digest -or
    $boringBuildSourceAfter.fileCount -ne $boringBuildSourceBefore.fileCount) {
    throw "a local Zig dependency source tree changed while compiling; no artifact set was activated"
}
$dependencySourcesAfter = Get-DirectoryTreeProof -Directory $isolatedPackageRoot
if ($dependencySourcesAfter.digest -ne $dependencySourcesBefore.digest -or
    $dependencySourcesAfter.fileCount -ne $dependencySourcesBefore.fileCount) {
    throw "dependency source package tree changed while compiling; no artifact set was activated"
}
$cargoVendorAfter = Get-DirectoryTreeProof -Directory $cargoVendorRoot
if ($cargoVendorAfter.digest -ne $cargoVendorPreparedBefore.digest -or
    $cargoVendorAfter.fileCount -ne $cargoVendorPreparedBefore.fileCount) {
    throw "vendored Cargo source tree changed while compiling; no artifact set was activated"
}
$cargoVendorInputAfter = Get-DirectoryTreeProof -Directory $cargoVendorInput
if ($cargoVendorInputAfter.digest -ne $cargoVendorInputBefore.digest -or
    $cargoVendorInputAfter.fileCount -ne $cargoVendorInputBefore.fileCount) {
    throw "Cargo vendor input changed while compiling; no artifact set was activated"
}
$skiaSourceAfter = Get-DirectoryTreeProof -Directory $skiaSourcePath
if ($skiaSourceAfter.digest -ne $skiaSourceBefore.digest -or
    $skiaSourceAfter.fileCount -ne $skiaSourceBefore.fileCount) {
    throw "Skia source input changed while compiling; no artifact set was activated"
}
if ((Get-Sha256 -Path $v8Path) -ne $inputHashesBefore.v8 -or
    (Get-Sha256 -Path $cryptoPath) -ne $inputHashesBefore.crypto -or
    (Get-Sha256 -Path $fipsPath) -ne $inputHashesBefore.fipsmodule -or
    (Get-Sha256 -Path $cmakePath) -ne $inputHashesBefore.cmake -or
    (Get-Sha256 -Path $ninjaPath) -ne $inputHashesBefore.ninja -or
    (Get-Sha256 -Path $clangClPath) -ne $inputHashesBefore.clangCl -or
    (Get-Sha256 -Path $contractPath) -ne $inputHashesBefore.contract -or
    (Get-Sha256 -Path $contractExecutable) -ne $inputHashesBefore.contractExecutable) {
    throw "a pinned build input changed while compiling; no artifact set was activated"
}

$binRoot = Join-Path $installRoot "bin"
$browserExe = Resolve-AbsolutePath -Path (Join-Path $binRoot "darkpanda.exe") -MustExist
$ffiDll = Resolve-AbsolutePath -Path (Join-Path $binRoot "darkpanda.dll") -MustExist
$wreqDll = Resolve-AbsolutePath -Path (Join-Path $binRoot "wreq.dll") -MustExist
$htmlDll = Resolve-AbsolutePath -Path (Join-Path $binRoot "darkpanda_html5ever.dll") -MustExist
$canvasDll = Resolve-AbsolutePath -Path (Join-Path $binRoot "darkpanda_canvas_backend.dll") -MustExist

function New-ArtifactRecord {
    param(
        [string]$Role,
        [string]$Path,
        [string]$Version,
        [string]$Kind,
        [string]$ExpectedSha256
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $actualSha256 = Get-Sha256 -Path $item.FullName
    if ($ExpectedSha256 -and $actualSha256 -ne $ExpectedSha256) {
        throw "artifact '$Role' changed since its hash was recorded"
    }
    return [ordered]@{
        role = $Role
        kind = $Kind
        path = $item.FullName
        version = $Version
        size = [int64]$item.Length
        sha256 = $actualSha256
    }
}

$candidateArtifactRecords = @(
    (New-ArtifactRecord -Role "browser_exe" -Path $browserExe -Version $buildVersion -Kind "runtime-output"),
    (New-ArtifactRecord -Role "ffi_dll" -Path $ffiDll -Version $buildVersion -Kind "runtime-output"),
    (New-ArtifactRecord -Role "wreq_library" -Path $wreqDll -Version "pending runtime attestation" -Kind "runtime-output"),
    (New-ArtifactRecord -Role "canvas_backend_library" -Path $canvasDll -Version "pending runtime attestation" -Kind "runtime-output"),
    (New-ArtifactRecord -Role "html_parser_dll" -Path $htmlDll -Version "$buildVersion; source-built" -Kind "runtime-output")
)
$candidateArtifactPath = Join-Path $buildRoot "candidate-artifacts.json"
$candidateArtifactRecord = [ordered]@{
    schema = "darkpanda-candidate-artifact-set/v1"
    buildId = $buildId
    target = "x86_64-windows-msvc"
    version = $buildVersion
    artifacts = $candidateArtifactRecords
}
Write-Utf8NoBom -Path $candidateArtifactPath -Text (($candidateArtifactRecord | ConvertTo-Json -Depth 8) + "`n")

function Assert-CandidateArtifacts {
    foreach ($artifact in $candidateArtifactRecords) {
        $item = Get-Item -LiteralPath $artifact.path -ErrorAction Stop
        if ([int64]$item.Length -ne [int64]$artifact.size -or
            (Get-Sha256 -Path $item.FullName) -ne [string]$artifact.sha256) {
            throw "candidate artifact changed before or during testing: $($item.FullName)"
        }
    }
}

$null = Stop-ScopedDarkPandaProcesses -RepoRoot $repoRoot
Assert-CandidateArtifacts
$runtimeVersion = (& $browserExe version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $runtimeVersion -ne $buildVersion) {
    throw "fresh executable version mismatch; expected '$buildVersion', got '$runtimeVersion'"
}
$ffiAbiMatch = Select-String -LiteralPath (Join-Path $repoRoot "include\darkpanda.h") -Pattern '^#define DP_ABI_VERSION\s+(\d+)u' | Select-Object -First 1
if (-not $ffiAbiMatch) { throw "cannot determine DP_ABI_VERSION" }
$ffiAbi = $ffiAbiMatch.Matches[0].Groups[1].Value
$wreqAbiMatch = Select-String -LiteralPath (Join-Path $repoRoot "src\wreq_transport\include\wreq_transport.h") -Pattern '^#define WREQ_TRANSPORT_ABI_VERSION\s+(\d+)u' | Select-Object -First 1
if (-not $wreqAbiMatch) { throw "cannot determine WREQ_TRANSPORT_ABI_VERSION" }
$wreqAbi = $wreqAbiMatch.Matches[0].Groups[1].Value
$wreqVersionLine = Select-String -LiteralPath (Join-Path $repoRoot "src\wreq_transport\src\lib.rs") -Pattern 'b"(libwreq/[^\"]*)\\0";' | Select-Object -First 1
if (-not $wreqVersionLine) { throw "cannot determine the source wreq transport version" }
$wreqVersion = $wreqVersionLine.Matches[0].Groups[1].Value

$acceptanceRuntimeRoot = Join-Path $buildRoot "acceptance"
$acceptancePythonRoot = Join-Path $acceptanceRuntimeRoot "python"
$acceptancePackageRoot = Join-Path $acceptancePythonRoot "darkpanda"
$acceptanceExecutable = Join-Path $acceptanceRuntimeRoot "ffi_turnstile.py"
New-Item -ItemType Directory -Path $acceptancePackageRoot -ErrorAction Stop | Out-Null
Copy-Item -LiteralPath $contractExecutable -Destination $acceptanceExecutable -ErrorAction Stop
$sourcePythonPackage = Join-Path $repoRoot "python\darkpanda"
foreach ($sourceFile in Get-ChildItem -LiteralPath $sourcePythonPackage -File -Recurse -Force) {
    if ($sourceFile.Extension -ne ".py" -or $sourceFile.FullName -match '(^|[\\/])__pycache__([\\/]|$)') {
        continue
    }
    $relative = $sourceFile.FullName.Substring($sourcePythonPackage.Length).TrimStart([char[]]@('\', '/'))
    $destination = Join-Path $acceptancePackageRoot $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -ErrorAction Stop
}
$acceptanceRuntimeProof = Get-DirectoryTreeProof -Directory $acceptanceRuntimeRoot
if ((Get-Sha256 -Path $acceptanceExecutable) -ne $inputHashesBefore.contractExecutable) {
    throw "frozen acceptance executable is not byte-identical to its proven source"
}

$buildAttestationStateRoot = Join-Path $buildRoot "attestation-state"
$runtimeAttestation = Get-RuntimeArtifactAttestation `
    -PythonPath $pythonPath `
    -PythonRoot $acceptancePythonRoot `
    -FfiPath $ffiDll `
    -WreqPath $wreqDll `
    -CanvasPath $canvasDll `
    -StateRoot $buildAttestationStateRoot
if ([uint32]$runtimeAttestation.ffiAbiVersion -ne [uint32]$ffiAbi) {
    throw "fresh FFI DLL ABI does not match include/darkpanda.h"
}
if ([string]$runtimeAttestation.ffiVersion -ne $buildVersion) {
    throw "fresh FFI DLL build version does not match the unique build version"
}
if ([uint32]$runtimeAttestation.wreqAbiVersion -ne [uint32]$wreqAbi) {
    throw "fresh wreq DLL ABI does not match wreq_transport.h"
}
if ([uint32]$runtimeAttestation.canvasAbiVersion -ne 2 -or
    [string]$runtimeAttestation.canvasVersion -notmatch 'rust-skia/0\.99\.0' -or
    (@($runtimeAttestation.canvasPixels) -join ',') -ne '17,99,201,255') {
    throw "fresh dynamic rust-skia Canvas attestation failed"
}
if ([string]$runtimeAttestation.wreqVersion -ne $wreqVersion) {
    throw "fresh wreq DLL version does not match the source version string"
}
$actualV8Version = [string]$runtimeAttestation.identity.javascriptRuntime.actualV8Version
$declaredV8Version = [string]$runtimeAttestation.identity.profile.declaredV8Version
if ([string]::IsNullOrWhiteSpace($actualV8Version) -or $actualV8Version -ne $declaredV8Version) {
    throw "fresh V8 runtime version does not match the Chrome 149 profile: actual='$actualV8Version' declared='$declaredV8Version'"
}
if (-not ($runtimeAttestation.identity.consistency.allNonTlsAttestedChecksPass -is [bool]) -or
    -not [bool]$runtimeAttestation.identity.consistency.allNonTlsAttestedChecksPass) {
    throw "fresh runtime identity consistency checks did not pass"
}
$runtimeAttestationPath = Join-Path $buildRoot "runtime-attestation.json"
Write-Utf8NoBom -Path $runtimeAttestationPath -Text (($runtimeAttestation | ConvertTo-Json -Depth 20) + "`n")
Assert-CandidateArtifacts

function Get-CandidateArtifactHash {
    param([Parameter(Mandatory = $true)][string]$Role)
    $matches = @($candidateArtifactRecords | Where-Object { $_.role -eq $Role })
    if ($matches.Count -ne 1) { throw "candidate artifact role is not unique: $Role" }
    return [string]$matches[0].sha256
}

$sourceProofPath = Join-Path $buildRoot "source-files.sha256"
Write-Utf8NoBom -Path $sourceProofPath -Text $sourceAfter.canonical
$manifestPath = Join-Path $buildRoot "manifest.json"
$manifest = [ordered]@{
    schema = $script:ArtifactSetSchema
    buildId = $buildId
    activated = $true
    createdAtUtc = $utc.ToString("o")
    repoRoot = $repoRoot
    buildRoot = $buildRoot
    runtimeBinRoot = $binRoot
    runtimeStateRoot = $runtimeRoot
    buildScratch = [ordered]@{
        wreqCargoTargetRoot = $wreqCargoTargetRoot
        canvasCargoTargetRoot = $canvasCargoTargetRoot
        isolatedCargoHome = $isolatedCargoHome
        buildAttestationStateRoot = $buildAttestationStateRoot
        policy = "unique source-build intermediates only; never accepted as runtime artifacts"
    }
    target = "x86_64-windows-msvc"
    optimize = $Optimize
    buildVersion = $buildVersion
    git = [ordered]@{
        head = $gitHead
        short = $gitShort
        dirty = ((& git -C $repoRoot status --porcelain=v1).Count -ne 0)
    }
    toolchain = [ordered]@{
        zigPath = $zigPath
        zigVersion = (& $zigPath version).Trim()
        zigSha256 = Get-Sha256 -Path $zigPath
        cargoPath = $cargoPath
        cargoVersion = (& $cargoPath --version).Trim()
        cargoSha256 = Get-Sha256 -Path $cargoPath
        rustcPath = $rustcPath
        rustcVersion = (& $rustcPath --version).Trim()
        rustcSha256 = Get-Sha256 -Path $rustcPath
        pythonPath = $pythonPath
        pythonVersion = (& $pythonPath -I -B -S --version 2>&1 | Out-String).Trim()
        pythonSha256 = Get-Sha256 -Path $pythonPath
        cmakePath = $cmakePath
        cmakeVersion = (& $cmakePath --version | Select-Object -First 1)
        cmakeSha256 = Get-Sha256 -Path $cmakePath
        ninjaPath = $ninjaPath
        ninjaVersion = (& $ninjaPath --version).Trim()
        ninjaSha256 = Get-Sha256 -Path $ninjaPath
        clangClPath = $clangClPath
        clangClVersion = (& $clangClPath --version | Select-Object -First 1)
        clangClSha256 = Get-Sha256 -Path $clangClPath
    }
    command = @($zigPath) + $zigArgs
    buildParallelism = [ordered]@{
        zigJobs = $Jobs
        cargoBuildJobs = $Jobs
        cmakeBuildParallelLevel = $Jobs
    }
    oldProcessesStopped = $stopped
    sourceProof = [ordered]@{
        digest = $sourceAfter.digest
        fileCount = $sourceAfter.fileCount
        path = $sourceProofPath
        sha256 = Get-Sha256 -Path $sourceProofPath
    }
    dependencySourceProof = [ordered]@{
        policy = "content-addressed source packages only; no compiler objects or installed binaries reused"
        importedFrom = $packageSourceCache
        path = $isolatedPackageRoot
        digest = $dependencySourcesAfter.digest
        fileCount = $dependencySourcesAfter.fileCount
    }
    localDependencySourceProofs = @(
        [ordered]@{
            name = "zig-v8-fork"
            path = $v8BuildRepo
            selection = $v8BuildSourceSelection
            digest = $v8BuildSourceAfter.digest
            fileCount = $v8BuildSourceAfter.fileCount
        },
        [ordered]@{
            name = "boringssl-zig-fork"
            path = $boringRepo
            selection = $boringBuildSourceSelection
            digest = $boringBuildSourceAfter.digest
            fileCount = $boringBuildSourceAfter.fileCount
        }
    )
    cargoSourceProof = [ordered]@{
        policy = "pre-materialized Cargo.lock-selected sources copied and compiled offline; rust-skia uses the vendored Skia source tree; no compiler cache or wrapper"
        importedFrom = $cargoVendorInput
        importedFromDigest = $cargoVendorInputBefore.digest
        importedFromFileCount = $cargoVendorInputBefore.fileCount
        path = $cargoVendorRoot
        digest = $cargoVendorAfter.digest
        fileCount = $cargoVendorAfter.fileCount
        preparationPath = $cargoVendorPreparationPath
        preparationSha256 = Get-Sha256 -Path $cargoVendorPreparationPath
        preparation = $cargoVendorPreparation
        vendorLogPath = $cargoVendorLog
        vendorLogSha256 = Get-Sha256 -Path $cargoVendorLog
        wreqCargoLockPath = (Join-Path $repoRoot "src\wreq_transport\Cargo.lock")
        wreqCargoLockSha256 = Get-Sha256 -Path (Join-Path $repoRoot "src\wreq_transport\Cargo.lock")
        htmlCargoLockPath = (Join-Path $repoRoot "src\html5ever\Cargo.lock")
        htmlCargoLockSha256 = Get-Sha256 -Path (Join-Path $repoRoot "src\html5ever\Cargo.lock")
        canvasCargoLockPath = (Join-Path $repoRoot "src\canvas_backend\Cargo.lock")
        canvasCargoLockSha256 = Get-Sha256 -Path (Join-Path $repoRoot "src\canvas_backend\Cargo.lock")
    }
    skiaSourceProof = [ordered]@{
        policy = "pinned source-only input; compiled offline in the unique Cargo target directory"
        path = $skiaSourcePath
        digest = $skiaSourceAfter.digest
        fileCount = $skiaSourceAfter.fileCount
    }
    buildLog = [ordered]@{
        path = $buildLog
        sha256 = Get-Sha256 -Path $buildLog
    }
    acceptanceContract = [ordered]@{
        version = $script:AcceptanceContractVersion
        path = $contractPath
        sha256 = $inputHashesBefore.contract
        sourceExecutablePath = $contractExecutable
        sourceExecutableSha256 = $inputHashesBefore.contractExecutable
        runtimeRoot = $acceptanceRuntimeRoot
        runtimePythonRoot = $acceptancePythonRoot
        runtimeTreeDigest = $acceptanceRuntimeProof.digest
        runtimeTreeFileCount = $acceptanceRuntimeProof.fileCount
        executablePath = $acceptanceExecutable
        executableSha256 = Get-Sha256 -Path $acceptanceExecutable
    }
    runtimeAttestation = [ordered]@{
        path = $runtimeAttestationPath
        sha256 = Get-Sha256 -Path $runtimeAttestationPath
        ffiAbiVersion = [uint32]$runtimeAttestation.ffiAbiVersion
        ffiVersion = [string]$runtimeAttestation.ffiVersion
        wreqAbiVersion = [uint32]$runtimeAttestation.wreqAbiVersion
        wreqVersion = [string]$runtimeAttestation.wreqVersion
        canvasAbiVersion = [uint32]$runtimeAttestation.canvasAbiVersion
        canvasVersion = [string]$runtimeAttestation.canvasVersion
        canvasPixels = @($runtimeAttestation.canvasPixels | ForEach-Object { [uint32]$_ })
        actualV8Version = $actualV8Version
        declaredV8Version = $declaredV8Version
        allNonTlsAttestedChecksPass = [bool]$runtimeAttestation.identity.consistency.allNonTlsAttestedChecksPass
    }
    candidateArtifactRecord = [ordered]@{
        path = $candidateArtifactPath
        sha256 = Get-Sha256 -Path $candidateArtifactPath
        verifiedBeforeAndAfterRuntimeAttestation = $true
    }
    artifacts = @(
        (New-ArtifactRecord -Role "browser_exe" -Path $browserExe -Version $buildVersion -Kind "runtime-output" -ExpectedSha256 (Get-CandidateArtifactHash -Role "browser_exe")),
        (New-ArtifactRecord -Role "ffi_dll" -Path $ffiDll -Version "$($runtimeAttestation.ffiVersion); DP ABI $ffiAbi" -Kind "runtime-output" -ExpectedSha256 (Get-CandidateArtifactHash -Role "ffi_dll")),
        (New-ArtifactRecord -Role "wreq_library" -Path $wreqDll -Version "$wreqVersion; ABI $wreqAbi" -Kind "runtime-output" -ExpectedSha256 (Get-CandidateArtifactHash -Role "wreq_library")),
        (New-ArtifactRecord -Role "canvas_backend_library" -Path $canvasDll -Version "$($runtimeAttestation.canvasVersion); ABI $($runtimeAttestation.canvasAbiVersion)" -Kind "runtime-output" -ExpectedSha256 (Get-CandidateArtifactHash -Role "canvas_backend_library")),
        (New-ArtifactRecord -Role "html_parser_dll" -Path $htmlDll -Version "$buildVersion; source-built" -Kind "runtime-output" -ExpectedSha256 (Get-CandidateArtifactHash -Role "html_parser_dll")),
        (New-ArtifactRecord -Role "v8_archive" -Path $v8Path -Version "$V8Version; runtime $actualV8Version" -Kind "pinned-build-input" -ExpectedSha256 $inputHashesBefore.v8),
        (New-ArtifactRecord -Role "boringssl_crypto_archive" -Path $cryptoPath -Version "BoringSSL source $boringGitHead (WebCrypto only)" -Kind "pinned-build-input" -ExpectedSha256 $inputHashesBefore.crypto),
        (New-ArtifactRecord -Role "boringssl_fipsmodule_archive" -Path $fipsPath -Version "BoringSSL source $boringGitHead (WebCrypto only)" -Kind "pinned-build-input" -ExpectedSha256 $inputHashesBefore.fipsmodule)
    )
}
Write-Utf8NoBom -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 12) + "`n")

# Activation is the sole validity selector. Existing directories may remain for
# audit, but no test helper accepts a manifest not named by this pointer.
$null = Assert-ArtifactManifestContents -ManifestPath $manifestPath
$active = [ordered]@{
    schema = "darkpanda-active-artifact-set/v1"
    state = "active"
    buildId = $buildId
    activatedAtUtc = [DateTime]::UtcNow.ToString("o")
    manifestPath = $manifestPath
    manifestSha256 = Get-Sha256 -Path $manifestPath
}
$activeTemporary = Join-Path $activeRoot ("ACTIVE." + [Guid]::NewGuid().ToString("N") + ".tmp")
Write-Utf8NoBom -Path $activeTemporary -Text (($active | ConvertTo-Json -Depth 4) + "`n")
Move-Item -LiteralPath $activeTemporary -Destination (Join-Path $activeRoot "ACTIVE.json") -Force
Write-ArtifactSetState -RepoRoot $repoRoot -State "active" -BuildId $buildId -ManifestPath $manifestPath -Detail "manifest published; final active verification in progress"

try {
    $verified = Assert-ArtifactSet -ManifestPath $manifestPath
} catch {
    $publishedPath = Join-Path $activeRoot "ACTIVE.json"
    if (Test-Path -LiteralPath $publishedPath) {
        try {
            $published = Get-Content -LiteralPath $publishedPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($published.buildId -eq $buildId) {
                Remove-Item -LiteralPath $publishedPath -Force -ErrorAction Stop
            }
        } catch {}
    }
    throw
}
Write-ArtifactSetState -RepoRoot $repoRoot -State "active" -BuildId $buildId -ManifestPath $manifestPath -Detail "manifest contents and ACTIVE pointer verified"
Write-Host "ACTIVE_ARTIFACT_SET=$($verified.manifestPath)"
Write-Host "ACTIVE_MANIFEST_SHA256=$($verified.manifestSha256)"
}

$lockRepoRoot = Resolve-AbsolutePath -Path (Split-Path $PSScriptRoot -Parent) -MustExist
$script:CurrentArtifactBuildId = "uninitialized-" + [Guid]::NewGuid().ToString("N")
$artifactSetLock = Enter-ArtifactSetLock -RepoRoot $lockRepoRoot
try {
    Invoke-BuildAcceptanceArtifactSet
} catch {
    $publishedPath = Join-Path $lockRepoRoot "artifacts\builds\ACTIVE.json"
    if (Test-Path -LiteralPath $publishedPath) {
        try {
            $published = Get-Content -LiteralPath $publishedPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($published.buildId -eq $script:CurrentArtifactBuildId) {
                Remove-Item -LiteralPath $publishedPath -Force -ErrorAction Stop
            }
        } catch {}
    }
    try {
        Write-ArtifactSetState `
            -RepoRoot $lockRepoRoot `
            -State "failed" `
            -BuildId $script:CurrentArtifactBuildId `
            -Detail $_.Exception.Message
    } catch {}
    throw
} finally {
    $artifactSetLock.Dispose()
}

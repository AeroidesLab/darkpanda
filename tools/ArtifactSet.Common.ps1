Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ArtifactSetSchema = "darkpanda-artifact-set/v1"
$script:AcceptanceContractVersion = "turnstile-client-acceptance-v1"

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path (Get-Location).Path $Path
    }
    $full = [System.IO.Path]::GetFullPath($candidate)
    if ($MustExist) {
        return (Resolve-Path -LiteralPath $full -ErrorAction Stop).Path
    }
    return $full
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $fullPath.StartsWith(
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Get-TreeEntrySha256 {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    if (($File.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $targets = @($File.Target | ForEach-Object { [string]$_ }) -join "`n"
        return Get-TextSha256 -Text ("reparse`n{0}`n{1}`n" -f [string]$File.LinkType, $targets)
    }
    return Get-Sha256 -Path $File.FullName
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function ConvertTo-NativeCommandLineArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    # CommandLineToArgvW-compatible quoting. Backslashes only need doubling
    # before a quote or the closing quote.
    $quoted = New-Object System.Text.StringBuilder
    [void]$quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * (($backslashes * 2) + 1)))
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$quoted.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$quoted.Append(('\' * ($backslashes * 2)))
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-RecordedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $executable = Resolve-AbsolutePath -Path $FilePath -MustExist
    $working = Resolve-AbsolutePath -Path $WorkingDirectory -MustExist
    $log = Resolve-AbsolutePath -Path $LogPath
    $argumentLine = (@($Arguments | ForEach-Object { ConvertTo-NativeCommandLineArgument -Argument $_ }) -join ' ')
    $commandLine = (ConvertTo-NativeCommandLineArgument -Argument $executable) + $(if ($argumentLine) { " $argumentLine" } else { "" })
    $startedAt = [DateTime]::UtcNow

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $executable
    $process.StartInfo.Arguments = $argumentLine
    $process.StartInfo.WorkingDirectory = $working
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    try {
        if (-not $process.Start()) {
            throw "Process.Start returned false"
        }
    } catch {
        $launchFailure = @(
            "schema=darkpanda-recorded-process/v1",
            "startedAtUtc=$($startedAt.ToString('o'))",
            "workingDirectory=$working",
            "commandLine=$commandLine",
            "launchError=$($_.Exception.ToString())"
        ) -join "`r`n"
        Write-Utf8NoBom -Path $log -Text ($launchFailure + "`r`n")
        throw "failed to start recorded process; log=$log`: $($_.Exception.Message)"
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = [int]$process.ExitCode
        $exitCodeUnsigned = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($exitCode), 0)
        $exitCodeHex = '0x{0:X8}' -f $exitCodeUnsigned
        $finishedAt = [DateTime]::UtcNow

        $record = @(
            "schema=darkpanda-recorded-process/v1",
            "startedAtUtc=$($startedAt.ToString('o'))",
            "finishedAtUtc=$($finishedAt.ToString('o'))",
            "durationMs=$([int64]($finishedAt - $startedAt).TotalMilliseconds)",
            "workingDirectory=$working",
            "commandLine=$commandLine",
            "exitCode=$exitCode",
            "exitCodeHex=$exitCodeHex",
            "--- stdout ---",
            $stdout,
            "--- stderr ---",
            $stderr
        ) -join "`r`n"
        Write-Utf8NoBom -Path $log -Text ($record + "`r`n")

        return [pscustomobject]@{
            ExitCode = $exitCode
            ExitCodeHex = $exitCodeHex
            Stdout = $stdout
            Stderr = $stderr
            LogPath = $log
            CommandLine = $commandLine
        }
    } finally {
        $process.Dispose()
    }
}

function Enter-ArtifactSetLock {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $root = Resolve-AbsolutePath -Path $RepoRoot -MustExist
    $lockRoot = Join-Path $root "artifacts\builds"
    New-Item -ItemType Directory -Path $lockRoot -Force -ErrorAction Stop | Out-Null
    $lockPath = Join-Path $lockRoot "ARTIFACT_SET.lock"
    try {
        return [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "another artifact build or acceptance test owns the global lock: $lockPath"
    }
}

function Write-ArtifactSetState {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet("building", "active", "failed")][string]$State,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [string]$ManifestPath,
        [string]$Detail
    )

    $stateRoot = Join-Path (Resolve-AbsolutePath -Path $RepoRoot -MustExist) "artifacts\builds"
    New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop | Out-Null
    $record = [ordered]@{
        schema = "darkpanda-artifact-set-state/v1"
        state = $State
        buildId = $BuildId
        recordedAtUtc = [DateTime]::UtcNow.ToString("o")
        manifestPath = $ManifestPath
        detail = $Detail
    }
    $temporary = Join-Path $stateRoot ("STATE." + [Guid]::NewGuid().ToString("N") + ".tmp")
    Write-Utf8NoBom -Path $temporary -Text (($record | ConvertTo-Json -Depth 4) + "`n")
    Move-Item -LiteralPath $temporary -Destination (Join-Path $stateRoot "STATE.json") -Force
}

function Get-RuntimeArtifactAttestation {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$PythonRoot,
        [Parameter(Mandatory = $true)][string]$FfiPath,
        [Parameter(Mandatory = $true)][string]$WreqPath,
        [Parameter(Mandatory = $true)][string]$CanvasPath,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $python = Resolve-AbsolutePath -Path $PythonPath -MustExist
    $pythonRootAbsolute = Resolve-AbsolutePath -Path $PythonRoot -MustExist
    $ffi = Resolve-AbsolutePath -Path $FfiPath -MustExist
    $wreq = Resolve-AbsolutePath -Path $WreqPath -MustExist
    $canvas = Resolve-AbsolutePath -Path $CanvasPath -MustExist
    $state = Resolve-AbsolutePath -Path $StateRoot
    $localAppData = Join-Path $state "local-app-data"
    $appData = Join-Path $state "app-data"
    $isolatedUserHome = Join-Path $state "home"
    $temp = Join-Path $state "temp"
    foreach ($directory in @($state, $localAppData, $appData, $isolatedUserHome, $temp)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $probe = @'
import ctypes
import json
import sys

python_root, ffi_path, wreq_path, canvas_path = sys.argv[1:5]
sys.path.insert(0, python_root)

ffi = ctypes.CDLL(ffi_path)
ffi.dp_abi_version.argtypes = []
ffi.dp_abi_version.restype = ctypes.c_uint32
ffi.dp_version.argtypes = []
ffi.dp_version.restype = ctypes.c_char_p

transport = ctypes.CDLL(wreq_path)
transport.wreq_transport_abi_version.argtypes = []
transport.wreq_transport_abi_version.restype = ctypes.c_uint32
transport.wreq_transport_version.argtypes = []
transport.wreq_transport_version.restype = ctypes.c_char_p

canvas = ctypes.CDLL(canvas_path)
canvas.dp_canvas_backend_abi_version.argtypes = []
canvas.dp_canvas_backend_abi_version.restype = ctypes.c_uint32
canvas.dp_canvas_backend_version.argtypes = []
canvas.dp_canvas_backend_version.restype = ctypes.c_char_p

from darkpanda import CanvasDriver, ClientProfile, Runtime

with Runtime(
    library_path=ffi_path,
    wreq_library_path=wreq_path,
    canvas_library_path=canvas_path,
    canvas_driver=CanvasDriver.DYNAMIC,
    navigation_timeout_ms=30_000,
    locale="en-US",
    timezone="UTC",
    profile=ClientProfile.CHROME149,
) as runtime:
    identity = runtime.identity_manifest()
    with runtime.new_page() as page:
        page.navigate("data:text/html,<canvas id='c' width='1' height='1'></canvas>")
        canvas_pixels = page.evaluate("(() => { const c=document.querySelector('#c'); const x=c.getContext('2d'); x.fillStyle='rgb(17,99,201)'; x.fillRect(0,0,1,1); return Array.from(x.getImageData(0,0,1,1).data); })()")

print(json.dumps({
    "ffiAbiVersion": int(ffi.dp_abi_version()),
    "ffiVersion": ffi.dp_version().decode("utf-8"),
    "wreqAbiVersion": int(transport.wreq_transport_abi_version()),
    "wreqVersion": transport.wreq_transport_version().decode("utf-8"),
    "canvasAbiVersion": int(canvas.dp_canvas_backend_abi_version()),
    "canvasVersion": canvas.dp_canvas_backend_version().decode("utf-8"),
    "canvasPixels": json.loads(canvas_pixels),
    "identity": identity,
}, separators=(",", ":")))
'@
    # Passing multiline Python through `python -c` is not stable under Windows
    # PowerShell's native argument quoting: embedded quotes can be removed before
    # Python sees them.  Keep the fixed probe inside this run's isolated state
    # root and execute the file by absolute path instead.
    $probePath = Join-Path $state "runtime-artifact-attestation.py"
    Write-Utf8NoBom -Path $probePath -Text ($probe + "`n")

    $environmentNames = @(
        "DARKPANDA_CANVAS_DRIVER",
        "DARKPANDA_CANVAS_BACKEND_FALLBACK",
        "DARKPANDA_CANVAS_BACKEND_LIBRARY",
        "DARKPANDA_CANVAS_BACKEND",
        "DARKPANDA_CANVAS_PROFILE_SEED",
        "DARKPANDA_CANVAS_SEED",
        "DARKPANDA_WREQ_LIBRARY",
        "LOCALAPPDATA",
        "APPDATA",
        "USERPROFILE",
        "HOME",
        "TEMP",
        "TMP"
    )
    $environmentBefore = @{}
    foreach ($name in $environmentNames) {
        $environmentBefore[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
        [System.Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    [System.Environment]::SetEnvironmentVariable("DARKPANDA_WREQ_LIBRARY", $wreq, "Process")
    [System.Environment]::SetEnvironmentVariable("LOCALAPPDATA", $localAppData, "Process")
    [System.Environment]::SetEnvironmentVariable("APPDATA", $appData, "Process")
    [System.Environment]::SetEnvironmentVariable("USERPROFILE", $isolatedUserHome, "Process")
    [System.Environment]::SetEnvironmentVariable("HOME", $isolatedUserHome, "Process")
    [System.Environment]::SetEnvironmentVariable("TEMP", $temp, "Process")
    [System.Environment]::SetEnvironmentVariable("TMP", $temp, "Process")

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(
            & $python -I -B -S $probePath $pythonRootAbsolute $ffi $wreq $canvas 2>&1 |
                ForEach-Object { $_.ToString() }
        )
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $environmentBefore[$name], "Process")
        }
    }
    if ($exitCode -ne 0) {
        throw "runtime artifact attestation failed with exit code $exitCode`: $($lines -join ' | ')"
    }
    if ($lines.Count -eq 0) {
        throw "runtime artifact attestation returned no JSON"
    }
    try {
        return ($lines[-1] | ConvertFrom-Json)
    } catch {
        throw "runtime artifact attestation returned invalid JSON: $($lines[-1])"
    }
}

function Get-SourceTreeProof {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $root = Resolve-AbsolutePath -Path $RepoRoot -MustExist
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($relative in @(
        "build.zig",
        "build.zig.zon",
        "tools/ArtifactSet.Common.ps1",
        "tools/Build-AcceptanceArtifactSet.ps1",
        "tools/Invoke-AcceptanceTest.ps1",
        "tests/ffi_turnstile.py"
    )) {
        $files.Add((Get-Item -LiteralPath (Join-Path $root $relative) -ErrorAction Stop))
    }
    foreach ($relativeRoot in @("src", "include", "python/darkpanda")) {
        $directory = Join-Path $root $relativeRoot
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "missing build input directory: $directory"
        }
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse -Force) {
            $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            if ($relative -match '(^|/)(target|zig-out|\.zig-cache|__pycache__)(/|$)') {
                continue
            }
            $files.Add($file)
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $lines.Add(("{0}`t{1}`t{2}" -f $relative, $file.Length, (Get-TreeEntrySha256 -File $file)))
    }
    $canonical = ($lines -join "`n") + "`n"
    return [pscustomobject]@{
        digest = Get-TextSha256 -Text $canonical
        fileCount = $lines.Count
        canonical = $canonical
    }
}

function Get-DirectoryTreeProof {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $root = Resolve-AbsolutePath -Path $Directory -MustExist
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $lines.Add(("{0}`t{1}`t{2}" -f $relative, $file.Length, (Get-TreeEntrySha256 -File $file)))
    }
    $canonical = ($lines -join "`n") + "`n"
    return [pscustomobject]@{
        digest = Get-TextSha256 -Text $canonical
        fileCount = $lines.Count
        canonical = $canonical
    }
}

function Get-SelectedTreeProof {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )

    $root = Resolve-AbsolutePath -Path $Directory -MustExist
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($relativePath in $RelativePaths) {
        $selected = Join-Path $root $relativePath
        if (Test-Path -LiteralPath $selected -PathType Leaf) {
            $files.Add((Get-Item -LiteralPath $selected -ErrorAction Stop))
            continue
        }
        if (-not (Test-Path -LiteralPath $selected -PathType Container)) {
            throw "selected source path does not exist: $selected"
        }
        foreach ($file in Get-ChildItem -LiteralPath $selected -File -Recurse -Force) {
            $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            if ($relative -match '(^|/)(\.git|target|zig-out|\.zig-cache|\.lp-cache|__pycache__)(/|$)' -or
                $file.Extension -eq ".pyc") {
                continue
            }
            $files.Add($file)
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files | Sort-Object FullName -Unique) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $lines.Add(("{0}`t{1}`t{2}" -f $relative, $file.Length, (Get-TreeEntrySha256 -File $file)))
    }
    $canonical = ($lines -join "`n") + "`n"
    return [pscustomobject]@{
        digest = Get-TextSha256 -Text $canonical
        fileCount = $lines.Count
        canonical = $canonical
    }
}

function Stop-ScopedDarkPandaProcesses {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $root = Resolve-AbsolutePath -Path $RepoRoot -MustExist
    $stopped = New-Object System.Collections.Generic.List[object]
    foreach ($processName in @("darkpanda", "lightpanda")) {
        foreach ($process in Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            $path = $null
            try { $path = $process.Path } catch {}
            if ($path -and (Test-PathWithin -Path $path -Root $root)) {
                $stopped.Add([pscustomobject]@{ pid = $process.Id; path = $path })
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                try { Wait-Process -Id $process.Id -Timeout 10 -ErrorAction Stop } catch {
                    if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                        throw "failed to stop old DarkPanda executable pid=$($process.Id) path=$path"
                    }
                }
            }
        }
    }

    $loaded = New-Object System.Collections.Generic.List[object]
    $moduleNames = @("darkpanda.dll", "wreq.dll", "darkpanda_html5ever.dll", "darkpanda_canvas_backend.dll")
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        if ($process.Id -eq $PID) { continue }
        try {
            foreach ($module in $process.Modules) {
                if ($moduleNames -contains $module.ModuleName.ToLowerInvariant()) {
                    $loaded.Add([pscustomobject]@{
                        pid = $process.Id
                        process = $process.ProcessName
                        module = $module.FileName
                    })
                }
            }
        } catch {
            # Protected system processes cannot host our unsigned workspace DLLs.
        }
    }
    if ($loaded.Count -ne 0) {
        $details = $loaded | ConvertTo-Json -Compress
        throw "a process still has a DarkPanda DLL loaded; stop it before building/testing: $details"
    }
    return $stopped.ToArray()
}

function Get-ArtifactByRole {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $matches = @($Manifest.artifacts | Where-Object { $_.role -eq $Role })
    if ($matches.Count -ne 1) {
        throw "manifest must contain exactly one artifact with role '$Role'"
    }
    return $matches[0]
}

function Assert-ArtifactManifestContents {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $manifestPathAbsolute = Resolve-AbsolutePath -Path $ManifestPath -MustExist
    $manifest = Get-Content -LiteralPath $manifestPathAbsolute -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne $script:ArtifactSetSchema) {
        throw "unsupported artifact manifest schema: $($manifest.schema)"
    }
    if ($manifest.acceptanceContract.version -ne $script:AcceptanceContractVersion) {
        throw "artifact manifest uses a different acceptance contract: $($manifest.acceptanceContract.version)"
    }
    if ($manifest.activated -ne $true) {
        throw "artifact manifest is not marked activated"
    }

    $repoRoot = Resolve-AbsolutePath -Path ([string]$manifest.repoRoot) -MustExist
    $buildRoot = Resolve-AbsolutePath -Path ([string]$manifest.buildRoot) -MustExist
    if (-not (Test-PathWithin -Path $buildRoot -Root (Join-Path $repoRoot ".a"))) {
        throw "build root is outside the dedicated artifact-set directory: $buildRoot"
    }
    if (-not (Test-PathWithin -Path $manifestPathAbsolute -Root $buildRoot)) {
        throw "manifest is not contained by its build root"
    }

    $manifestHash = Get-Sha256 -Path $manifestPathAbsolute

    $requiredRoles = @(
        "browser_exe",
        "ffi_dll",
        "wreq_library",
        "canvas_backend_library",
        "html_parser_dll",
        "v8_archive",
        "boringssl_crypto_archive",
        "boringssl_fipsmodule_archive"
    )
    foreach ($role in $requiredRoles) {
        $artifact = Get-ArtifactByRole -Manifest $manifest -Role $role
        $path = Resolve-AbsolutePath -Path ([string]$artifact.path) -MustExist
        if (-not [System.IO.Path]::IsPathRooted([string]$artifact.path)) {
            throw "artifact '$role' path is not absolute"
        }
        if ((Get-Sha256 -Path $path) -ne $artifact.sha256) {
            throw "artifact '$role' SHA-256 mismatch: $path"
        }
        if ((Get-Item -LiteralPath $path).Length -ne [int64]$artifact.size) {
            throw "artifact '$role' length mismatch: $path"
        }
        if ([string]::IsNullOrWhiteSpace([string]$artifact.version)) {
            throw "artifact '$role' has no recorded version"
        }
        if ($role -in @("browser_exe", "ffi_dll", "wreq_library", "canvas_backend_library", "html_parser_dll")) {
            if (-not (Test-PathWithin -Path $path -Root $buildRoot)) {
                throw "runtime artifact '$role' is outside the active build root"
            }
        }
    }

    $contractPath = Resolve-AbsolutePath -Path ([string]$manifest.acceptanceContract.path) -MustExist
    if ((Get-Sha256 -Path $contractPath) -ne $manifest.acceptanceContract.sha256) {
        throw "acceptance contract changed after this build; rebuild before testing"
    }
    $sourceExecutable = Resolve-AbsolutePath -Path ([string]$manifest.acceptanceContract.sourceExecutablePath) -MustExist
    if ((Get-Sha256 -Path $sourceExecutable) -ne $manifest.acceptanceContract.sourceExecutableSha256) {
        throw "acceptance test implementation changed after this build; rebuild before testing"
    }
    $contractExecutable = Resolve-AbsolutePath -Path ([string]$manifest.acceptanceContract.executablePath) -MustExist
    if (-not (Test-PathWithin -Path $contractExecutable -Root $buildRoot)) {
        throw "frozen acceptance executable is outside the build root"
    }
    if ((Get-Sha256 -Path $contractExecutable) -ne $manifest.acceptanceContract.executableSha256) {
        throw "frozen acceptance executable hash mismatch"
    }
    if ($manifest.acceptanceContract.executableSha256 -ne $manifest.acceptanceContract.sourceExecutableSha256) {
        throw "frozen acceptance executable is not byte-identical to the proven source test"
    }
    $acceptanceRoot = Resolve-AbsolutePath -Path ([string]$manifest.acceptanceContract.runtimeRoot) -MustExist
    if (-not (Test-PathWithin -Path $acceptanceRoot -Root $buildRoot)) {
        throw "frozen acceptance runtime is outside the build root"
    }
    $acceptanceProof = Get-DirectoryTreeProof -Directory $acceptanceRoot
    if ($acceptanceProof.digest -ne $manifest.acceptanceContract.runtimeTreeDigest -or
        $acceptanceProof.fileCount -ne $manifest.acceptanceContract.runtimeTreeFileCount) {
        throw "frozen acceptance runtime tree changed after the build"
    }

    $sourceProofPath = Resolve-AbsolutePath -Path ([string]$manifest.sourceProof.path) -MustExist
    if (-not (Test-PathWithin -Path $sourceProofPath -Root $buildRoot) -or
        (Get-Sha256 -Path $sourceProofPath) -ne $manifest.sourceProof.sha256) {
        throw "recorded source proof file is missing or changed"
    }
    $currentSource = Get-SourceTreeProof -RepoRoot $repoRoot
    if ($currentSource.digest -ne $manifest.sourceProof.digest -or
        $currentSource.fileCount -ne $manifest.sourceProof.fileCount) {
        throw "source build inputs changed after this artifact set was built; rebuild before testing"
    }

    foreach ($dependency in @($manifest.localDependencySourceProofs)) {
        $dependencyRoot = Resolve-AbsolutePath -Path ([string]$dependency.path) -MustExist
        $dependencyProof = Get-SelectedTreeProof `
            -Directory $dependencyRoot `
            -RelativePaths @($dependency.selection | ForEach-Object { [string]$_ })
        if ($dependencyProof.digest -ne $dependency.digest -or
            $dependencyProof.fileCount -ne $dependency.fileCount) {
            throw "local dependency source changed after the build: $($dependency.name)"
        }
    }

    $skiaSourceRoot = Resolve-AbsolutePath -Path ([string]$manifest.skiaSourceProof.path) -MustExist
    $skiaSourceProof = Get-DirectoryTreeProof -Directory $skiaSourceRoot
    if ($skiaSourceProof.digest -ne $manifest.skiaSourceProof.digest -or
        $skiaSourceProof.fileCount -ne $manifest.skiaSourceProof.fileCount) {
        throw "pinned Skia source tree changed after the build"
    }

    $packageRoot = Resolve-AbsolutePath -Path ([string]$manifest.dependencySourceProof.path) -MustExist
    if (-not (Test-PathWithin -Path $packageRoot -Root $buildRoot)) {
        throw "dependency source package tree is outside the active build root"
    }
    $packageProof = Get-DirectoryTreeProof -Directory $packageRoot
    if ($packageProof.digest -ne $manifest.dependencySourceProof.digest -or
        $packageProof.fileCount -ne $manifest.dependencySourceProof.fileCount) {
        throw "content-addressed dependency source tree changed after the build"
    }

    $cargoVendorRoot = Resolve-AbsolutePath -Path ([string]$manifest.cargoSourceProof.path) -MustExist
    if (-not (Test-PathWithin -Path $cargoVendorRoot -Root $buildRoot)) {
        throw "vendored Cargo source tree is outside the active build root"
    }
    $cargoVendorProof = Get-DirectoryTreeProof -Directory $cargoVendorRoot
    if ($cargoVendorProof.digest -ne $manifest.cargoSourceProof.digest -or
        $cargoVendorProof.fileCount -ne $manifest.cargoSourceProof.fileCount) {
        throw "vendored Cargo source tree changed after the build"
    }
    $cargoVendorLog = Resolve-AbsolutePath -Path ([string]$manifest.cargoSourceProof.vendorLogPath) -MustExist
    if (-not (Test-PathWithin -Path $cargoVendorLog -Root $buildRoot) -or
        (Get-Sha256 -Path $cargoVendorLog) -ne $manifest.cargoSourceProof.vendorLogSha256) {
        throw "Cargo source-materialization log is missing or changed"
    }
    foreach ($lockRecord in @(
        [pscustomobject]@{ path = $manifest.cargoSourceProof.wreqCargoLockPath; sha256 = $manifest.cargoSourceProof.wreqCargoLockSha256 },
        [pscustomobject]@{ path = $manifest.cargoSourceProof.htmlCargoLockPath; sha256 = $manifest.cargoSourceProof.htmlCargoLockSha256 },
        [pscustomobject]@{ path = $manifest.cargoSourceProof.canvasCargoLockPath; sha256 = $manifest.cargoSourceProof.canvasCargoLockSha256 }
    )) {
        $lockPath = Resolve-AbsolutePath -Path ([string]$lockRecord.path) -MustExist
        if ((Get-Sha256 -Path $lockPath) -ne $lockRecord.sha256) {
            throw "Cargo.lock changed after the build: $lockPath"
        }
    }

    $runtimeRoot = Resolve-AbsolutePath -Path ([string]$manifest.runtimeStateRoot) -MustExist
    if (-not (Test-PathWithin -Path $runtimeRoot -Root $buildRoot)) {
        throw "runtime state root is outside the active build root"
    }
    $buildLog = Resolve-AbsolutePath -Path ([string]$manifest.buildLog.path) -MustExist
    if (-not (Test-PathWithin -Path $buildLog -Root $buildRoot) -or
        (Get-Sha256 -Path $buildLog) -ne $manifest.buildLog.sha256) {
        throw "build log is missing or changed"
    }

    $attestationPath = Resolve-AbsolutePath -Path ([string]$manifest.runtimeAttestation.path) -MustExist
    if (-not (Test-PathWithin -Path $attestationPath -Root $buildRoot) -or
        (Get-Sha256 -Path $attestationPath) -ne $manifest.runtimeAttestation.sha256) {
        throw "runtime attestation evidence is missing or changed"
    }
    $attestation = Get-Content -LiteralPath $attestationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([uint32]$attestation.ffiAbiVersion -ne [uint32]$manifest.runtimeAttestation.ffiAbiVersion -or
        [string]$attestation.ffiVersion -ne [string]$manifest.runtimeAttestation.ffiVersion -or
        [uint32]$attestation.wreqAbiVersion -ne [uint32]$manifest.runtimeAttestation.wreqAbiVersion -or
        [string]$attestation.wreqVersion -ne [string]$manifest.runtimeAttestation.wreqVersion -or
        [uint32]$attestation.canvasAbiVersion -ne [uint32]$manifest.runtimeAttestation.canvasAbiVersion -or
        [string]$attestation.canvasVersion -ne [string]$manifest.runtimeAttestation.canvasVersion -or
        (@($attestation.canvasPixels) -join ',') -ne (@($manifest.runtimeAttestation.canvasPixels) -join ',') -or
        [string]$attestation.identity.javascriptRuntime.actualV8Version -ne [string]$manifest.runtimeAttestation.actualV8Version -or
        -not ($attestation.identity.consistency.allNonTlsAttestedChecksPass -is [bool]) -or
        -not [bool]$attestation.identity.consistency.allNonTlsAttestedChecksPass) {
        throw "recorded runtime attestation contents do not match the manifest"
    }

    foreach ($tool in @("zig", "cargo", "rustc", "python")) {
        $pathProperty = $tool + "Path"
        $shaProperty = $tool + "Sha256"
        $toolPath = Resolve-AbsolutePath -Path ([string]$manifest.toolchain.$pathProperty) -MustExist
        if (-not [System.IO.Path]::IsPathRooted([string]$manifest.toolchain.$pathProperty) -or
            (Get-Sha256 -Path $toolPath) -ne $manifest.toolchain.$shaProperty) {
            throw "toolchain executable changed after the build: $tool"
        }
    }

    $runtimeArtifacts = @($manifest.artifacts | Where-Object { $_.kind -eq "runtime-output" })
    $recordedRuntimePaths = @($runtimeArtifacts | ForEach-Object {
        (Resolve-AbsolutePath -Path ([string]$_.path) -MustExist).ToLowerInvariant()
    } | Sort-Object -Unique)
    $runtimeBin = Join-Path $buildRoot "i\bin"
    $actualRuntimePaths = @(
        Get-ChildItem -LiteralPath $runtimeBin -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @(".exe", ".dll") } |
            ForEach-Object { $_.FullName.ToLowerInvariant() } |
            Sort-Object -Unique
    )
    if (($recordedRuntimePaths -join "`n") -ne ($actualRuntimePaths -join "`n")) {
        throw "runtime bin contains an unrecorded or missing EXE/DLL"
    }

    return [pscustomobject]@{
        manifest = $manifest
        manifestPath = $manifestPathAbsolute
        manifestSha256 = $manifestHash
        repoRoot = $repoRoot
        buildRoot = $buildRoot
    }
}

function Assert-ArtifactSet {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $verified = Assert-ArtifactManifestContents -ManifestPath $ManifestPath
    $activePath = Join-Path $verified.repoRoot "artifacts\builds\ACTIVE.json"
    $active = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($active.schema -ne "darkpanda-active-artifact-set/v1" -or $active.state -ne "active") {
        throw "ACTIVE.json schema/state is invalid"
    }
    if (-not [System.IO.Path]::IsPathRooted([string]$active.manifestPath)) {
        throw "ACTIVE.json manifest path is not absolute"
    }
    $activeManifest = Resolve-AbsolutePath -Path ([string]$active.manifestPath) -MustExist
    if (-not $activeManifest.Equals($verified.manifestPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "requested manifest is inactive; only ACTIVE.json may be tested"
    }
    if ($active.buildId -ne $verified.manifest.buildId -or
        $active.manifestSha256 -ne $verified.manifestSha256) {
        throw "ACTIVE.json build identity or manifest hash does not match"
    }
    $statePath = Join-Path $verified.repoRoot "artifacts\builds\STATE.json"
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.schema -ne "darkpanda-artifact-set-state/v1" -or
        $state.state -ne "active" -or
        $state.buildId -ne $active.buildId -or
        [string]$state.manifestPath -ne [string]$active.manifestPath) {
        throw "artifact-set STATE.json is not the same active build"
    }
    return $verified
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [string]$Python = "python"
)

. (Join-Path $PSScriptRoot "ArtifactSet.Common.ps1")

function Invoke-FrozenAcceptanceMatrix {
    $verified = Assert-ArtifactSet -ManifestPath $Manifest
    $processesStopped = @(Stop-ScopedDarkPandaProcesses -RepoRoot $verified.repoRoot)
    # Process cleanup is part of the attested preflight state, so verify the
    # same ACTIVE pointer and every content hash again immediately afterwards.
    $verified = Assert-ArtifactSet -ManifestPath $verified.manifestPath
    $artifactManifest = $verified.manifest

    $ffi = Get-ArtifactByRole -Manifest $artifactManifest -Role "ffi_dll"
    $wreq = Get-ArtifactByRole -Manifest $artifactManifest -Role "wreq_library"
    $canvas = Get-ArtifactByRole -Manifest $artifactManifest -Role "canvas_backend_library"
    $exe = Get-ArtifactByRole -Manifest $artifactManifest -Role "browser_exe"
    $v8 = Get-ArtifactByRole -Manifest $artifactManifest -Role "v8_archive"
    $testPath = Resolve-AbsolutePath -Path ([string]$artifactManifest.acceptanceContract.executablePath) -MustExist
    $acceptanceRoot = Resolve-AbsolutePath -Path ([string]$artifactManifest.acceptanceContract.runtimeRoot) -MustExist
    $pythonRoot = Resolve-AbsolutePath -Path ([string]$artifactManifest.acceptanceContract.runtimePythonRoot) -MustExist
    if (-not (Test-PathWithin -Path $testPath -Root $acceptanceRoot) -or
        -not (Test-PathWithin -Path $pythonRoot -Root $acceptanceRoot)) {
        throw "frozen test or Python package is outside the active acceptance runtime"
    }

    $runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [Guid]::NewGuid().ToString("N")
    $runtimeRoot = Resolve-AbsolutePath -Path ([string]$artifactManifest.runtimeStateRoot) -MustExist
    $runRoot = Join-Path $runtimeRoot $runId
    $matrixStateRoot = Join-Path $runRoot "matrix-state"
    $tempRoot = Join-Path $matrixStateRoot "temp"
    $localAppData = Join-Path $matrixStateRoot "local-app-data"
    $appData = Join-Path $matrixStateRoot "app-data"
    $isolatedUserHome = Join-Path $matrixStateRoot "home"
    foreach ($directory in @($runRoot, $matrixStateRoot, $tempRoot, $localAppData, $appData, $isolatedUserHome)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    $pythonPath = Resolve-AbsolutePath -Path ((Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source) -MustExist
    $pythonVersion = (& $pythonPath -I -B -S --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "cannot execute the selected Python interpreter" }
    $pythonSha256 = Get-Sha256 -Path $pythonPath
    $buildPythonPath = Resolve-AbsolutePath -Path ([string]$artifactManifest.toolchain.pythonPath) -MustExist
    if (-not $pythonPath.Equals($buildPythonPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pythonVersion -ne [string]$artifactManifest.toolchain.pythonVersion -or
        $pythonSha256 -ne [string]$artifactManifest.toolchain.pythonSha256) {
        throw "acceptance must use the exact Python executable recorded by the active build"
    }

    $exeVersion = (& ([string]$exe.path) version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $exeVersion -ne $artifactManifest.buildVersion) {
        throw "active browser executable version mismatch"
    }
    $runtimeAttestation = Get-RuntimeArtifactAttestation `
        -PythonPath $pythonPath `
        -PythonRoot $pythonRoot `
        -FfiPath ([string]$ffi.path) `
        -WreqPath ([string]$wreq.path) `
        -CanvasPath ([string]$canvas.path) `
        -StateRoot (Join-Path $runRoot "preflight-attestation-state")
    if ([uint32]$runtimeAttestation.ffiAbiVersion -ne [uint32]$artifactManifest.runtimeAttestation.ffiAbiVersion -or
        [string]$runtimeAttestation.ffiVersion -ne [string]$artifactManifest.runtimeAttestation.ffiVersion -or
        [uint32]$runtimeAttestation.wreqAbiVersion -ne [uint32]$artifactManifest.runtimeAttestation.wreqAbiVersion -or
        [string]$runtimeAttestation.wreqVersion -ne [string]$artifactManifest.runtimeAttestation.wreqVersion -or
        [uint32]$runtimeAttestation.canvasAbiVersion -ne [uint32]$artifactManifest.runtimeAttestation.canvasAbiVersion -or
        [string]$runtimeAttestation.canvasVersion -ne [string]$artifactManifest.runtimeAttestation.canvasVersion -or
        (@($runtimeAttestation.canvasPixels) -join ',') -ne (@($artifactManifest.runtimeAttestation.canvasPixels) -join ',') -or
        [string]$runtimeAttestation.identity.javascriptRuntime.actualV8Version -ne [string]$artifactManifest.runtimeAttestation.actualV8Version -or
        -not ($runtimeAttestation.identity.consistency.allNonTlsAttestedChecksPass -is [bool]) -or
        -not [bool]$runtimeAttestation.identity.consistency.allNonTlsAttestedChecksPass) {
        throw "active DLL/V8 runtime attestation does not match the build manifest"
    }

    $verifiedRuntimeArtifacts = @()
    foreach ($artifact in @($artifactManifest.artifacts | Where-Object { $_.kind -eq "runtime-output" })) {
        $path = Resolve-AbsolutePath -Path ([string]$artifact.path) -MustExist
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $actualSha256 = Get-Sha256 -Path $path
        if ($actualSha256 -ne [string]$artifact.sha256 -or [int64]$item.Length -ne [int64]$artifact.size) {
            throw "runtime artifact changed after active-manifest verification: $($artifact.role)"
        }
        $verifiedRuntimeArtifacts += [ordered]@{
            role = [string]$artifact.role
            path = $path
            version = [string]$artifact.version
            size = [int64]$item.Length
            sha256 = $actualSha256
        }
    }
    $v8Path = Resolve-AbsolutePath -Path ([string]$v8.path) -MustExist
    $v8Item = Get-Item -LiteralPath $v8Path -ErrorAction Stop
    $v8Sha256 = Get-Sha256 -Path $v8Path
    if ($v8Sha256 -ne [string]$v8.sha256 -or [int64]$v8Item.Length -ne [int64]$v8.size) {
        throw "pinned V8 archive changed after active-manifest verification"
    }
    $stdoutPath = Join-Path $runRoot "stdout.log"
    $stderrPath = Join-Path $runRoot "stderr.log"

    $fixedArguments = @(
        "--library", [string]$ffi.path,
        "--wreq", [string]$wreq.path,
        "--only", "all"
    )
    $preflight = [ordered]@{
        schema = "darkpanda-test-preflight/v1"
        recordedAtUtc = [DateTime]::UtcNow.ToString("o")
        manifestPath = $verified.manifestPath
        manifestSha256 = $verified.manifestSha256
        buildId = $artifactManifest.buildId
        buildVersion = $artifactManifest.buildVersion
        browserExecutableVersion = $exeVersion
        testScript = $testPath
        testScriptSha256 = Get-Sha256 -Path $testPath
        fixedArguments = $fixedArguments
        processesStopped = $processesStopped
        runtimeStateRoot = $runRoot
        python = [ordered]@{
            path = $pythonPath
            version = $pythonVersion
            sha256 = $pythonSha256
            flags = @("-I", "-B", "-S")
        }
        verifiedRuntimeArtifacts = $verifiedRuntimeArtifacts
        pinnedV8Archive = [ordered]@{
            path = $v8Path
            version = [string]$v8.version
            size = [int64]$v8Item.Length
            sha256 = $v8Sha256
            actualRuntimeVersion = [string]$runtimeAttestation.identity.javascriptRuntime.actualV8Version
        }
        runtimeAttestation = $runtimeAttestation
    }
    $preflightPath = Join-Path $runRoot "preflight.json"
    Write-Utf8NoBom -Path $preflightPath -Text (($preflight | ConvertTo-Json -Depth 20) + "`n")

    $environmentNames = @(
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONNOUSERSITE",
        "PYTHONDONTWRITEBYTECODE",
        "LOCALAPPDATA",
        "APPDATA",
        "USERPROFILE",
        "HOME",
        "TEMP",
        "TMP",
        "DARKPANDA_WREQ_LIBRARY",
        "DARKPANDA_CANVAS_DRIVER",
        "DARKPANDA_CANVAS_BACKEND_FALLBACK",
        "DARKPANDA_CANVAS_BACKEND_LIBRARY",
        "DARKPANDA_CANVAS_BACKEND",
        "DARKPANDA_CANVAS_PROFILE_SEED",
        "DARKPANDA_CANVAS_SEED"
    )
    $environmentBefore = @{}
    foreach ($name in $environmentNames) {
        $environmentBefore[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
        [System.Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    [System.Environment]::SetEnvironmentVariable("PYTHONNOUSERSITE", "1", "Process")
    [System.Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1", "Process")
    [System.Environment]::SetEnvironmentVariable("LOCALAPPDATA", $localAppData, "Process")
    [System.Environment]::SetEnvironmentVariable("APPDATA", $appData, "Process")
    [System.Environment]::SetEnvironmentVariable("USERPROFILE", $isolatedUserHome, "Process")
    [System.Environment]::SetEnvironmentVariable("HOME", $isolatedUserHome, "Process")
    [System.Environment]::SetEnvironmentVariable("TEMP", $tempRoot, "Process")
    [System.Environment]::SetEnvironmentVariable("TMP", $tempRoot, "Process")
    [System.Environment]::SetEnvironmentVariable("DARKPANDA_WREQ_LIBRARY", [string]$wreq.path, "Process")

    $bootstrap = 'import runpy,sys;sys.path.insert(0,sys.argv[1]);sys.argv=sys.argv[2:];runpy.run_path(sys.argv[0],run_name="__main__")'
    $bootstrapPath = Join-Path $runRoot "run-frozen-acceptance.py"
    Write-Utf8NoBom -Path $bootstrapPath -Text ($bootstrap + "`n")
    Push-Location $runRoot
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $pythonPath -I -B -S $bootstrapPath $pythonRoot $testPath @fixedArguments 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
        Pop-Location
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $environmentBefore[$name], "Process")
        }
    }

    $stdoutLines = @(Get-Content -LiteralPath $stdoutPath -ErrorAction Stop)
    $stderrLines = @(Get-Content -LiteralPath $stderrPath -ErrorAction Stop)
    $matrixMarker = $null
    $validationError = $null
    if ($exitCode -ne 0) {
        $validationError = "acceptance process exited with code $exitCode"
    } else {
        try {
            $lastJsonLine = @($stdoutLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $matrixMarker = $lastJsonLine | ConvertFrom-Json
            $fixtureProperties = @($matrixMarker.fixtures.PSObject.Properties)
            $fixtureNames = @($fixtureProperties.Name | Sort-Object)
            if ($matrixMarker.contractVersion -ne $script:AcceptanceContractVersion -or
                $matrixMarker.result -ne "CLIENT_MATRIX_COMPLETE" -or
                -not ($matrixMarker.matrixComplete -is [bool]) -or
                -not [bool]$matrixMarker.matrixComplete -or
                $matrixMarker.validationLevel -ne "client_completed" -or
                -not ($matrixMarker.siteverify -is [bool]) -or
                [bool]$matrixMarker.siteverify -or
                ($fixtureNames -join ",") -ne "invisible,managed,non-interactive" -or
                @($fixtureProperties | Where-Object { $_.Value -ne "CLIENT_FIXTURE_COMPLETE" }).Count -ne 0) {
                throw "final JSON does not satisfy the immutable three-fixture client-completion contract"
            }
        } catch {
            $validationError = $_.Exception.Message
        }
    }

    $postflight = Assert-ArtifactSet -ManifestPath $verified.manifestPath
    $result = [ordered]@{
        schema = "darkpanda-test-result/v1"
        completedAtUtc = [DateTime]::UtcNow.ToString("o")
        preflightPath = $preflightPath
        preflightSha256 = Get-Sha256 -Path $preflightPath
        stdoutPath = $stdoutPath
        stdoutSha256 = Get-Sha256 -Path $stdoutPath
        stderrPath = $stderrPath
        stderrSha256 = Get-Sha256 -Path $stderrPath
        exitCode = $exitCode
        matrixMarker = $matrixMarker
        validationError = $validationError
        postflightManifestSha256 = $postflight.manifestSha256
    }
    $resultPath = Join-Path $runRoot "result.json"
    Write-Utf8NoBom -Path $resultPath -Text (($result | ConvertTo-Json -Depth 20) + "`n")
    if ($validationError) {
        throw "$validationError; preflight=$preflightPath result=$resultPath stderr=$stderrPath"
    }

    foreach ($line in $stdoutLines) { Write-Output $line }
    foreach ($line in $stderrLines) { Write-Warning $line }
    Write-Host "TEST_PREFLIGHT=$preflightPath"
    Write-Host "TEST_RESULT=$resultPath"
}

$repoRoot = Resolve-AbsolutePath -Path (Split-Path $PSScriptRoot -Parent) -MustExist
$artifactSetLock = Enter-ArtifactSetLock -RepoRoot $repoRoot
try {
    Invoke-FrozenAcceptanceMatrix
} finally {
    $artifactSetLock.Dispose()
}

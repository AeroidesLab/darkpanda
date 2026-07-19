[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Architecture,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [Parameter(Mandatory = $true)][string]$InstallRoot
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$install = [System.IO.Path]::GetFullPath($InstallRoot)
$archive = Join-Path $env:RUNNER_TEMP "zig-$Architecture-windows-$Version.zip"
$url = "https://ziglang.org/download/$Version/zig-$Architecture-windows-$Version.zip"

if (Test-Path -LiteralPath $install) {
    Remove-Item -LiteralPath $install -Recurse -Force
}
New-Item -ItemType Directory -Path $install -Force | Out-Null
Invoke-WebRequest -Uri $url -OutFile $archive
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actual -ne $Sha256.ToLowerInvariant()) {
    throw "Zig archive SHA-256 mismatch: expected $Sha256, got $actual"
}

$extract = Join-Path $env:RUNNER_TEMP "zig-extract-$Version-$Architecture"
if (Test-Path -LiteralPath $extract) {
    Remove-Item -LiteralPath $extract -Recurse -Force
}
Expand-Archive -LiteralPath $archive -DestinationPath $extract
$roots = @(Get-ChildItem -LiteralPath $extract -Directory)
if ($roots.Count -ne 1) {
    throw "Expected one Zig archive root, found $($roots.Count)"
}
Get-ChildItem -LiteralPath $roots[0].FullName -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $install -Recurse -Force
}
$zig = Join-Path $install "zig.exe"
if (-not (Test-Path -LiteralPath $zig -PathType Leaf)) {
    throw "Zig executable is missing after extraction: $zig"
}
$reported = (& $zig version).Trim()
if ($reported -ne $Version) {
    throw "Zig version mismatch: expected $Version, got $reported"
}
$install | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
"zig=$zig" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
Write-Host "Installed Zig $reported at $zig"

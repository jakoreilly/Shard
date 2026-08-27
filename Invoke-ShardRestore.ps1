<#
.SYNOPSIS
    Reassembles a project folder from shards written by Invoke-ShardPack.ps1.
.DESCRIPTION
    Reads the manifest (joining split manifest parts if needed), verifies
    every shard is present and hash-correct, then reconstructs the original
    tree exactly: file bytes (chunks re-joined in order), empty directories,
    last-write timestamps, and ReadOnly/Hidden attributes. Every write is
    manifest-driven and guarded against path traversal.
.PARAMETER PackagePath
    Folder containing the manifest and shard zips. Defaults to the current
    directory, so the script can simply be run inside the package folder.
.PARAMETER DestinationPath
    Folder to restore into. Must not already exist unless -Force is given.
    Defaults to a folder named after the manifest's projectName, created in
    the current directory.
.PARAMETER Force
    If DestinationPath already exists, delete it first.
.PARAMETER VerifyOnly
    Only verify shard presence and hashes; do not extract anything.
.EXAMPLE
    .\Invoke-ShardRestore.ps1
.EXAMPLE
    .\Invoke-ShardRestore.ps1 -PackagePath C:\incoming\pkg -DestinationPath C:\out\MyProject -Force
.EXAMPLE
    .\Invoke-ShardRestore.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$PackagePath = '.',

    [string]$DestinationPath,

    [switch]$Force,

    [switch]$VerifyOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

<#
    SHA-256 of a file, from one reused algorithm instance.

    Restore hashes everything twice - every shard before extracting anything,
    every restored file afterwards - so this is the hottest thing in the
    script. Get-FileHash is 16x slower (4.92s against 0.30s over 3,000 files)
    because each call re-resolves the provider path and constructs a fresh
    algorithm object.

    Duplicated from Invoke-ShardPack.ps1 rather than shared, deliberately:
    this script has to work when it is the only file sitting beside a folder of
    shards, and a dot-sourced helper would be one more thing somebody had to
    remember to copy.

    Same output as Get-FileHash - uppercase hex, no separators - so it compares
    directly against manifests written either way.
#>
$script:Sha256 = [System.Security.Cryptography.SHA256]::Create()
function Get-Sha256Hex {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return [System.BitConverter]::ToString($script:Sha256.ComputeHash($stream)).Replace('-', '')
    }
    finally {
        $stream.Dispose()
    }
}

<#
    Progress, throttled by the clock rather than by a count.

    Write-Progress costs about 7 ms a call on Windows PowerShell - measured at
    0.89s for 120 calls - because each one repaints the host's progress region.
    Firing it every 25 items therefore spent more time reporting than working
    on any project with a few thousand files. Every 250 ms keeps the bar
    honestly live and costs nothing measurable.
#>
$script:ProgressWatch = [System.Diagnostics.Stopwatch]::StartNew()
function Write-ThrottledProgress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete, [switch]$Force)
    if (-not $Force -and $script:ProgressWatch.ElapsedMilliseconds -lt 250) { return }
    $script:ProgressWatch.Restart()
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Container)) {
    throw "PackagePath is not a folder: $PackagePath"
}
$packageRoot = (Get-Item -LiteralPath $PackagePath).FullName.TrimEnd('\')

# --- Step 1: bootstrap the manifest (join split parts if needed) -----------

$manifestZip = Get-ChildItem -LiteralPath $packageRoot -Filter '*.manifest.zip' | Select-Object -First 1
$joinedTempPath = $null
if ($null -eq $manifestZip) {
    $parts = @(Get-ChildItem -LiteralPath $packageRoot -Filter '*.manifest.zip.*' | Sort-Object -Property Name)
    if ($parts.Count -eq 0) {
        throw "No *.manifest.zip (or split parts) found in '$packageRoot'. Is this a package folder created by Invoke-ShardPack.ps1?"
    }
    $joinedTempPath = Join-Path $env:TEMP ('shardmanifest_{0}.zip' -f [Guid]::NewGuid().ToString('N'))
    $outStream = [System.IO.File]::Create($joinedTempPath)
    try {
        foreach ($part in $parts) {
            $bytes = [System.IO.File]::ReadAllBytes($part.FullName)
            $outStream.Write($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $outStream.Dispose()
    }
    $manifestZipPath = $joinedTempPath
}
else {
    $manifestZipPath = $manifestZip.FullName
}

try {
    $mzip = [System.IO.Compression.ZipFile]::OpenRead($manifestZipPath)
    try {
        $entry = $mzip.GetEntry('manifest.json')
        if ($null -eq $entry) {
            throw "'$manifestZipPath' does not contain manifest.json."
        }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try {
            $manifestJson = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $mzip.Dispose()
    }
}
finally {
    if ($null -ne $joinedTempPath -and (Test-Path -LiteralPath $joinedTempPath)) {
        Remove-Item -LiteralPath $joinedTempPath -Force
    }
}

$manifest = $manifestJson | ConvertFrom-Json
<#
    Version 2 renamed the manifest's shard keys and the .zip names that go with
    them. A version 1 package is not readable here and failing on the version
    field says so plainly; without this check the first missing key would
    surface as a strict-mode "property not found" from somewhere deep in the
    restore loop, which tells the reader nothing about what is actually wrong.
#>
if ($manifest.formatVersion -ne 2) {
    $versionHint = ''
    if ($manifest.formatVersion -eq 1) {
        $versionHint = " Version 1 packages were written by an earlier release and name their shards '.partNNNN.zip'; repack the source with Invoke-ShardPack.ps1, or restore them with the scripts that produced them."
    }
    throw "Unsupported manifest formatVersion '$($manifest.formatVersion)'. This script supports version 2.$versionHint"
}

if (-not $PSBoundParameters.ContainsKey('DestinationPath') -or [string]::IsNullOrEmpty($DestinationPath)) {
    # projectName comes from the (unauthenticated) manifest; a tampered value
    # like "..\..\evil" would move the default destination outside the current
    # directory, past the zip-slip guard below.
    $projectName = [string]$manifest.projectName
    if ([string]::IsNullOrWhiteSpace($projectName) -or
        $projectName.IndexOfAny([char[]]@('\', '/', ':')) -ge 0 -or
        $projectName.Contains('..')) {
        throw "Manifest projectName '$projectName' is not a plain folder name. Pass -DestinationPath explicitly to restore this package."
    }
    $DestinationPath = Join-Path (Get-Location).ProviderPath $projectName
}

$manifestShards = @($manifest.shards)
$manifestFiles = @($manifest.files)
$manifestEmptyDirs = @(if ($manifest.PSObject.Properties['emptyDirectories'] -and $manifest.emptyDirectories) {
    $manifest.emptyDirectories
})

Write-Verbose "Manifest: $($manifestFiles.Count) files, $($manifestShards.Count) shards, $($manifestEmptyDirs.Count) empty directories"

# --- Step 2: shard verification (before touching the destination) ----------

Write-Progress -Activity 'Restoring' -Status 'Verifying shards' -PercentComplete 0

$missingShards = New-Object System.Collections.Generic.List[string]
$mismatchedShards = New-Object System.Collections.Generic.List[string]
$shardCounter = 0
foreach ($shard in $manifestShards) {
    $shardCounter++
    $zipPath = Join-Path $packageRoot $shard.zipName
    if (-not (Test-Path -LiteralPath $zipPath)) {
        $missingShards.Add($shard.zipName)
        continue
    }
    $actualHash = Get-Sha256Hex $zipPath
    if ($actualHash -ne $shard.sha256) {
        $mismatchedShards.Add($shard.zipName)
    }
    $pct = [int](50 * ($shardCounter / [double]([Math]::Max(1, $manifestShards.Count))))
    Write-ThrottledProgress 'Restoring' "Verifying shards ($shardCounter/$($manifestShards.Count))" $pct
}

if ($missingShards.Count -gt 0 -or $mismatchedShards.Count -gt 0) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($missingShards.Count -gt 0) {
        $lines.Add("Missing shards ($($missingShards.Count)):")
        $lines.AddRange([string[]]$missingShards)
    }
    if ($mismatchedShards.Count -gt 0) {
        $lines.Add("Hash-mismatched shards ($($mismatchedShards.Count)):")
        $lines.AddRange([string[]]$mismatchedShards)
    }
    throw "Package verification failed:`n$($lines -join "`n")"
}

if ($VerifyOnly) {
    Write-Progress -Activity 'Restoring' -Completed
    Write-Host "VERIFY OK: $($manifestShards.Count) shards, $($manifestFiles.Count) files declared"
    $script:Sha256.Dispose()
    return
}

# --- Step 3: destination handling -------------------------------------------

$destFull = $DestinationPath
if (-not [System.IO.Path]::IsPathRooted($destFull)) {
    $destFull = Join-Path (Get-Location).ProviderPath $destFull
}
$destFull = [System.IO.Path]::GetFullPath($destFull).TrimEnd('\')
if ($packageRoot.Equals($destFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $packageRoot.StartsWith("$destFull\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "DestinationPath '$destFull' contains the package folder itself; with -Force the restore would delete its own shards. Choose a destination outside '$packageRoot'."
}

if (Test-Path -LiteralPath $DestinationPath) {
    if ($Force) {
        Write-Warning "Deleting existing destination: $DestinationPath"
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force -Confirm:$false
    }
    else {
        throw "Destination '$DestinationPath' already exists. Use -Force to replace it."
    }
}
New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
$destRoot = (Get-Item -LiteralPath $DestinationPath).FullName.TrimEnd('\')

# --- Step 4: manifest-driven reassembly with zip-slip guard -----------------

$openZips = @{}   # zipName -> ZipArchive
function Get-ShardArchive {
    param([string]$ZipName)
    if (-not $openZips.ContainsKey($ZipName)) {
        if ($openZips.Count -ge 64) {
            foreach ($z in $openZips.Values) { $z.Dispose() }
            $openZips.Clear()
        }
        $openZips[$ZipName] = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $packageRoot $ZipName))
    }
    return $openZips[$ZipName]
}

$createdDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$fileCounter = 0
try {
    foreach ($f in $manifestFiles) {
        $fileCounter++
        $pct = 50 + [int](40 * ($fileCounter / [double]([Math]::Max(1, $manifestFiles.Count))))
        Write-ThrottledProgress 'Restoring' "Writing files ($fileCounter/$($manifestFiles.Count))" $pct

        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $f.relativePath))
        if (-not $targetPath.StartsWith($destRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest path '$($f.relativePath)' escapes the destination folder. Aborting."
        }
        <#
            Remembered rather than re-checked. Test-Path is a cmdlet call with
            provider resolution behind it - 0.82s per 3,000 against 0.11s for
            the .NET equivalent - and a project puts most of its files in a
            handful of directories, so nearly every check was asking about a
            folder this loop had already created.
        #>
        $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
        if ($createdDirs.Add($targetDir)) {
            [void][System.IO.Directory]::CreateDirectory($targetDir)
        }

        $out = [System.IO.File]::Create($targetPath)
        try {
            foreach ($chunk in @($f.chunks)) {
                $zip = Get-ShardArchive -ZipName $chunk.shard
                $entry = $zip.GetEntry($chunk.entry)
                if ($null -eq $entry) {
                    throw "Entry '$($chunk.entry)' not found in shard '$($chunk.shard)' (manifest/zip mismatch)."
                }
                $es = $entry.Open()
                try {
                    $es.CopyTo($out)
                }
                finally {
                    $es.Dispose()
                }
            }
        }
        finally {
            $out.Dispose()
        }
    }
}
finally {
    foreach ($z in $openZips.Values) { $z.Dispose() }
}

# --- Step 5: recreate empty directories -------------------------------------

foreach ($relDir in $manifestEmptyDirs) {
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $relDir))
    if (-not $targetPath.StartsWith($destRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest empty-directory path '$relDir' escapes the destination folder. Aborting."
    }
    if (-not (Test-Path -LiteralPath $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }
}

# --- Step 6: post-restore verification and metadata restore ----------------

Write-Progress -Activity 'Restoring' -Status 'Verifying restored files' -PercentComplete 92

$missingFiles = New-Object System.Collections.Generic.List[string]
$mismatchedFiles = New-Object System.Collections.Generic.List[string]

foreach ($f in $manifestFiles) {
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $f.relativePath))
    if (-not [System.IO.File]::Exists($targetPath)) {
        $missingFiles.Add($f.relativePath)
        continue
    }
    $actualHash = Get-Sha256Hex $targetPath
    if ($actualHash -ne $f.sha256) {
        $mismatchedFiles.Add($f.relativePath)
        continue
    }

    [System.IO.File]::SetLastWriteTimeUtc(
        $targetPath,
        [datetime]::Parse($f.lastWriteTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind))

    if ($f.PSObject.Properties['attributes'] -and $f.attributes) {
        [System.IO.File]::SetAttributes($targetPath, [System.IO.FileAttributes]$f.attributes)
    }
}

Write-Progress -Activity 'Restoring' -Completed

if ($missingFiles.Count -gt 0 -or $mismatchedFiles.Count -gt 0) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($missingFiles.Count -gt 0) {
        $lines.Add("Missing files ($($missingFiles.Count)):")
        $lines.AddRange([string[]]$missingFiles)
    }
    if ($mismatchedFiles.Count -gt 0) {
        $lines.Add("Hash-mismatched files ($($mismatchedFiles.Count)):")
        $lines.AddRange([string[]]$mismatchedFiles)
    }
    throw "Restore FAILED verification:`n$($lines -join "`n")"
}

$script:Sha256.Dispose()

Write-Host "RESTORE OK: $($manifestFiles.Count) files, $($manifestEmptyDirs.Count) empty dirs -> $destRoot"

<#
    A package built with exclusions restores to something that is deliberately
    not a copy of the original folder, and nothing else on screen would say so.
    Read back from the manifest rather than assumed, so an older package (which
    has no such field) stays silent instead of claiming nothing was excluded.
#>
if ($manifest.PSObject.Properties['excludedFiles'] -and $manifest.excludedFiles -gt 0) {
    Write-Host "  note: $($manifest.excludedFiles) file(s) were excluded when this package was built, and are not here."
    # The full pattern list runs to thirty entries by default and would bury
    # the line that matters. It stays in the manifest for anyone who needs it.
    if ($manifest.PSObject.Properties['excludes'] -and $manifest.excludes) {
        Write-Verbose "Exclusion patterns: $(@($manifest.excludes) -join ' ')"
    }
}

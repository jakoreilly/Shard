<#
.SYNOPSIS
    Packs a project folder into many small .zip shards plus a manifest.
.DESCRIPTION
    Splits every file in SourcePath into byte-range chunks sized to fit
    within MaxShardSizeKB, packs chunks into sequential .shardNNNN.zip
    shards (each guaranteed <= the cap), and writes a manifest describing
    how to reassemble the original tree exactly (paths, hashes, empty
    directories, timestamps, ReadOnly/Hidden attributes).

    The manifest itself is written as <ProjectName>.manifest.zip; if that
    compressed manifest still exceeds the cap it is split into raw byte
    parts (<ProjectName>.manifest.zip.001, .002, ...) that
    Invoke-ShardRestore.ps1 concatenates before reading.
.PARAMETER SourcePath
    The project folder to package.
.PARAMETER OutputPath
    The folder to write shards and the manifest into. Created if missing.
.PARAMETER MaxShardSizeKB
    Maximum size in KB of any single shard or manifest part. Default 500.
.PARAMETER Exclude
    Extra patterns to leave out, matched with -like against each path segment
    and against the whole relative path: 'bin', '*.user', 'src\generated\*'.
    A matching directory prunes its entire subtree.
.PARAMETER NoDefaultExcludes
    Package build output and tool folders too. Without this, the patterns in
    $defaultExcludes below are skipped.
.EXAMPLE
    .\Invoke-ShardPack.ps1 -SourcePath C:\src\MyProject -OutputPath C:\out\MyProject-pkg
.EXAMPLE
    .\Invoke-ShardPack.ps1 -SourcePath .\MyProject -OutputPath .\pkg -MaxShardSizeKB 200
.EXAMPLE
    .\Invoke-ShardPack.ps1 -SourcePath .\MyProject -OutputPath .\pkg -Exclude '*.mp4','docs'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(8, 1048576)]
    [int]$MaxShardSizeKB = 500,

    [string[]]$Exclude = @(),

    [switch]$NoDefaultExcludes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

<#
    Overhead reserve, per shard.

    Beyond the zip structures, DEFLATE can make incompressible data slightly
    LARGER than its input - roughly five bytes per 64 KB block once it falls
    back to stored blocks. A flat 2 KB reserve covers that up to about a 26 MB
    cap and silently stops covering it above that, which turned a large
    -MaxShardSizeKB over already-compressed content (video, .zip, .pdf) into an
    "internal error" thrown after every shard had already been written.
    Scaling the reserve with the cap keeps the guarantee at every size the
    parameter accepts.
#>
$capBytes     = [long]$MaxShardSizeKB * 1KB
$reserveBytes = [long]2KB + [long]($capBytes / 1024)
$budgetBytes  = $capBytes - $reserveBytes
if ($budgetBytes -le 0) {
    throw "MaxShardSizeKB is too small once overhead is reserved. Use a larger value."
}

<#
    What a project folder holds that a package of it should not.

    Packing a working checkout without this is the difference between a 300 KB
    package and a 300 MB one, and every byte of the difference is reproducible
    from what is kept. .git is the sharpest case: it is routinely larger than
    the tree it tracks, and restoring it produces a repository whose index
    disagrees with the working copy beside it.
#>
$defaultExcludes = @(
    '.git', '.svn', '.hg',
    'bin', 'obj', 'node_modules', 'packages', 'vendor',
    '.vs', '.idea', '__pycache__', '.pytest_cache', '.mypy_cache',
    'dist', 'build', 'out', 'target', 'TestResults', 'coverage', '.nyc_output',
    '.next', '.nuxt', '.parcel-cache', '.gradle', '.terraform',
    '*.user', '*.suo', '*.pyc', 'Thumbs.db', '.DS_Store'
)

$effectiveExcludes = @()
if (-not $NoDefaultExcludes) { $effectiveExcludes += $defaultExcludes }
$effectiveExcludes += $Exclude
$effectiveExcludes = @($effectiveExcludes | Where-Object { $_ })

<#
    Split once, into the patterns that need matching and the ones that only
    need looking up.

    Almost every exclusion is a plain folder name, and testing thirty of those
    against every path segment with -like costs 0.67s per 3,000 files - as much
    as reading and hashing the whole project. A set lookup for the literals and
    -like for the handful that actually contain a wildcard does the same work in
    0.09s.
#>
$excludeLiterals = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$excludeWildcards = @()
foreach ($pattern in $effectiveExcludes) {
    if ($pattern.IndexOfAny([char[]]@('*', '?', '[')) -ge 0) {
        $excludeWildcards += $pattern
    }
    else {
        [void]$excludeLiterals.Add($pattern)
    }
}

<#
    Does this relative path match an exclusion?

    Matched per segment as well as whole, so 'bin' excludes 'src\App\bin\x.dll'
    without anyone having to write 'src\App\bin\*' - which is what people mean
    by "exclude bin", and what every other tool of this kind does.
#>
function Test-Excluded {
    param([string]$RelativePath)
    $segments = $RelativePath -split '\\'
    if ($excludeLiterals.Count -gt 0) {
        foreach ($segment in $segments) {
            if ($excludeLiterals.Contains($segment)) { return $true }
        }
    }
    foreach ($pattern in $excludeWildcards) {
        if ($RelativePath -like $pattern) { return $true }
        foreach ($segment in $segments) {
            if ($segment -like $pattern) { return $true }
        }
    }
    return $false
}

<#
    SHA-256 of a file, from one reused algorithm instance.

    Get-FileHash is the obvious call and it is 16x slower here: measured over
    3,000 small files it took 4.92s against 0.30s for this, because every call
    re-resolves the provider path and constructs a fresh algorithm object. On a
    project of any size that gap is most of the run time.

    Same output as Get-FileHash - uppercase hex, no separators - so manifests
    written before and after this change are interchangeable.
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

# --- Step 1: resolve and validate paths ------------------------------------

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "SourcePath is not a folder: $SourcePath"
}
$sourceRoot = (Get-Item -LiteralPath $SourcePath).FullName.TrimEnd('\')
$projectName = Split-Path -Path $sourceRoot -Leaf
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}
$outputRoot = (Get-Item -LiteralPath $OutputPath).FullName.TrimEnd('\')
# -like treats [ ] as a wildcard character class, so it misses paths like
# "proj [v2]"; compare ordinally instead.
if ($outputRoot.Equals($sourceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputRoot.StartsWith("$sourceRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must not be inside SourcePath (the package would include itself)."
}

Write-Verbose "Source: $sourceRoot"
Write-Verbose "Output: $outputRoot"
Write-Verbose "Shard cap: $capBytes bytes (budget per unit: $budgetBytes bytes)"

# --- Step 2: inventory ------------------------------------------------------

Write-Progress -Activity 'Packaging' -Status 'Scanning source tree' -PercentComplete 0

$allItems = Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force

<#
    Exclusions are applied before anything else looks at the tree, so an
    excluded folder costs nothing downstream - not a hash, not a long-path
    complaint, not a line in the manifest. That ordering matters for more than
    speed: node_modules routinely contains paths past 260 characters, and
    checking those first made an otherwise ordinary project refuse to pack over
    files that were never going to be included.
#>
$skippedCount = 0
$skippedBytes = [long]0
$kept = New-Object System.Collections.Generic.List[object]
foreach ($item in $allItems) {
    $relativePath = $item.FullName.Substring($sourceRoot.Length + 1)
    if (Test-Excluded $relativePath) {
        if (-not $item.PSIsContainer) {
            $skippedCount++
            $skippedBytes += [long]$item.Length
        }
        continue
    }
    $kept.Add([pscustomobject]@{ Item = $item; RelativePath = $relativePath })
}

$longPaths = @($kept | Where-Object { $_.Item.FullName.Length -ge 260 } | ForEach-Object { $_.Item.FullName })
if ($longPaths.Count -gt 0) {
    throw "The following paths are >= 260 characters and are not supported on PowerShell 5.1:`n$($longPaths -join "`n")"
}

# List rather than +=: appending to a PowerShell array reallocates and copies
# the whole thing each time, so a 3,000-file project spent 0.24s here and a
# 30,000-file one would spend about a hundred times that.
$fileList = New-Object System.Collections.Generic.List[object]
foreach ($entry in $kept) {
    if ($entry.Item.PSIsContainer) { continue }
    $fileList.Add([pscustomobject]@{
        FullName     = $entry.Item.FullName
        RelativePath = $entry.RelativePath
        Length       = [long]$entry.Item.Length
        LastWriteUtc = $entry.Item.LastWriteTimeUtc
        Attributes   = $entry.Item.Attributes
        Sha256       = $null
    })
}
$files = @($fileList.ToArray())
$filesArray = [object[]]$files
$ordinalComparer = [System.StringComparer]::OrdinalIgnoreCase
[System.Array]::Sort($filesArray, [System.Comparison[object]]{ param($a, $b) $ordinalComparer.Compare($a.RelativePath, $b.RelativePath) })
$files = @($filesArray)

if ($files.Count -gt 0) {
    Write-Progress -Activity 'Packaging' -Status 'Hashing files' -PercentComplete 5
    $hashCounter = 0
    foreach ($file in $files) {
        $file.Sha256 = Get-Sha256Hex $file.FullName
        $hashCounter++
        $pct = 5 + [int](15 * ($hashCounter / [double]$files.Count))
        Write-ThrottledProgress 'Packaging' "Hashing files ($hashCounter/$($files.Count))" $pct
    }
}

<#
    Empty directories, derived from the walk already done rather than from a
    second recursive scan that opened every directory again to count it.

    "Empty" here means empty *of things being packaged*. A folder that matched
    an exclusion is gone entirely - an empty bin\ is worse than no bin\ - but a
    folder that merely ended up empty because its contents were excluded is
    kept, so the restored tree is the original with files removed rather than a
    tree that quietly changed shape. A folder is non-empty if any kept item
    sits anywhere beneath it.
#>
$occupied = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $kept) {
    $parent = Split-Path -Path $entry.RelativePath -Parent
    while ($parent) {
        if (-not $occupied.Add($parent)) { break }   # already walked this branch
        $parent = Split-Path -Path $parent -Parent
    }
}
$emptyDirs = @(
    $kept |
        Where-Object { $_.Item.PSIsContainer -and -not $occupied.Contains($_.RelativePath) } |
        ForEach-Object { $_.RelativePath }
)

# --- Step 3: expand files into pack units (whole file or byte-range chunk) -

$units = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $entryBase = $file.RelativePath -replace '\\', '/'
    if ($file.Length -le $budgetBytes) {
        $units.Add([pscustomobject]@{
            File      = $file
            Offset    = [long]0
            Length    = [long]$file.Length
            EntryName = $entryBase
        })
    }
    else {
        $chunkCount = [int][Math]::Ceiling($file.Length / [double]$budgetBytes)
        for ($i = 0; $i -lt $chunkCount; $i++) {
            $offset = [long]$i * $budgetBytes
            $units.Add([pscustomobject]@{
                File      = $file
                Offset    = $offset
                Length    = [Math]::Min([long]$budgetBytes, $file.Length - $offset)
                EntryName = ('{0}.__chunk{1:D4}' -f $entryBase, $i)
            })
        }
        Write-Verbose "File '$($file.RelativePath)' ($($file.Length) bytes) split into $chunkCount chunks."
    }
}

# --- Step 4: assign units to shards (sequential fill, each unit <= budget) -

# Beyond its payload, every zip entry costs ~160 bytes of fixed structures
# (local header + central directory record) plus its UTF-8 entry name stored
# in both. Charging that against the budget keeps shards of many tiny files
# (e.g. hundreds of zero-byte .gitkeep/__init__.py) under the cap.
$zipEntryFixedOverhead = [long]160

$shards = New-Object System.Collections.Generic.List[object]
$current = $null
foreach ($unit in $units) {
    $unitCost = $unit.Length + $zipEntryFixedOverhead +
        2 * [System.Text.Encoding]::UTF8.GetByteCount($unit.EntryName)
    if ($null -eq $current -or ($current.Bytes + $unitCost -gt $budgetBytes -and $current.Units.Count -gt 0)) {
        $current = [pscustomobject]@{
            Index = $shards.Count + 1
            Units = New-Object System.Collections.Generic.List[object]
            Bytes = [long]0
        }
        $shards.Add($current)
    }
    $current.Units.Add($unit)
    $current.Bytes += $unitCost
}

Write-Verbose "$($files.Count) files -> $($units.Count) pack units -> $($shards.Count) shards"

# --- Step 5: write each shard ------------------------------------------------

$chunkMap = @{}   # file RelativePath -> List of chunk descriptors (shard, entry, offset, length), in order

$shardCounter = 0
foreach ($shard in $shards) {
    $shardCounter++
    Write-ThrottledProgress 'Packaging' "Writing shard $shardCounter/$($shards.Count)" `
        (20 + [int](75 * ($shardCounter / [double]$shards.Count)))

    $zipName = '{0}.shard{1:D4}.zip' -f $projectName, $shard.Index
    $zipPath = Join-Path $outputRoot $zipName

    try {
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($unit in $shard.Units) {
                $entry = $zip.CreateEntry($unit.EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                $fileStream  = [System.IO.File]::OpenRead($unit.File.FullName)
                try {
                    $fileStream.Position = $unit.Offset
                    $buffer = New-Object byte[] 81920
                    $remaining = $unit.Length
                    while ($remaining -gt 0) {
                        $toRead = [int][Math]::Min([long]$buffer.Length, $remaining)
                        $read = $fileStream.Read($buffer, 0, $toRead)
                        if ($read -le 0) {
                            throw "Unexpected end of file reading '$($unit.File.FullName)' at offset $($fileStream.Position)."
                        }
                        $entryStream.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                }
                finally {
                    $entryStream.Dispose()
                    $fileStream.Dispose()
                }

                if (-not $chunkMap.ContainsKey($unit.File.RelativePath)) {
                    $chunkMap[$unit.File.RelativePath] = New-Object System.Collections.Generic.List[object]
                }
                $chunkMap[$unit.File.RelativePath].Add([pscustomobject]@{
                    shard  = $zipName
                    entry  = $unit.EntryName
                    offset = $unit.Offset
                    length = $unit.Length
                })
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }
        throw
    }

    $shardSize = (Get-Item -LiteralPath $zipPath).Length
    if ($shardSize -gt $capBytes) {
        throw "Internal error: shard '$zipPath' is $shardSize bytes, exceeding the $capBytes-byte cap."
    }
}

# --- Step 6: build manifest --------------------------------------------------

Write-Progress -Activity 'Packaging' -Status 'Hashing shards' -PercentComplete 96

$shardManifestList = New-Object System.Collections.Generic.List[object]
foreach ($shard in $shards) {
    $zipName = '{0}.shard{1:D4}.zip' -f $projectName, $shard.Index
    $zipPath = Join-Path $outputRoot $zipName
    $shardManifestList.Add([pscustomobject]@{
        zipName    = $zipName
        sha256     = Get-Sha256Hex $zipPath
        entryCount = $shard.Units.Count
    })
}
$shardManifest = @($shardManifestList.ToArray())

$restorableAttributeMask = [System.IO.FileAttributes]'ReadOnly, Hidden'
$fileManifestList = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $restorableAttrs = $file.Attributes -band $restorableAttributeMask
    $attrString = if ($restorableAttrs -eq 0) { '' } else { $restorableAttrs.ToString() }
    $fileManifestList.Add([pscustomobject]@{
        relativePath     = $file.RelativePath
        length           = $file.Length
        sha256           = $file.Sha256
        lastWriteTimeUtc = $file.LastWriteUtc.ToString('o')
        attributes       = $attrString
        chunks           = $chunkMap[$file.RelativePath].ToArray()
    })
}
$fileManifest = @($fileManifestList.ToArray())

$manifest = [pscustomobject]@{
    formatVersion   = 2
    createdUtc      = [datetime]::UtcNow.ToString('o')
    projectName     = $projectName
    maxShardSizeKB  = $MaxShardSizeKB
    totalFiles      = $files.Count
    totalBytes      = [long]($files | Measure-Object -Property Length -Sum).Sum
    # Recorded so a restored tree can be read honestly: it is the original
    # minus these patterns, and without them written down nobody can tell
    # whether a missing bin\ folder was excluded or was never there.
    excludes        = @($effectiveExcludes)
    excludedFiles   = $skippedCount
    excludedBytes   = $skippedBytes
    shards          = @($shardManifest)
    files           = @($fileManifest)
    emptyDirectories = @($emptyDirs)
}

# --- Step 7: write, compress, and (if needed) split the manifest ------------

$manifestJsonPath = Join-Path $outputRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestJsonPath -Encoding utf8

$manifestZipPath = Join-Path $outputRoot ('{0}.manifest.zip' -f $projectName)
$mzip = [System.IO.Compression.ZipFile]::Open($manifestZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $mzip, $manifestJsonPath, 'manifest.json',
        [System.IO.Compression.CompressionLevel]::Optimal)
}
finally { $mzip.Dispose() }
Remove-Item -LiteralPath $manifestJsonPath   # only the zipped form ships

$manifestPartCount = 1
$manifestZipSize = (Get-Item -LiteralPath $manifestZipPath).Length
if ($manifestZipSize -gt $capBytes) {
    $bytes = [System.IO.File]::ReadAllBytes($manifestZipPath)
    $partCount = [int][Math]::Ceiling($bytes.Length / [double]$capBytes)
    if ($partCount -gt 999) {
        throw "Manifest requires $partCount parts, exceeding the 999-part limit. Use a larger -MaxShardSizeKB."
    }
    for ($i = 0; $i -lt $partCount; $i++) {
        $start = $i * $capBytes
        $len = [Math]::Min([long]$capBytes, $bytes.Length - $start)
        $partPath = Join-Path $outputRoot ('{0}.manifest.zip.{1:D3}' -f $projectName, ($i + 1))
        $slice = New-Object byte[] $len
        [System.Array]::Copy($bytes, $start, $slice, 0, $len)
        [System.IO.File]::WriteAllBytes($partPath, $slice)
    }
    Remove-Item -LiteralPath $manifestZipPath
    $manifestPartCount = $partCount
    Write-Verbose "Manifest split into $partCount parts."
}

Write-Progress -Activity 'Packaging' -Status 'Done' -PercentComplete 100 -Completed

# --- Step 8: summary ---------------------------------------------------------

$chunkedFileCount = @($fileManifest | Where-Object { $_.chunks.Count -gt 1 }).Count
$largestShard = if ($shards.Count -gt 0) {
    (Get-ChildItem -LiteralPath $outputRoot -Filter ('{0}.shard*.zip' -f $projectName) |
        Measure-Object -Property Length -Maximum).Maximum
} else { 0 }

Write-Host ""
Write-Host "Package summary:"
Write-Host "  Project name       : $projectName"
Write-Host "  Source files       : $($files.Count)"
Write-Host "  Source bytes       : $($manifest.totalBytes)"
if ($skippedCount -gt 0) {
    # Said out loud, every time. A package that silently dropped a folder
    # someone wanted is worse than one that took ten minutes to build.
    Write-Host "  Excluded           : $skippedCount file(s), $skippedBytes bytes (-NoDefaultExcludes keeps them)"
}
Write-Host "  Chunked files      : $chunkedFileCount"
Write-Host "  Shards written     : $($shards.Count)"
Write-Host "  Largest shard      : $largestShard bytes (cap $capBytes)"
Write-Host "  Empty directories  : $($emptyDirs.Count)"
if ($manifestPartCount -gt 1) {
    Write-Host "  Manifest           : $projectName.manifest.zip split into $manifestPartCount parts"
}
else {
    Write-Host "  Manifest           : $projectName.manifest.zip"
}
Write-Host "  Output folder      : $outputRoot"

$script:Sha256.Dispose()

<#
.SYNOPSIS
    Self-contained proof that Invoke-ShardPack.ps1 / Invoke-ShardRestore.ps1
    round-trip a project folder exactly, including chunked files and a
    split/joined manifest.
.DESCRIPTION
    Builds a fixture tree with every trap the two scripts claim to handle,
    packs it, restores it (including the -VerifyOnly and manifest-join
    paths), and independently compares the restored tree against the
    original. Also exercises two negative cases: a missing shard and a
    corrupted shard. Prints RESULT: PASS/FAIL and sets the exit code
    accordingly.
.PARAMETER MaxShardSizeKB
    Shard cap used for the fixture pack/restore cycle. Default 16 (small
    enough to force multiple shards and force the 200 KB fixture file to
    chunk, without being so small the test takes a long time).
#>
[CmdletBinding()]
param(
    [ValidateRange(8, 1048576)]
    [int]$MaxShardSizeKB = 16
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = Split-Path -Path $PSCommandPath -Parent
$packerScript = Join-Path $scriptDir 'Invoke-ShardPack.ps1'
$restoreScript = Join-Path $scriptDir 'Invoke-ShardRestore.ps1'

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

$runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$testRoot = Join-Path $env:TEMP "shardtest_$runId"
$srcRoot = Join-Path $testRoot 'fixture'
$pkgRoot = Join-Path $testRoot 'pkg'
$restoreRoot1 = Join-Path $testRoot 'restored1'
$restoreRoot2 = Join-Path $testRoot 'restored2'
$restoreRoot3 = Join-Path $testRoot 'restored3'

function Get-FixtureFileSnapshot {
    param([string]$Root)
    $items = Get-ChildItem -LiteralPath $Root -Recurse -Force
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')
    $files = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($rootFull.Length + 1)
            Sha256       = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            LastWriteUtc = $_.LastWriteTimeUtc
            Attributes   = ($_.Attributes -band [System.IO.FileAttributes]'ReadOnly, Hidden')
        }
    })
    $emptyDirs = @($items | Where-Object {
        $_.PSIsContainer -and (Get-ChildItem -LiteralPath $_.FullName -Force | Measure-Object).Count -eq 0
    } | ForEach-Object { $_.FullName.Substring($rootFull.Length + 1) })
    [pscustomobject]@{
        Files      = $files
        EmptyDirs  = $emptyDirs
        FileCount  = $files.Count
    }
}

function Edit-PackageManifest {
    # Rewrites manifest.json inside a package's *.manifest.zip via $Mutate,
    # to simulate a tampered manifest for the negative-case tests.
    param([string]$PackageFolder, [scriptblock]$Mutate)
    $mzipFile = Get-ChildItem -LiteralPath $PackageFolder -Filter '*.manifest.zip' -Force | Select-Object -First 1
    $mz = [System.IO.Compression.ZipFile]::Open($mzipFile.FullName, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $mz.GetEntry('manifest.json')
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $m = $json | ConvertFrom-Json
        & $Mutate $m
        $entry.Delete()
        $newEntry = $mz.CreateEntry('manifest.json')
        $writer = New-Object System.IO.StreamWriter($newEntry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write((ConvertTo-Json -InputObject $m -Depth 6)) } finally { $writer.Dispose() }
    }
    finally { $mz.Dispose() }
}

function Compare-Snapshots {
    param([object]$Original, [object]$Restored, [string]$Label)

    Assert-True ($Original.FileCount -eq $Restored.FileCount) `
        "${Label}: file count mismatch (expected $($Original.FileCount), got $($Restored.FileCount))"

    $origByPath = @{}
    foreach ($f in $Original.Files) { $origByPath[$f.RelativePath] = $f }
    $restByPath = @{}
    foreach ($f in $Restored.Files) { $restByPath[$f.RelativePath] = $f }

    foreach ($path in $origByPath.Keys) {
        if (-not $restByPath.ContainsKey($path)) {
            Assert-True $false "${Label}: restored tree is missing '$path'"
            continue
        }
        $o = $origByPath[$path]
        $r = $restByPath[$path]
        Assert-True ($o.Sha256 -eq $r.Sha256) "${Label}: hash mismatch for '$path'"
        Assert-True ($o.LastWriteUtc -eq $r.LastWriteUtc) "${Label}: LastWriteTimeUtc mismatch for '$path' (orig $($o.LastWriteUtc), restored $($r.LastWriteUtc))"
        Assert-True ($o.Attributes -eq $r.Attributes) "${Label}: attributes mismatch for '$path' (orig $($o.Attributes), restored $($r.Attributes))"
    }

    $origEmptySet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Original.EmptyDirs, [System.StringComparer]::OrdinalIgnoreCase)
    $restEmptySet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Restored.EmptyDirs, [System.StringComparer]::OrdinalIgnoreCase)
    Assert-True ($origEmptySet.SetEquals($restEmptySet)) "${Label}: empty-directory set mismatch"
}

try {
    Write-Host "Building fixture at $srcRoot ..."
    New-Item -ItemType Directory -Path $srcRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $srcRoot 'a\b\c') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $srcRoot 'leaf-empty') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $srcRoot 'only-empty-child\child') -Force | Out-Null

    # small files, enough to force multiple shards via bin-packing
    for ($i = 1; $i -le 6; $i++) {
        $p = Join-Path $srcRoot ('a\b\c\small{0}.txt' -f $i)
        "small file number $i - $(New-Guid)" | Out-File -FilePath $p -Encoding utf8
    }

    # zero-byte file
    $zeroPath = Join-Path $srcRoot 'zero.bin'
    New-Item -ItemType File -Path $zeroPath -Force | Out-Null

    # unicode + spaces + brackets filename
    $unicodePath = Join-Path $srcRoot 'naïve—файл (copy #2).txt'
    "unicode content" | Out-File -FilePath $unicodePath -Encoding utf8

    # hidden file
    $hiddenPath = Join-Path $srcRoot 'hidden.txt'
    "hidden content" | Out-File -FilePath $hiddenPath -Encoding utf8
    (Get-Item -LiteralPath $hiddenPath -Force).Attributes = 'Hidden'

    # readonly file
    $readonlyPath = Join-Path $srcRoot 'readonly.txt'
    "readonly content" | Out-File -FilePath $readonlyPath -Encoding utf8
    (Get-Item -LiteralPath $readonlyPath -Force).Attributes = 'ReadOnly'

    # 200 KB incompressible file -> forces chunking at the 16 KB default cap
    $bigPath = Join-Path $srcRoot 'big.bin'
    $bigBytes = New-Object byte[] (200KB)
    (New-Object System.Random(42)).NextBytes($bigBytes)
    [System.IO.File]::WriteAllBytes($bigPath, $bigBytes)

    $expectedFileCount = 11   # 6 small + zero + unicode + hidden + readonly + big
    $originalSnapshot = Get-FixtureFileSnapshot -Root $srcRoot
    Assert-True ($originalSnapshot.FileCount -eq $expectedFileCount) `
        "Fixture sanity check: expected $expectedFileCount files, found $($originalSnapshot.FileCount) (hidden-file scan may not be using -Force)"

    Write-Host "Packing (cap ${MaxShardSizeKB}KB) ..."
    & $packerScript -SourcePath $srcRoot -OutputPath $pkgRoot -MaxShardSizeKB $MaxShardSizeKB

    $shardZips = @(Get-ChildItem -LiteralPath $pkgRoot -Filter '*.shard*.zip' -Force)
    Assert-True ($shardZips.Count -ge 5) "Expected at least 5 shards, got $($shardZips.Count)"

    $capBytes = [long]$MaxShardSizeKB * 1KB
    $oversized = @(Get-ChildItem -LiteralPath $pkgRoot -Filter '*.zip*' -Force | Where-Object { $_.Length -gt $capBytes })
    Assert-True ($oversized.Count -eq 0) "Found $($oversized.Count) shard(s)/manifest part(s) exceeding the ${capBytes}-byte cap: $(($oversized | ForEach-Object { $_.Name }) -join ', ')"

    $manifestZipExists = (Get-ChildItem -LiteralPath $pkgRoot -Filter '*.manifest.zip' -Force | Measure-Object).Count -gt 0
    Assert-True $manifestZipExists "Expected a *.manifest.zip in the package output"

    Write-Host "Verifying package (-VerifyOnly) ..."
    Push-Location $pkgRoot
    try {
        & $restoreScript -VerifyOnly -ErrorAction Stop | Out-Null
    }
    catch {
        Assert-True $false "-VerifyOnly threw unexpectedly: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }

    Write-Host "Restoring (normal path) ..."
    Push-Location $pkgRoot
    try {
        & $restoreScript -DestinationPath $restoreRoot1 -ErrorAction Stop | Out-Null
    }
    finally {
        Pop-Location
    }
    $restoredSnapshot1 = Get-FixtureFileSnapshot -Root $restoreRoot1
    Compare-Snapshots -Original $originalSnapshot -Restored $restoredSnapshot1 -Label 'Normal restore'

    Write-Host "Exercising manifest-split/join path ..."
    $manifestZip = Get-ChildItem -LiteralPath $pkgRoot -Filter '*.manifest.zip' -Force | Select-Object -First 1
    if ($null -ne $manifestZip) {
        $manifestBytes = [System.IO.File]::ReadAllBytes($manifestZip.FullName)
        $sliceCount = 3
        $sliceSize = [int][Math]::Ceiling($manifestBytes.Length / [double]$sliceCount)
        $baseName = $manifestZip.Name.Substring(0, $manifestZip.Name.Length - '.zip'.Length)  # "<name>.manifest"
        for ($i = 0; $i -lt $sliceCount; $i++) {
            $start = $i * $sliceSize
            if ($start -ge $manifestBytes.Length) { break }
            $len = [Math]::Min($sliceSize, $manifestBytes.Length - $start)
            $slice = New-Object byte[] $len
            [System.Array]::Copy($manifestBytes, $start, $slice, 0, $len)
            $partPath = Join-Path $pkgRoot ('{0}.zip.{1:D3}' -f $baseName, ($i + 1))
            [System.IO.File]::WriteAllBytes($partPath, $slice)
        }
        Remove-Item -LiteralPath $manifestZip.FullName -Force

        Push-Location $pkgRoot
        try {
            & $restoreScript -DestinationPath $restoreRoot2 -ErrorAction Stop | Out-Null
        }
        finally {
            Pop-Location
        }
        $restoredSnapshot2 = Get-FixtureFileSnapshot -Root $restoreRoot2
        Compare-Snapshots -Original $originalSnapshot -Restored $restoredSnapshot2 -Label 'Manifest-join restore'

        # restore the whole manifest zip for the negative-case tests below
        [System.IO.File]::WriteAllBytes($manifestZip.FullName, $manifestBytes)
        # NOTE: Get-ChildItem -Filter uses legacy 8.3 wildcard matching, where a pattern like
        # "fixture.manifest.zip.*" can also match the literal "fixture.manifest.zip" (the same
        # quirk behind "*.xls" matching "book1.xlsx"). Use -like on the exact name instead.
        $partNamePrefix = '{0}.zip.' -f $baseName
        Get-ChildItem -LiteralPath $pkgRoot -Force |
            Where-Object { $_.Name.StartsWith($partNamePrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
            Remove-Item -Force
    }
    else {
        Assert-True $false "Manifest zip disappeared before the split/join test could run"
    }

    Write-Host "Many zero-byte files at a small cap (zip entry overhead) ..."
    $tinySrc = Join-Path $testRoot 'tinyfixture'
    New-Item -ItemType Directory -Path $tinySrc -Force | Out-Null
    for ($i = 1; $i -le 300; $i++) {
        ([System.IO.File]::Create((Join-Path $tinySrc ('keep{0:D3}.gitkeep' -f $i)))).Dispose()
    }
    $tinyPkg = Join-Path $testRoot 'pkg-tiny'
    try {
        & $packerScript -SourcePath $tinySrc -OutputPath $tinyPkg -MaxShardSizeKB 8 | Out-Null
        $tinyOversized = @(Get-ChildItem -LiteralPath $tinyPkg -Filter '*.zip*' -Force | Where-Object { $_.Length -gt 8KB })
        Assert-True ($tinyOversized.Count -eq 0) "Zero-byte fixture produced shard(s)/manifest part(s) over the 8 KB cap: $(($tinyOversized | ForEach-Object { $_.Name }) -join ', ')"
        $tinyDest = Join-Path $testRoot 'restored-tiny'
        & $restoreScript -PackagePath $tinyPkg -DestinationPath $tinyDest -ErrorAction Stop | Out-Null
        $tinyRestoredCount = @(Get-ChildItem -LiteralPath $tinyDest -Recurse -Force -File).Count
        Assert-True ($tinyRestoredCount -eq 300) "Zero-byte fixture restored $tinyRestoredCount of 300 files"
    }
    catch {
        Assert-True $false "Zero-byte fixture pack/restore threw: $($_.Exception.Message)"
    }

    Write-Host "Exclusions: defaults, extra patterns, and -NoDefaultExcludes ..."
    <#
        The shape of a real checkout: source worth keeping, build output and a
        .git folder that should not travel, and a folder holding nothing but
        excluded content - which must still come back as an empty directory,
        because the alternative is a restored tree that quietly changed shape.
    #>
    $exSrc = Join-Path $testRoot 'exfixture'
    foreach ($d in @('App\Code', 'App\bin\Debug', 'App\obj', '.git\objects', 'Media')) {
        New-Item -ItemType Directory -Path (Join-Path $exSrc $d) -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'App\Code\Real.cs'), 'class Real {}')
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'README.md'), '# readme')
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'App\bin\Debug\App.dll'), 'not really a dll')
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'App\obj\tmp.o'), 'obj')
    [System.IO.File]::WriteAllText((Join-Path $exSrc '.git\objects\ab12'), 'git object')
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'App\App.csproj.user'), 'user prefs')
    [System.IO.File]::WriteAllText((Join-Path $exSrc 'Media\clip.mp4'), 'pretend video')

    try {
        $exPkg = Join-Path $testRoot 'pkg-ex'
        & $packerScript -SourcePath $exSrc -OutputPath $exPkg -MaxShardSizeKB 8 | Out-Null
        $exDest = Join-Path $testRoot 'restored-ex'
        & $restoreScript -PackagePath $exPkg -DestinationPath $exDest -ErrorAction Stop | Out-Null

        # Resolved, not used as given: $env:TEMP can contain an 8.3 short
        # segment (BUILDA~1) where FullName always comes back long (buildagent),
        # and slicing by the unresolved length silently produces garbage paths.
        $exDestFull = (Get-Item -LiteralPath $exDest).FullName.TrimEnd('\')
        $exRestored = @(Get-ChildItem -LiteralPath $exDest -Recurse -Force -File |
            ForEach-Object { $_.FullName.Substring($exDestFull.Length + 1) })
        Assert-True ($exRestored -contains 'App\Code\Real.cs') "Default excludes dropped a source file"
        Assert-True ($exRestored -contains 'README.md') "Default excludes dropped README.md"
        Assert-True ($exRestored -contains 'Media\clip.mp4') "Default excludes dropped an unrelated file"
        foreach ($gone in @('App\bin\Debug\App.dll', 'App\obj\tmp.o', '.git\objects\ab12', 'App\App.csproj.user')) {
            Assert-True ($exRestored -notcontains $gone) "Default excludes failed to drop '$gone'"
        }
        # App\bin matches the 'bin' pattern itself, so the folder goes with its
        # contents - restoring an empty bin\ would be worse than useless.
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $exDest 'App\bin'))) `
            "An excluded directory was recreated anyway"

        # -Exclude adds to the defaults rather than replacing them.
        $exPkg2 = Join-Path $testRoot 'pkg-ex2'
        & $packerScript -SourcePath $exSrc -OutputPath $exPkg2 -MaxShardSizeKB 8 -Exclude '*.mp4' | Out-Null
        $exDest2 = Join-Path $testRoot 'restored-ex2'
        & $restoreScript -PackagePath $exPkg2 -DestinationPath $exDest2 -ErrorAction Stop | Out-Null
        $exDest2Full = (Get-Item -LiteralPath $exDest2).FullName.TrimEnd('\')
        $exRestored2 = @(Get-ChildItem -LiteralPath $exDest2 -Recurse -Force -File |
            ForEach-Object { $_.FullName.Substring($exDest2Full.Length + 1) })
        Assert-True ($exRestored2 -notcontains 'Media\clip.mp4') "-Exclude '*.mp4' did not drop the video"
        Assert-True ($exRestored2 -contains 'App\Code\Real.cs') "-Exclude also dropped a source file"
        Assert-True ($exRestored2 -notcontains 'App\obj\tmp.o') "-Exclude replaced the defaults instead of adding to them"
        # Media matches no pattern itself; -Exclude '*.mp4' merely emptied it, so
        # it must still come back. That is the difference between a tree with
        # files removed and a tree that quietly changed shape.
        Assert-True (Test-Path -LiteralPath (Join-Path $exDest2 'Media')) `
            "A directory emptied only by -Exclude was not preserved"

        # -NoDefaultExcludes packs the lot.
        $exPkg3 = Join-Path $testRoot 'pkg-ex3'
        & $packerScript -SourcePath $exSrc -OutputPath $exPkg3 -MaxShardSizeKB 8 -NoDefaultExcludes | Out-Null
        $exDest3 = Join-Path $testRoot 'restored-ex3'
        & $restoreScript -PackagePath $exPkg3 -DestinationPath $exDest3 -ErrorAction Stop | Out-Null
        $exRestored3 = @(Get-ChildItem -LiteralPath $exDest3 -Recurse -Force -File)
        Assert-True ($exRestored3.Count -eq 7) "-NoDefaultExcludes restored $($exRestored3.Count) of 7 files"
    }
    catch {
        Assert-True $false "Exclusion fixture pack/restore threw: $($_.Exception.Message)"
    }

    Write-Host "Negative case: output inside a bracketed source path ..."
    $brkSrc = Join-Path $testRoot 'brk [v2]'
    [System.IO.Directory]::CreateDirectory($brkSrc) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $brkSrc 'file.txt'), 'bracket fixture')
    try {
        & $packerScript -SourcePath $brkSrc -OutputPath (Join-Path $brkSrc 'out') -ErrorAction Stop | Out-Null
        Assert-True $false "Packer did not reject an output folder inside a bracketed source path"
    }
    catch {
        Assert-True ($_.Exception.Message -like '*must not be inside*') `
            "Bracketed self-inclusion error unexpected: $($_.Exception.Message)"
    }

    Write-Host "Negative case: zip-slip manifest ..."
    $slipPkg = Join-Path $testRoot 'pkg-slip'
    Copy-Item -LiteralPath $pkgRoot -Destination $slipPkg -Recurse -Force
    Edit-PackageManifest -PackageFolder $slipPkg -Mutate { param($m) $m.files[0].relativePath = '..\evil.txt' }
    $slipDest = Join-Path $testRoot 'restored-slip'
    try {
        & $restoreScript -PackagePath $slipPkg -DestinationPath $slipDest -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw on a manifest path escaping the destination"
    }
    catch {
        Assert-True ($_.Exception.Message -like '*escapes*') `
            "Zip-slip error did not mention escaping: $($_.Exception.Message)"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'evil.txt'))) `
        "Zip-slip manifest wrote a file outside the destination"

    Write-Host "Negative case: hostile projectName in manifest ..."
    $namePkg = Join-Path $testRoot 'pkg-name'
    Copy-Item -LiteralPath $pkgRoot -Destination $namePkg -Recurse -Force
    Edit-PackageManifest -PackageFolder $namePkg -Mutate { param($m) $m.projectName = '..\..\evil' }
    Push-Location $namePkg
    try {
        & $restoreScript -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw on a hostile projectName with a default destination"
    }
    catch {
        Assert-True ($_.Exception.Message -like '*projectName*') `
            "Hostile-projectName error unexpected: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }

    Write-Host "Negative case: unsupported manifest formatVersion ..."
    $verPkg = Join-Path $testRoot 'pkg-version'
    Copy-Item -LiteralPath $pkgRoot -Destination $verPkg -Recurse -Force
    Edit-PackageManifest -PackageFolder $verPkg -Mutate { param($m) $m.formatVersion = 1 }
    $verDest = Join-Path $testRoot 'restored-version'
    try {
        & $restoreScript -PackagePath $verPkg -DestinationPath $verDest -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw on a version 1 manifest"
    }
    catch {
        Assert-True ($_.Exception.Message -like '*formatVersion*') `
            "Version error did not name the offending field: $($_.Exception.Message)"
        # The version-1 branch has to say how to get the data out, not just that
        # it refused - a bare version number strands whoever is holding an old
        # package with no idea what to do next.
        Assert-True ($_.Exception.Message -like '*partNNNN*') `
            "Version 1 error did not explain how to restore an older package: $($_.Exception.Message)"
    }
    Assert-True (-not (Test-Path -LiteralPath $verDest)) `
        "Destination was created despite an unsupported formatVersion"

    Write-Host "Negative case: -Force destination containing the package ..."
    $wrapRoot = Join-Path $testRoot 'forcewrap'
    $wrapPkg = Join-Path $wrapRoot 'pkgcopy'
    New-Item -ItemType Directory -Path $wrapRoot -Force | Out-Null
    Copy-Item -LiteralPath $pkgRoot -Destination $wrapPkg -Recurse -Force
    try {
        & $restoreScript -PackagePath $wrapPkg -DestinationPath $wrapRoot -Force -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw when the -Force destination contained the package"
    }
    catch {
        Assert-True ($_.Exception.Message -like '*package folder*') `
            "Self-destruct guard error unexpected: $($_.Exception.Message)"
    }
    Assert-True (Test-Path -LiteralPath $wrapPkg) `
        "The package folder was deleted by a -Force restore into its parent"

    Write-Host "Negative case: missing shard ..."
    $victimZip = $shardZips[0].FullName
    $victimBackup = "$victimZip.bak"
    Move-Item -LiteralPath $victimZip -Destination $victimBackup -Force
    Push-Location $pkgRoot
    try {
        & $restoreScript -DestinationPath $restoreRoot3 -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw when a shard was missing"
    }
    catch {
        Assert-True ($_.Exception.Message -like "*$($shardZips[0].Name)*") `
            "Missing-shard error did not name the missing shard: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
        Move-Item -LiteralPath $victimBackup -Destination $victimZip -Force
    }
    Assert-True (-not (Test-Path -LiteralPath $restoreRoot3)) "Destination was created despite a missing shard"

    Write-Host "Negative case: corrupted shard ..."
    $victimBytes = [System.IO.File]::ReadAllBytes($victimZip)
    $victimBytes[100] = $victimBytes[100] -bxor 1
    [System.IO.File]::WriteAllBytes($victimZip, $victimBytes)
    Push-Location $pkgRoot
    try {
        & $restoreScript -DestinationPath $restoreRoot3 -ErrorAction Stop | Out-Null
        Assert-True $false "Restore did not throw when a shard was corrupted"
    }
    catch {
        Assert-True ($_.Exception.Message -like "*$($shardZips[0].Name)*") `
            "Corrupted-shard error did not name the corrupted shard: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }
    Assert-True (-not (Test-Path -LiteralPath $restoreRoot3)) "Destination was created despite a corrupted shard"

    if ($failures.Count -eq 0) {
        Write-Host ""
        Write-Host "RESULT: PASS" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host ""
        Write-Host "RESULT: FAIL ($($failures.Count) assertion(s) failed)" -ForegroundColor Red
        foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
        exit 1
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Get-ChildItem -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
            ForEach-Object { $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

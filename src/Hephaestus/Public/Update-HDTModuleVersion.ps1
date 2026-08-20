function Update-HDTModuleVersion {
    <#
        .SYNOPSIS
            Bumps ModuleVersion in Hephaestus.psd1 when the module's sources have
            moved since the last bump, and does nothing when they have not.

        .DESCRIPTION
            A MODULE VERSION THAT DOES NOT MOVE IS WORSE THAN NO VERSION AT ALL.
            A boot image records the engine version staged into it and the share
            records its own; comparing the two is how a technician finds out that
            WinPE is running last month's engine. That only works if editing the
            engine changes the number, and nobody remembers to edit a manifest by
            hand - so ./build.ps1 -Task version does it.

            WHAT COUNTS AS WHICH BUMP. A file added or removed is a change in
            what the module IS - a new command, a page of markup, a template - so
            it takes the minor and resets the patch. Editing the inside of a file
            that already shipped takes the patch. Neither is semver's promise
            about breakage, because 0.x makes no such promise; they are a build's
            honest report of what moved.

            THE COMPARISON IS AGAINST A HASH THE LAST BUMP RECORDED, not against
            git. "Does the working tree differ from the last commit" bumps again
            on every build until somebody commits, so `ci` twice in a row would
            take 0.2.0 to 0.4.0 - and a fresh clone with no history at all could
            not answer the question. The two hashes live in the manifest under
            PrivateData.HDT, which makes the manifest the record of exactly which
            source tree its version stands for.

            THE FIRST RUN SEEDS AND DOES NOT BUMP. A manifest recording no hashes
            has nothing to compare against, and bumping on that would move the
            version for a tree nobody touched.

            WHAT IS NOT COUNTED: Hephaestus.psd1, because it is what this writes
            to, and Hephaestus.bundle.ps1, because every build regenerates it -
            counting either would make the build bump for its own output, for
            ever. Everything else under the module root is counted, markup and
            string tables included: a window is as much the module as a cmdlet
            is.

            THE MANIFEST IS SPLICED, NEVER RE-SERIALISED. Import-PowerShellDataFile
            followed by a rewrite drops every comment in the file, and this
            manifest is more comment than data. Three values are replaced in
            place, the file's encoding and line endings are left as they were,
            and nothing else moves.

        .PARAMETER ModuleRoot
            The module folder - the one holding Hephaestus.psd1, Private\ and
            Public\.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Changed, Version,
            PreviousVersion, Reason and FileCount.

        .EXAMPLE
            Update-HDTModuleVersion -ModuleRoot 'src/Hephaestus'

        .EXAMPLE
            ./build.ps1 -Task version

            What the build and CI run, before the bundle is written and before
            the module is staged into out/<version>.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NESTED, BECAUSE NOTHING ELSE IN THE MODULE HASHES A STRING. A file of its
    # own would be a public surface for four lines that exist to keep the two
    # fingerprints below from being written out twice.
    function Get-HDTTextHash {
        param([string] $Text)

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [System.BitConverter]::ToString(
                $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')
        } finally {
            $sha.Dispose()
        }
    }

    $manifestName = 'Hephaestus.psd1'
    $bundleName = 'Hephaestus.bundle.ps1'
    $manifestPath = Join-Path -Path $ModuleRoot -ChildPath $manifestName

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ModuleRoot -Category ObjectNotFound `
                    -Message ("'{0}' holds no {1}, so there is no version to update. Point this at the module folder - the one with the manifest in it." -f $ModuleRoot, $manifestName)))
    }

    # THE FINGERPRINT IS TWO HASHES, NOT ONE, because the two answer different
    # questions. The layout - the sorted list of paths - answers "is this a
    # different set of files"; the source hash answers "is any of them
    # different inside". One hash could only say that something moved, and the
    # bump depends on which.
    $file = @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $manifestName -and $_.Name -ne $bundleName })

    $prefix = (Resolve-Path -LiteralPath $ModuleRoot).ProviderPath.TrimEnd('\') + '\'

    $entry = @($file | ForEach-Object {
            $relative = $_.FullName.Substring($prefix.Length)

            [pscustomobject] @{
                Path = $relative
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } | Sort-Object -Property Path)

    $layoutHash = Get-HDTTextHash -Text (@($entry | ForEach-Object { $_.Path }) -join "`n")
    $sourceHash = Get-HDTTextHash -Text (@($entry | ForEach-Object { '{0}|{1}' -f $_.Path, $_.Hash }) -join "`n")

    # READ THE MANIFEST AS TEXT, and read the recorded hashes out of the same
    # text that will be spliced. Import-PowerShellDataFile would answer from a
    # parse, and a key it found in a comment-free parse is not proof that the
    # line this function has to rewrite exists.
    $original = [System.IO.File]::ReadAllText($manifestPath)

    $versionPattern = "(?m)^(\s*ModuleVersion\s*=\s*')([^']*)(')"
    $sourcePattern = "(?m)^(\s*SourceHash\s*=\s*')([^']*)(')"
    $layoutPattern = "(?m)^(\s*LayoutHash\s*=\s*')([^']*)(')"

    foreach ($required in @(@{ Name = 'ModuleVersion'; Pattern = $versionPattern },
            @{ Name = 'SourceHash'; Pattern = $sourcePattern },
            @{ Name = 'LayoutHash'; Pattern = $layoutPattern })) {

        if (-not [regex]::IsMatch($original, $required.Pattern)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $manifestPath -Category InvalidData `
                        -Message ("{0} has no {1} line for the build to write to. It needs ModuleVersion at the top level, and SourceHash and LayoutHash as single-quoted strings under PrivateData.HDT - that is where the build records which source tree the version stands for." -f $manifestName, $required.Name)))
        }
    }

    $currentVersion = [regex]::Match($original, $versionPattern).Groups[2].Value
    $recordedSource = [regex]::Match($original, $sourcePattern).Groups[2].Value
    $recordedLayout = [regex]::Match($original, $layoutPattern).Groups[2].Value

    $version = [version] $currentVersion
    $patch = $version.Build
    if ($patch -lt 0) { $patch = 0 }

    $seeding = [string]::IsNullOrEmpty($recordedSource) -or [string]::IsNullOrEmpty($recordedLayout)
    $layoutMoved = $recordedLayout -ne $layoutHash
    $sourceMoved = $recordedSource -ne $sourceHash

    if ($seeding) {
        $newVersion = $currentVersion
        $reason = 'seeded'
    } elseif ($layoutMoved) {
        $newVersion = '{0}.{1}.0' -f $version.Major, ($version.Minor + 1)
        $reason = 'files added or removed'
    } elseif ($sourceMoved) {
        $newVersion = '{0}.{1}.{2}' -f $version.Major, $version.Minor, ($patch + 1)
        $reason = 'file contents changed'
    } else {
        $newVersion = $currentVersion
        $reason = 'unchanged'
    }

    $answer = [pscustomobject] @{
        Changed         = ($newVersion -ne $currentVersion)
        Version         = $newVersion
        PreviousVersion = $currentVersion
        Reason          = $reason
        FileCount       = $entry.Count
    }

    if ($reason -eq 'unchanged') {
        return $answer
    }

    $updated = [regex]::Replace($original, $versionPattern, ('${1}' + $newVersion + '${3}'))
    $updated = [regex]::Replace($updated, $sourcePattern, ('${1}' + $sourceHash + '${3}'))
    $updated = [regex]::Replace($updated, $layoutPattern, ('${1}' + $layoutHash + '${3}'))

    if ($PSCmdlet.ShouldProcess($manifestPath, ("Set ModuleVersion to {0} ({1})" -f $newVersion, $reason))) {
        # THE BOM IS KEPT IF IT WAS THERE. Windows PowerShell 5.1 reads a
        # BOM-less UTF-8 file as ANSI, so dropping one from a manifest that had
        # it would mangle every non-ASCII character in the file the next time
        # anything read it.
        $hadBom = $false
        $head = New-Object -TypeName 'byte[]' -ArgumentList 3
        $stream = [System.IO.File]::OpenRead($manifestPath)
        try {
            $read = $stream.Read($head, 0, 3)
            $hadBom = ($read -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
        } finally {
            $stream.Dispose()
        }

        $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $hadBom
        [System.IO.File]::WriteAllText($manifestPath, $updated, $encoding)
    }

    return $answer
}

function Write-HDTModuleBundle {
    <#
        .SYNOPSIS
            Concatenates the module's sources into one file, so importing it
            parses one file instead of 363.

        .DESCRIPTION
            IMPORTING THIS MODULE COSTS 2.6 SECONDS, and 2.46 of that is the
            dot-sourcing loop: PowerShell parses 2.6 MB of script - comment-based
            help included - once per import, paying the per-file cost 363 times.
            The same code in one file parses in 1.37 seconds. Measured on the
            lab host, in a fresh Windows PowerShell 5.1 process.

            IT MATTERS BECAUSE OF -Detach. Start-HDTConsole -Detach starts a
            fresh powershell.exe, which imports the module cold before it can
            draw anything, so this is a second of somebody watching nothing
            happen.

            THE BUNDLE IS A BUILD ARTEFACT, NOT A SOURCE FILE. It is generated,
            never edited, and never committed - and it is the only thing
            Hephaestus.psm1 loads, so a developer who never runs the build is
            exactly as correct as one who does: the loader calls this itself
            whenever the bundle is missing or older than a source.

            PRIVATE BEFORE PUBLIC, which is the order the loader uses: a public
            function's parameter default can call a private one at load time
            (New-HDTFileSystem is one), and a function that is not defined yet
            is a parse that succeeds and a call that fails.

            NOTHING IS REWRITTEN ON THE WAY IN. The text of each file is copied
            verbatim, so a stack trace from the bundle names the same function
            and the same line contents as the file it came from. Which file, and
            which line of it, is recovered with Resolve-HDTBundleLine from the
            '# ---- source: ... ----' marker written above each one.

        .PARAMETER ModuleRoot
            The module folder - the one holding Private\ and Public\.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FileCount and
            Length.

        .EXAMPLE
            Write-HDTModuleBundle -ModuleRoot 'C:\Users\Itamartz\Documents\GithubRepos\HDT\src\Hephaestus'

            Concatenates every source file into Hephaestus.bundle.ps1, which is the one
            file the module loads. Dot-sourcing the sources costs a second longer,
            and that second is what somebody watches nothing happen for after
            Start-HDTConsole -Detach.

        .EXAMPLE
            $bundle = Write-HDTModuleBundle -ModuleRoot 'C:\Users\Itamartz\Documents\GithubRepos\HDT\src\Hephaestus'
            $bundle.SourceCount

            How many files went into it. The bundle is generated and never
            committed; ./build.ps1 -Task bundle is what runs this deliberately,
            and the module rebuilds it itself when a source is newer.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one generated build artefact into the module folder it was handed; it is not a state change an administrator needs protecting from, and the build calls it unattended.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $bundleName = 'Hephaestus.bundle.ps1'
    $bundlePath = Join-Path -Path $ModuleRoot -ChildPath $bundleName

    $privateFile = @(Get-ChildItem -Path (Join-Path -Path $ModuleRoot -ChildPath 'Private') `
            -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName)

    $publicFile = @(Get-ChildItem -Path (Join-Path -Path $ModuleRoot -ChildPath 'Public') `
            -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName)

    $file = @($privateFile + $publicFile)

    if (@($file).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ModuleRoot -Category ObjectNotFound `
                    -Message ("'{0}' holds no Private or Public script files, so there is nothing to bundle. Point this at the module folder - the one with Hephaestus.psd1 in it." -f $ModuleRoot)))
    }

    $text = New-Object -TypeName System.Text.StringBuilder

    [void] $text.AppendLine('# GENERATED. Do not edit, and do not commit.')
    [void] $text.AppendLine('#')
    [void] $text.AppendLine('# Every Private and Public script of this module, concatenated, so that')
    [void] $text.AppendLine('# importing it parses one file instead of several hundred. Written by')
    [void] $text.AppendLine('# Write-HDTModuleBundle; this is the only thing Hephaestus.psm1 loads,')
    [void] $text.AppendLine('# and it is rebuilt on import whenever a source is newer than it.')
    [void] $text.AppendLine('#')
    [void] $text.AppendLine('# A line number in here maps back to a source with Resolve-HDTBundleLine.')
    [void] $text.AppendLine('')

    # WHAT TO EXPORT, BECAUSE THE FOLDER MAY NOT TRAVEL WITH IT.
    #
    # A module that ships as a bundle and NOTHING ELSE is what goes into a boot
    # image and onto a deployed machine. Public\ is not there to enumerate, so
    # without this list Hephaestus.psm1 would load every function and export
    # none of them: an import with no error and CommandNotFound for everything,
    # on a machine mid-deployment.
    #
    # THE LIST IS WRITTEN HERE BECAUSE IT IS KNOWN HERE - these are the files
    # just read. The alternative was Import-PowerShellDataFile against the
    # manifest at load time, which is one more thing that has to exist inside
    # WinPE for the engine to export a command.
    #
    # ABOVE THE SOURCES, NOT BELOW THEM. Anything written after the last file
    # is a run of lines belonging to no source, sitting where Resolve-HDTBundleLine
    # can only read them as the last file overrunning its own end. Up here it is
    # preamble, and preamble is already unmapped.
    $exportName = @(@($publicFile) | ForEach-Object { $_.BaseName } | Sort-Object)

    [void] $text.AppendLine(('$script:HDTBundleExport = @({0})' -f
            ((@($exportName) | ForEach-Object { "'{0}'" -f $_ }) -join ', ')))
    [void] $text.AppendLine('')

    # THE ROOT, WITH ITS TRAILING SEPARATOR, so each marker below can be cut down
    # to 'Public\Foo.ps1'. GetFullPath normalises 'src/Hephaestus' and a relative
    # -ModuleRoot alike, which is what makes the comparison with FullName sound.
    $rootPrefix = [System.IO.Path]::GetFullPath($ModuleRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar

    foreach ($current in @($file)) {
        # THE FILE IT CAME FROM, ON THE LINE ABOVE IT. A bundle is what a stack
        # trace, a breakpoint and a coverage report all name, and 'line 214,207
        # of Hephaestus.bundle.ps1' is an answer nobody can act on without this.
        # Resolve-HDTBundleLine reads these back; PowerShell itself ignores them,
        # because it has no #line directive - a comment is just a comment.
        #
        # RELATIVE TO THE MODULE ROOT, NEVER THE BUILD MACHINE'S ABSOLUTE PATH.
        # The bundle runs somewhere else - a boot image, a deployed disk, a
        # Gallery install - where C:\Users\...\GithubRepos\HDT does not exist,
        # and an artefact that names the machine that built it also differs
        # between two machines building identical code.
        $relative = $current.FullName

        if ($relative.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $relative.Substring($rootPrefix.Length)
        }

        [void] $text.AppendLine(('# ---- source: {0} ----' -f $relative))
        [void] $text.AppendLine([System.IO.File]::ReadAllText($current.FullName))
    }

    # NO BOM, AND THE LINE ENDINGS THE SOURCES HAD. Windows PowerShell 5.1 reads
    # a BOM-less UTF-8 file as ASCII unless it has one - and every source here is
    # ASCII by contract (the analyzer settings say so), so this is safe and keeps
    # the artefact byte-comparable between machines.
    [System.IO.File]::WriteAllText($bundlePath, $text.ToString(),
        (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

    # NEWER THAN EVERYTHING IT WAS BUILT FROM, or the loader would ignore it on
    # every import. A file written this instant normally is, but a source with a
    # clock-skewed timestamp - restored from a backup, copied from a share - is
    # not something to discover as a silently ignored bundle.
    $newest = @(@($file) | Sort-Object -Property LastWriteTimeUtc -Descending)[0]
    $written = Get-Item -LiteralPath $bundlePath

    if ($written.LastWriteTimeUtc -lt $newest.LastWriteTimeUtc) {
        $written.LastWriteTimeUtc = $newest.LastWriteTimeUtc.AddSeconds(1)
    }

    return [pscustomobject] @{
        Path      = $bundlePath
        FileCount = @($file).Count
        Length    = (Get-Item -LiteralPath $bundlePath).Length
    }
}

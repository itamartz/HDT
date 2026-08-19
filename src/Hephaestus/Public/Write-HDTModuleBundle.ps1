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
            never edited, and never committed - Hephaestus.psm1 falls back to
            the individual files whenever it is missing or older than any of
            them, so a developer who never runs the build is exactly as correct
            as one who does, only slower.

            PRIVATE BEFORE PUBLIC, which is the order the loader uses: a public
            function's parameter default can call a private one at load time
            (New-HDTFileSystem is one), and a function that is not defined yet
            is a parse that succeeds and a call that fails.

            NOTHING IS REWRITTEN ON THE WAY IN. The text of each file is copied
            verbatim, so a stack trace from the bundle names the same function
            and the same line contents as the file it came from.

        .PARAMETER ModuleRoot
            The module folder - the one holding Private\ and Public\.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FileCount and
            Length.

        .EXAMPLE
            Write-HDTModuleBundle -ModuleRoot 'src/Hephaestus'

        .EXAMPLE
            ./build.ps1 -Task bundle

            What CI and the package task run.
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
    [void] $text.AppendLine('# Write-HDTModuleBundle; Hephaestus.psm1 ignores this file whenever any')
    [void] $text.AppendLine('# source is newer than it, so editing a source is always what runs.')
    [void] $text.AppendLine('')

    foreach ($current in @($file)) {
        # THE FILE IT CAME FROM, ON THE LINE ABOVE IT. A bundle is what a stack
        # trace names, and 'line 41,207 of Hephaestus.bundle.ps1' is an answer
        # nobody can act on without this.
        [void] $text.AppendLine(('# ---- {0} ----' -f $current.FullName))
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

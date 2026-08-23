function Resolve-HDTBundleLine {
    <#
        .SYNOPSIS
            Maps a line number in Hephaestus.bundle.ps1 back to the source file
            and line it was concatenated from.

        .DESCRIPTION
            THE MODULE RUNS AS ONE FILE. Hephaestus.psm1 loads
            Hephaestus.bundle.ps1 and nothing else - 377 sources concatenated,
            2.8 MB - because that is what a boot image and a deployed disk can
            afford to read and parse. Everything PowerShell then reports about
            the running code names that file: a stack trace, a breakpoint, a
            code coverage report.

            'AT LINE 214207, CHAR 9' IS NOT AN ANSWER ANYBODY CAN ACT ON, and
            PowerShell will not give a better one - it has no #line directive,
            so a comment naming the original file is just a comment to it. The
            mapping has to be done by hand, which is why ModuleBuilder ships its
            own ConvertTo-SourceLineNumber for the same reason.

            SO THIS READS THE MARKERS BACK. Write-HDTModuleBundle writes

                # ---- source: Public\Get-HDTBootImage.ps1 ----

            above each file. A line below that marker and above the next one came
            from that file, at that many lines past the marker.

            LINES THAT CAME FROM NO FILE ANSWER NOTHING - the generated preamble,
            the export list, the marker lines themselves. Nothing is the honest
            answer for them, and it keeps a bulk call over a coverage report from
            inventing a source for a line the build wrote.

        .PARAMETER Line
            One or more 1-based line numbers in the bundle. Takes a list, and
            the pipeline, because a coverage report is thousands of them and
            reading the bundle once per line is not free.

        .PARAMETER Path
            The bundle to read. Defaults to the one this module was loaded from.

        .INPUTS
            System.Int32. Line numbers, from the pipeline.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with BundleLine, Path
            and Line. Path is relative to the module root, as the marker records
            it - the machine that built the bundle is not the one running it.

        .EXAMPLE
            $trace = try { throw 'x' } catch { $_ }
            Resolve-HDTBundleLine -Line 214207

            BundleLine Path                            Line
            ---------- ----                            ----
                214207 Public\Update-HDTBootImage.ps1   612

            The stack trace case: a failure inside WinPE, and no idea which of
            377 files it came out of.

        .EXAMPLE
            $trace.ScriptStackTrace -split "`n" |
                ForEach-Object { if ($_ -match ':\s*line\s*(\d+)') { [int] $Matches[1] } } |
                Resolve-HDTBundleLine

            A whole stack, mapped in one read of the bundle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int[]] $Line,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        if (-not $PSBoundParameters.ContainsKey('Path')) {
            # $script:HDTModuleRoot is set by Hephaestus.psm1. Get-Variable
            # rather than naming it: under Set-StrictMode -Version Latest an
            # unassigned variable is an error, and this file is also dot-sourced
            # on its own by the loader's bootstrap.
            $root = Get-Variable -Name 'HDTModuleRoot' -Scope Script -ValueOnly -ErrorAction SilentlyContinue

            if ([string]::IsNullOrEmpty($root)) {
                $root = $PSScriptRoot
            }

            $Path = Join-Path -Path $root -ChildPath 'Hephaestus.bundle.ps1'
        }

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path -Category ObjectNotFound `
                        -Message 'There is no bundle here to map a line against. Build one with ./build.ps1 -Task bundle, or import the module - the loader writes it.'))
        }

        $content = @([System.IO.File]::ReadAllLines($Path))

        # THE MARKERS, IN THE ORDER THEY APPEAR, WHICH IS ASCENDING BY DEFINITION.
        # That is what lets the lookup below be a binary search instead of a scan
        # of 377 entries per line of a coverage report.
        $markerAt = New-Object -TypeName System.Collections.Generic.List[int]
        $markerPath = New-Object -TypeName System.Collections.Generic.List[string]

        for ($index = 0; $index -lt $content.Count; $index++) {
            if ($content[$index] -match '^# ---- source: (.+?) ---- *$') {
                $markerAt.Add($index + 1)
                $markerPath.Add($Matches[1])
            }
        }

        if ($markerAt.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path -Category InvalidData `
                        -Message "This file carries no '# ---- source: ... ----' markers, so it is not a bundle Write-HDTModuleBundle produced. Rebuild it with ./build.ps1 -Task bundle."))
        }

        $at = $markerAt.ToArray()
        $lineCount = $content.Count
    }

    process {
        foreach ($current in @($Line)) {
            if ($current -gt $lineCount) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path -Line $current -Category InvalidArgument `
                            -Message ('The bundle has {0} lines, so there is no line {1} in it to map. Check the line number came from this bundle - a rebuild moves them.' -f
                                $lineCount, $current)))
            }

            # A NEGATIVE RESULT IS THE USEFUL ONE. BinarySearch returns the index
            # when the line IS a marker - a line that came from no file - and the
            # complement of the insertion point when it is not, which is one past
            # the marker that owns it.
            $found = [array]::BinarySearch($at, $current)

            if ($found -ge 0) {
                continue
            }

            $owner = (-bnot $found) - 1

            # Above the first marker: the generated preamble and the export list.
            if ($owner -lt 0) {
                continue
            }

            [pscustomobject] @{
                BundleLine = $current
                Path       = $markerPath[$owner]
                Line       = $current - $at[$owner]
            }
        }
    }
}

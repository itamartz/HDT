function Get-HDTScratchLeakViolation {
    <#
        .SYNOPSIS
            Reports every scratch directory a test file fills and never gives
            back.

        .DESCRIPTION
            Get-HDTScratchRootReference with the judgement applied: a violation
            is a C:\HDTLab\scratch root the file names, does not remove, and that
            the caller has not declared kept.

            THE KEEP LIST BELONGS TO THE CALLER, in one reviewed place, and not
            to the suite asking for the exemption. ScratchTeardown.Contract holds
            it: three artifact roots holding the screenshots, RESULT.json,
            HDT.jsonl and state.json copied off a content disk the AfterAll then
            destroys, which tests/e2e/README.md is a table of. Deleting those at
            the end of every run would leave every future E2E failure
            undiagnosable, and they are bounded anyway - each run overwrites the
            same filenames, and the lot came to about 6 MB against 5 GB of build
            roots.

            C:\HDTLab\scratch\bootimage IS ON NO LIST HERE. Nothing in tests/e2e
            names it, and if something ever does it will be reported as a leak
            rather than removed - which is the right way round, because it is the
            user's live build scratch and the contract asserts by name that no
            teardown targets it.

        .PARAMETER Path
            One or more PowerShell files to judge.

        .PARAMETER Keep
            Scratch roots that are deliberately not removed. Compared whole and
            case-insensitively.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Root, Line and
            Message.

        .EXAMPLE
            Get-ChildItem ./tests/e2e -Filter *.ps1 |
                ForEach-Object { $_.FullName } |
                Get-HDTScratchLeakViolation -Keep 'C:\HDTLab\scratch\e2e'

            Scans the whole slow suite, allowing the M3 artifact root to stand.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Keep = @()
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $kept = @{}
        foreach ($root in @($Keep)) {
            if (-not [string]::IsNullOrWhiteSpace($root)) {
                $kept[$root.Trim().TrimEnd('\', '/').ToLowerInvariant()] = $true
            }
        }
    }

    process {
        foreach ($reference in @(Get-HDTScratchRootReference -Path $Path)) {
            if ($reference.Removed) { continue }
            if ($kept.ContainsKey($reference.Root.ToLowerInvariant())) { continue }

            [pscustomobject] @{
                Path    = $reference.Path
                Root    = $reference.Root
                Line    = $reference.Line
                Message = ("'{0}' is built by this file and never removed. Give it back in the AfterAll with Remove-HDTLabScratchTree, or add it to the KEEP list in ScratchTeardown.Contract.Tests.ps1 with the reason it has to stand." -f $reference.Root)
            }
        }
    }
}

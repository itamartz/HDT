function Remove-HDTLabScratchTree {
    <#
        .SYNOPSIS
            Removes one scratch directory a slow suite built, and refuses
            everything else.

        .DESCRIPTION
            The teardown half of the E2E suites. Each of them builds a boot image
            into its own root under C:\HDTLab\scratch - a gigabyte or two a run -
            and before this existed not one of them gave it back: the scratch
            area reached 7.1 GB, 5 GB of it dead build roots.

            IT IS A COMMAND RATHER THAN FOUR COPIES OF Remove-Item because of
            CLAUDE.md, "Paths that must never be deleted": never pass a variable
            to Remove-Item -Recurse without asserting first that it is one of the
            permitted locations. Written once the assertion can be proven;
            written four times it is four chances to get it wrong, and the one
            that is wrong takes the staged media with it.

            WHAT IT ACCEPTS is exactly one shape: a FIRST-LEVEL directory under
            C:\HDTLab\scratch\, spelt out, with no wildcard and no '..' in it.
            Not the scratch area itself, not the lab root, not a drive root, not
            a path on another volume, not a relative path, and not a deeper path
            - because a deeper path is how somebody eventually names
            bootimage\work and takes the live build scratch's mount tree with it.

            C:\HDTLab\scratch\bootimage IS REFUSED BY NAME, and so is anything
            inside it. It is the user's live build scratch: already bounded,
            because Update-HDTBootImage empties it at the start of every run, and
            read afterwards by the tests that answer "what actually went into my
            image?". A cleanup that removed it would break those and take the
            debuggability with it.

            A STRANDED DISM MOUNT IS THE REASON THE REMOVAL CAN FAIL. A boot
            image build that died between mount and dismount leaves a WIM mounted
            inside the scratch tree holding files open, and Remove-Item -Recurse
            then throws part-way through and leaves half a tree. So every image
            mounted under the target is discarded FIRST. If the removal still
            fails the function WARNS - it never throws, because it is called from
            an AfterAll that runs after a failure and a teardown that throws
            turns one red test into a red container - and the warning says LEAK
            and names the path, so a green run that leaked still says so.

            THE REFUSALS ARE THROWS, and that is deliberate: a wrong target is a
            defect in the caller, not a condition to tolerate. Callers pass a
            literal, so the throw can only ever fire while somebody is editing.

        .PARAMETER Path
            The scratch directory to remove. Must be a first-level directory
            under C:\HDTLab\scratch, and must not be the live build scratch.

        .OUTPUTS
            None.

        .EXAMPLE
            Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-bootimage' -Confirm:$false

            What UnattendedDeployment.E2E.Tests.ps1 calls from its AfterAll.

        .EXAMPLE
            Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\bootimage'

            Throws. That directory is the user's live build scratch.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- the guard ---------------------------------------------------------
    #
    # Everything below runs BEFORE anything is touched, and every failure is a
    # throw. The word "refuses" is in each message because the tests match on it.

    $area = 'C:\HDTLab\scratch'
    $live = 'bootimage'

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw ('Remove-HDTLabScratchTree refuses an empty target. An AfterAll that runs after its BeforeAll threw holds $null or "", and "" is not a directory this may delete (CLAUDE.md, "Paths that must never be deleted").')
    }

    $trimmed = $Path.Trim().TrimEnd('\', '/')

    if ($trimmed -match '[*?]') {
        throw ("Remove-HDTLabScratchTree refuses '{0}': a wildcard names a set, and this deletes one directory it was told the whole name of." -f $Path)
    }

    if ($trimmed -match '(^|[\\/])\.\.([\\/]|$)') {
        throw ("Remove-HDTLabScratchTree refuses '{0}': a relative segment can climb out of the scratch area." -f $Path)
    }

    # The prefix test is on the string as written, not on a resolved path: a
    # resolve would follow a junction out of the scratch area, and the caller is
    # expected to pass a literal anyway.
    $prefix = $area + '\'

    if (-not $trimmed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Remove-HDTLabScratchTree refuses '{0}': the only directories it may delete are first-level ones under the scratch area, and that is not one of them (CLAUDE.md, 'Paths that must never be deleted')." -f $Path)
    }

    $leaf = $trimmed.Substring($prefix.Length)

    if ([string]::IsNullOrWhiteSpace($leaf)) {
        throw ("Remove-HDTLabScratchTree refuses '{0}': that is the scratch area itself, and every suite's work is in it." -f $Path)
    }

    if ($leaf -match '[\\/]') {
        $first = ($leaf -split '[\\/]')[0]

        if ($first -eq $live) {
            throw ("Remove-HDTLabScratchTree refuses '{0}': it is inside the live build scratch. Update-HDTBootImage empties that directory itself, and the integration suite reads its mount tree afterwards to answer what went into the image." -f $Path)
        }

        throw ("Remove-HDTLabScratchTree refuses '{0}': it names a directory below the first level, which is how somebody eventually deletes a mount folder out from under a build. Name the root the run created." -f $Path)
    }

    if ($leaf -eq $live) {
        throw ("Remove-HDTLabScratchTree refuses '{0}': it is the live build scratch. Update-HDTBootImage empties that directory at the start of every run, and the integration suite reads its mount tree afterwards to answer what went into the image." -f $Path)
    }

    # -- the target is legal from here on ----------------------------------

    if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
        return
    }

    if (-not $PSCmdlet.ShouldProcess($trimmed, 'Remove the scratch directory this run created')) {
        return
    }

    # A boot image build that died between mount and dismount leaves a WIM
    # mounted inside this tree holding files open, and the recursive delete then
    # throws part-way and leaves half a tree behind. Discard those first.
    #
    # Best effort, and silent when there is nothing to do: the usual run has no
    # mount at all, and Get-WindowsImage is unavailable on a machine with no DISM
    # PowerShell module.
    try {
        if (Get-Command -Name 'Get-WindowsImage' -ErrorAction SilentlyContinue) {
            $stranded = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { ([string] $_.Path).StartsWith(($trimmed + '\'), [System.StringComparison]::OrdinalIgnoreCase) -or
                        ([string] $_.Path) -eq $trimmed })

            foreach ($image in $stranded) {
                Write-Warning ("dismounting a stranded image at '{0}' before the teardown can remove the tree" -f $image.Path)
                Dismount-WindowsImage -Path ([string] $image.Path) -Discard -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        Write-Warning ("could not dismount a stranded image under the scratch tree: {0}" -f $_.Exception.Message)
    }

    # -LiteralPath to the one directory named above, never a target built by
    # enumerating a parent.
    try {
        Remove-Item -LiteralPath $trimmed -Recurse -Force -ErrorAction Stop
    } catch {
        # LOUD, because the alternative is a leak that comes back silently: the
        # size is what makes it obvious in a scrollback.
        $megabyte = 0
        try {
            $byte = (Get-ChildItem -LiteralPath $trimmed -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            if ($null -ne $byte) { $megabyte = [math]::Round(($byte / 1MB), 0) }
        } catch {
            $megabyte = 0
        }

        Write-Warning ("SCRATCH LEAK: '{0}' could not be removed and is still there, holding about {1} MB. The usual cause is a stranded DISM mount keeping files open - run 'dism /cleanup-wim' and delete it by hand. The teardown carried on rather than failing the suite. Reason: {2}" -f
            $trimmed, $megabyte, $_.Exception.Message)
    }
}

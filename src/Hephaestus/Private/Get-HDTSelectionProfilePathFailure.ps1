function Get-HDTSelectionProfilePathFailure {
    <#
        .SYNOPSIS
            Why an include path may not be included, or nothing if it may.

        .DESCRIPTION
            THE SECURITY BOUNDARY OF SELECTION PROFILES, in one place so the
            validator, the setter and the console cannot disagree about it.

            Expand-HDTSelectionProfile turns an include into a folder under the
            share, and the boot image build hands that folder to
            Add-WindowsDriver WITH -Recurse. So an include that escapes the share
            does not merely read a file: its contents end up inside a WIM that is
            transferred to every machine that PXE boots. Four rules close that:

              not blank      an empty entry would resolve to the share root, which
                             is 'everything, including the logs' by accident
              not rooted     'C:\Windows\System32\DriverStore' and '\\server\x'
                             ignore the share entirely
              no '..'        'Drivers\..\..\Windows' walks out one segment at a
                             time and passes a naive prefix check
              a known folder the first segment must be one of
                             Get-HDTSelectionProfileContentFolder's

            IT RETURNS A SENTENCE RATHER THAN THROWING. The callers each build
            their own terminating error naming their own file and profile, and a
            nested ThrowTerminatingError here would rewrite the error id those
            failures are asserted on.

            THE CHECK IS TEXTUAL, NOT A GetFullPath COMPARISON, deliberately.
            Resolving against a root would need the share to exist, and a profile
            is authored on a workstation against a share that is a UNC path
            nobody has mounted - Get-HDTWorkspacePath has the same rule and the
            same reason.

        .PARAMETER Include
            The share-relative path to check.

        .PARAMETER ContentFolder
            The legal first segments. Omitted, the standard set.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the reason it is refused, or an empty string.

        .EXAMPLE
            Get-HDTSelectionProfilePathFailure -Include 'Drivers\WinPE\Dell WinPE 11 x64'

            Returns '', because that is a folder under Drivers\.

        .EXAMPLE
            Get-HDTSelectionProfilePathFailure -Include 'Drivers\..\..\Windows'

            Returns the sentence about '..' - the traversal this exists to stop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Include,

        [Parameter()]
        [AllowNull()]
        [string[]] $ContentFolder = (Get-HDTSelectionProfileContentFolder)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Include)) {
        return 'an include may not be blank. A blank one resolves to the share root, which includes the logs and the captures with it.'
    }

    if ([System.IO.Path]::IsPathRooted($Include)) {
        return 'an include is a path RELATIVE to the share, not an absolute one. Write ''Drivers\WinPE\Dell WinPE 11 x64'', not a drive or a UNC path.'
    }

    $segment = @($Include -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if (@($segment | Where-Object { $_ -eq '..' }).Count -gt 0) {
        return 'an include may not contain ''..''. It would name a folder outside the share, and the boot image build injects what it names recursively.'
    }

    if (@($segment).Count -eq 0) {
        return 'an include may not be a bare separator.'
    }

    if ($ContentFolder -notcontains $segment[0]) {
        return ("'{0}' is not a folder a profile may include from. The first segment must be one of {1}." -f
            $segment[0], (@($ContentFolder) -join ', '))
    }

    return ''
}

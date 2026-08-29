function Format-HDTConsoleByteCount {
    <#
        .SYNOPSIS
            Renders a size in bytes the way the console shows it.

        .DESCRIPTION
            Both figures, always: the exact byte count an operator can compare
            against a directory listing, and the MB an operator can compare
            against a USB stick. Rounding to MB alone loses the comparison that
            catches a truncated artifact.

            INVARIANT CULTURE, DELIBERATELY. '{0:N0}' groups by the current
            culture, so the same share would render 495,334,205 on one desk and
            495.334.205 on another - and a screenshot could not be compared with
            a test or with the manifest it came from.

        .PARAMETER Byte
            The size in bytes.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Format-HDTConsoleByteCount -Byte 495334205

            Returns '495,334,205 bytes (472.4 MB)'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [long] $Byte,

        # ONE UNIT, FOR A LINE THAT HAS A SENTENCE ROUND IT. The console's
        # properties pane shows a size in a field of its own, where exactness is
        # free and "495,334,205 bytes (472.4 MB)" is the right answer. A LOG LINE
        # is different: "staged Latitude 5490 (126 .inf, 1302 files, 3.5 GB) to
        # W:\Drivers in 48078 ms" has to be read at a glance, and the full form
        # would be a third of its width for a number nobody counts digits on.
        #
        # A SWITCH RATHER THAN A SECOND FORMATTER, because two of these would
        # eventually disagree about what a megabyte is.
        [Parameter()]
        [switch] $Compact
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Compact) {
        if ($Byte -ge 1GB) {
            return [string]::Format([cultureinfo]::InvariantCulture, '{0:N1} GB', ($Byte / 1GB))
        }

        if ($Byte -ge 1MB) {
            return [string]::Format([cultureinfo]::InvariantCulture, '{0:N1} MB', ($Byte / 1MB))
        }

        if ($Byte -ge 1KB) {
            return [string]::Format([cultureinfo]::InvariantCulture, '{0:N1} KB', ($Byte / 1KB))
        }

        return [string]::Format([cultureinfo]::InvariantCulture, '{0:N0} bytes', $Byte)
    }

    return [string]::Format([cultureinfo]::InvariantCulture, '{0:N0} bytes ({1:N1} MB)',
        $Byte, ($Byte / 1MB))
}

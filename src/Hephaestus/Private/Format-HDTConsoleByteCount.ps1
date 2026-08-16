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
        [long] $Byte
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string]::Format([cultureinfo]::InvariantCulture, '{0:N0} bytes ({1:N1} MB)',
        $Byte, ($Byte / 1MB))
}

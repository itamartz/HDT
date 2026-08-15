function Get-HDTUsableAddress {
    <#
        .SYNOPSIS
            The first IPv4 address on this machine that a share could be reached
            from, or nothing.

        .DESCRIPTION
            FOUND ON A LIVE MACHINE, FROM ITS OWN LOG. A VM in WinPE printed
            "waiting for an address" seven times while holding 192.168.2.39 the
            whole time, because the payload did this inline:

                foreach ($candidate in (([string] $fact['HDTIPAddress']) -split ','))

            HDTIPAddress is a [string[]] (Get-HDTMachineFact). Casting an array
            to a string SPACE-joins it, so the comma split produced one element -
            '192.168.2.39 fe80::7796:...' - which matches no IPv4 pattern. The
            machine waited the full timeout for an address it already had.

            IT IS A COMMAND BECAUSE IT WAS A BUG. Inline in the payload it was
            reachable only by booting a VM; the payload's own test reads that
            file's SHAPE and cannot execute it. A decision has to be a command
            before a test can find anything wrong with it.

            EVERY SHAPE THE FACT CAN ARRIVE IN is read: the array it really is,
            a single string, a comma-joined string, and the space-joined string
            the broken cast produced. A reader that accepted only one of them is
            how this happened.

            APIPA IS NOT AN ADDRESS. 169.254.* is precisely the case where a
            machine looks connected and can reach nothing (SPIKES S9.2), and
            0.0.0.0 is the unconfigured adapter saying so.

        .PARAMETER Fact
            What Get-HDTMachineFact returned. Null is not an error.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the address, or empty.

        .EXAMPLE
            Get-HDTUsableAddress -Fact $fact
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Fact
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Fact) { return '' }
    if (-not $Fact.Contains('HDTIPAddress')) { return '' }

    $value = $Fact['HDTIPAddress']
    if ($null -eq $value) { return '' }

    # SPLIT ON COMMA AND WHITESPACE, over each element of whatever arrived - so
    # the array, the comma-joined string and the space-joined one all read the
    # same.
    $candidate = @()
    foreach ($item in @($value)) {
        if ($null -eq $item) { continue }
        $candidate += ([string] $item) -split '[,\s]+'
    }

    foreach ($address in $candidate) {

        $trimmed = ([string] $address).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { continue }

        if ($trimmed.StartsWith('169.254.')) { continue }
        if ($trimmed -eq '0.0.0.0') { continue }

        return $trimmed
    }

    return ''
}

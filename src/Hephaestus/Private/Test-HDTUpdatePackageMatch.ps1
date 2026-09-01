function Test-HDTUpdatePackageMatch {
    <#
        .SYNOPSIS
            Whether a package identity DISM reports is the one an update
            installs.

        .DESCRIPTION
            THE TWO STRINGS ARE NOT EQUAL AND NEVER WILL BE, which is the whole
            reason this exists rather than an -eq. A package's own CompDB names
            it without the publisher key:

              Package_for_RollupFix~~amd64~~26100.8655.1.20

            and DISM, listing the same package on a serviced image, names it with
            one:

              Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8655.1.20

            Both were read on 2026-09-01 from the same apply. A comparison that
            expected them to match would decide that no update ever landed, and
            the step that verifies an apply by re-reading the image would report
            every successful package as a failure.

            SO THE TILDE-SEPARATED FIELDS ARE COMPARED, MINUS THE PUBLISHER KEY.
            The name, the architecture and the version are what identify a
            package; the public key token is who signed it, is constant for
            everything Microsoft ships, and is exactly the field the two spellings
            disagree about.

            IT IS DELIBERATELY NOT A prefix OR A -like. 26100.8655.1.2 is a prefix
            of 26100.8655.1.20 and a different package, so a step verifying an
            apply would accept the wrong one.

        .PARAMETER Installed
            The package identity as DISM reported it.

        .PARAMETER PackageId
            The package identity as the update's own metadata gave it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean.

        .EXAMPLE
            Test-HDTUpdatePackageMatch -Installed 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8655.1.20' -PackageId 'Package_for_RollupFix~~amd64~~26100.8655.1.20'

            True: the same package, spelled the two ways the two tools spell it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Installed,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $PackageId
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($PackageId)) {
        return $false
    }

    # NAME~PUBLISHERKEY~ARCH~LANGUAGE~VERSION. Index 1 is the publisher key and
    # is the field the two spellings disagree about, so it is dropped from both
    # sides rather than defended against.
    $strip = {
        param([string] $Identity)

        $field = @($Identity -split '~')

        if ($field.Count -lt 2) { return $Identity.Trim() }

        $kept = @($field[0])
        $kept += @($field[2..($field.Count - 1)])

        return ((@($kept) -join '~').Trim())
    }

    return ((& $strip $Installed) -eq (& $strip $PackageId))
}

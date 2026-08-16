function Resolve-HDTDiskLayoutName {
    <#
        .SYNOPSIS
            Decides which named disk layout a machine gets.

        .DESCRIPTION
            DESIGN 9.1: "the engine selects a layout by firmware unless the
            sequence pins one". Precedence, highest first:

              1  the step's layout: property   (-Layout)
              2  the HDTDiskLayout variable
              3  firmware - HDTIsUEFI true means uefi-standard

            A MACHINE WHOSE FIRMWARE WAS NEVER GATHERED IS NOT A UEFI MACHINE BY
            DEFAULT. An absent HDTIsUEFI resolves to bios-standard and WARNS,
            rather than assuming the modern answer: an MBR disk on UEFI hardware
            fails to boot loudly and immediately, while a GPT disk on a BIOS
            machine fails after the image has been applied, which costs the whole
            deployment instead of the first minute of it.

            HDTIsUEFI is read as a boolean OR as text, because the variable
            dictionary carries whatever the rules produced and a rules.yaml value
            arrives as a string.

            The pinned name is %Var%-expanded first, so a sequence may write
            layout: "%HDTDiskLayout%". A token that resolves to nothing leaves
            the name unusable, and the resolver falls through to the next source
            rather than failing on a value the author never meant to pin.

            A name no layout defines is a terminating HDTConfigurationError
            listing the names that exist - and the name it returns is the
            layout's own casing, so callers may compare it exactly.

        .PARAMETER Variable
            The resolved variable scope. Read for HDTDiskLayout and HDTIsUEFI,
            and used to expand a %Var% in -Layout.

        .PARAMETER Layout
            The name the step pinned, if any. May contain %Var% tokens.

        .PARAMETER Definition
            Extra layout definitions, passed straight through to
            Get-HDTDiskLayout so a workspace-supplied layout is a legal pin.

        .OUTPUTS
            System.String - a layout name Get-HDTDiskLayout accepts.

        .EXAMPLE
            Resolve-HDTDiskLayoutName -Variable $scope

            The unattended case: firmware decides.

        .EXAMPLE
            Resolve-HDTDiskLayoutName -Variable $scope -Layout '%HDTDiskLayout%'

            The authored case, as the sample sequence pins it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Layout,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Definition
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $known = @(Get-HDTDiskLayout -Definition $Definition)
    $knownName = @($known | ForEach-Object { $_.Name })

    # A hashtable literal is case-SENSITIVE on its keys, and a variable scope is
    # not, so every lookup goes through one case-insensitive walk.
    $lookup = {
        param($Name)

        foreach ($key in @($Variable.Keys)) {
            if ([string] $key -eq $Name) { return $Variable[$key] }
        }

        return $null
    }

    $requested = ''

    if (-not [string]::IsNullOrWhiteSpace($Layout)) {
        $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($Variable.Keys)) { $scope[[string] $key] = $Variable[$key] }

        $expanded = Expand-HDTVariableToken -Value $Layout -Scope $scope

        # A token that resolved to nothing is left literally, so an unexpanded
        # per cent means the author pinned something this machine does not have.
        if ($expanded -notmatch '%') {
            $requested = $expanded
        }
    }

    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [string] (& $lookup 'HDTDiskLayout')
    }

    if (-not [string]::IsNullOrWhiteSpace($requested)) {
        foreach ($name in $knownName) {
            if ($name -eq $requested) { return $name }
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $requested `
                    -Message ("'{0}' is not a disk layout this engine knows. The layouts are {1}." -f $requested, ($knownName -join ', '))))
    }

    $firmware = & $lookup 'HDTIsUEFI'

    if ($null -eq $firmware) {
        Write-Warning 'HDTIsUEFI was not gathered for this machine, so the bios-standard disk layout was assumed. Set HDTIsUEFI, or pin a layout on the step, rather than relying on this.'
        return 'bios-standard'
    }

    $isUefi = $false
    if ($firmware -is [bool]) {
        $isUefi = [bool] $firmware
    } else {
        # A rules.yaml value arrives as text, so 'True' and 'true' both count and
        # anything else - including 'False' and '0' - does not.
        $isUefi = ([string] $firmware).Trim() -eq 'True'
    }

    if ($isUefi) { return 'uefi-standard' }

    return 'bios-standard'
}

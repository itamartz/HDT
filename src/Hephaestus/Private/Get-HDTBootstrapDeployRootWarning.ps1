function Get-HDTBootstrapDeployRootWarning {
    <#
        .SYNOPSIS
            Says when a bootstrap rule sends machines to a share the workspace no
            longer claims.

        .DESCRIPTION
            THE SHARE'S ADDRESS LIVES IN TWO FILES AND NOTHING COMPARED THEM.
            workspace.yaml carries deployRoot; bootstrap-rules.yaml carries
            HDTDeployRoot per rule and OVERRIDES it, because it is read in WinPE
            before the share is reachable and may match on gateway, MAC or model.
            That is MDT's Bootstrap.ini and it is the right design.

            IT COST AN AFTERNOON. The lab's DHCP lease moved, deployRoot was
            corrected to the new address, the boot image was rebuilt - and every
            machine still went looking for the old one, because both bootstrap
            rules still named it. Nothing on any screen, in any step or in any
            test said the two disagreed. The Welcome screen even showed the
            CORRECTED address in its box, which made the stale rule invisible:
            the box is filled from the workspace, and the rule is what the
            connection attempt actually used.

            A DIFFERENCE IS NOT AN ERROR AND MUST NOT REFUSE THE BUILD. Pointing
            some machines at another server is exactly what these rules are for -
            a second site, a replica, a test share. What is worth saying is that
            it IS different, so a stale one is seen while the image is being
            made rather than at a bench.

            IT COMPARES WHAT WAS WRITTEN, not what it resolves to. A rule whose
            share is a %Variable% names no server this can check, and one that
            differs only in case or a trailing slash is the same share said
            differently - neither is worth a warning nobody can act on.

        .PARAMETER DeployRoot
            The workspace's own deployRoot.

        .PARAMETER Rule
            The rules Import-HDTBootstrapRuleDocument returned.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - one warning per rule that disagrees, empty when
            they agree or when there is nothing to compare.

        .EXAMPLE
            Get-HDTBootstrapDeployRootWarning -DeployRoot '\\host\share' -Rule $document.Rule
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $DeployRoot,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Rule
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $found = New-Object -TypeName System.Collections.ArrayList

    # NOTHING TO COMPARE AGAINST. An image built to ask for its share has no
    # opinion for a rule to disagree with.
    if ([string]::IsNullOrWhiteSpace($DeployRoot)) { return [string[]] @() }

    $tidy = {
        param([string] $Value)

        return ([string] $Value).Trim().TrimEnd('\')
    }

    $wanted = & $tidy $DeployRoot

    foreach ($one in @($Rule)) {
        if ($null -eq $one) { continue }
        if ($null -eq $one.PSObject.Properties['Set']) { continue }

        $set = $one.Set
        if ($null -eq $set) { continue }

        $named = ''

        # A RULE'S set: IS A DICTIONARY OR AN OBJECT depending on the reader, and
        # this is handed whatever the importer produced.
        if ($set -is [System.Collections.IDictionary]) {
            if ($set.Contains('HDTDeployRoot')) { $named = [string] $set['HDTDeployRoot'] }
        } elseif ($null -ne $set.PSObject.Properties['HDTDeployRoot']) {
            $named = [string] $set.HDTDeployRoot
        }

        if ([string]::IsNullOrWhiteSpace($named)) { continue }

        # A SHARE PICKED AT RUN TIME NAMES NO SERVER THIS CAN CHECK.
        if ($named -like '*%*') { continue }

        if ((& $tidy $named) -eq $wanted) { continue }

        $ruleName = '(unnamed)'
        if ($null -ne $one.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string] $one.Name)) {
            $ruleName = [string] $one.Name
        }

        [void] $found.Add(
            ("bootstrap rule '{0}' sends machines to '{1}', which is not this share's deployRoot '{2}'. That is legitimate for a second site or a replica - but if the share's address has changed, this rule is what a machine will still use." -f
                $ruleName, $named, $DeployRoot))
    }

    return [string[]] @($found)
}

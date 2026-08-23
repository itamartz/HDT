function Get-HDTWizardField {
    <#
        .SYNOPSIS
            Works out what every box on the Welcome screen should say, without a
            window.

        .DESCRIPTION
            W2 of the WPF-first direction, and the
            reason it is a command rather than code inside the window host.

            NEW-HDTWIZARDHOST'S TDD EXEMPTION IS CONDITIONAL. HDT exempts a
            thin adapter over an external tool - here WPF itself - and
            the price of that exemption is that the adapter must stay
            BRANCH-FREE, "because it is not unit tested". The host had stopped
            paying it: it read the network, decided which named boxes were
            present, decided what belonged in each, and swallowed every failure.
            The first time it was ever really executed, it crashed. That is the
            exemption being charged in the one place nobody can see it - on a
            bench, in WinPE, with a technician watching.

            So the decisions are here, where Pester can reach them with no
            display and no boot image, and the host is plumbing again: load the
            markup, apply this list by name, wire the buttons, show it. That is
            also what WPF-FIRST asked for in the first place - "the command
            holds the logic and is callable without the window".

            A FIELD IS A CONTROL NAME AND THE TEXT THAT GOES IN IT, nothing
            more. The host does not interpret them; it calls FindName and sets
            Text. A field naming a control the window does not have is a box
            that silently stays empty in WinPE, so the names are asserted
            against the shipped XAML in
            tests/unit/Get-HDTWizardField.Tests.ps1.

            THE PASSWORD IS NEVER A FIELD, and that is a rule rather than an
            omission. bootstrap.json can carry a credential and this command can
            see it; a prefilled PasswordBox would put the share password on a
            screen in a room where somebody is deploying a machine. MDT never
            prefills it either.

            BLANK DOMAIN MEANS LOCAL, so a domain that IS the server is shown as
            blank. Get-HDTWizardCredential composes the two back into
            SERVER\user, so the round trip is identical either way - but the
            page's own hint says "leave blank if the account is local to the
            server", and prefilling the server name there teaches the technician
            the opposite of what the hint says.

            NOTHING HERE IS A PRECONDITION. A machine whose network read failed,
            an image with no embedded credential, a boot with no bootstrap
            document at all - each simply produces fewer fields. The Welcome
            screen must open on the machine that is having the problem.

        .PARAMETER NetworkConfiguration
            What Get-HDTNetworkConfiguration returned. Omitted, the address
            boxes are left alone.

        .PARAMETER Bootstrap
            What Get-HDTBootstrapConfiguration returned. Omitted, the share and
            account boxes are left alone.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Name and Text.

        .EXAMPLE
            $bootstrap = Get-HDTBootstrapConfiguration -Path 'X:\HDT\bootstrap.json'
            $network = Get-HDTNetworkConfiguration
            Get-HDTWizardField -NetworkConfiguration (Get-HDTNetworkConfiguration)

            The address boxes, filled from the lease the machine actually got.

        .EXAMPLE
            $field = Get-HDTWizardField -NetworkConfiguration $network -Bootstrap $bootstrap
            foreach ($current in $field) { $window.FindName($current.Name).Text = $current.Text }

            What the host does with the result, and all it does with it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $NetworkConfiguration,

        [Parameter()]
        [AllowNull()]
        [object] $Bootstrap
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $field = @()

    # A property read that tolerates an object which simply does not have it.
    # These come from two different readers and from a boot that may have
    # neither, so "the machine did not tell us" is an ordinary answer here.
    $textOf = {
        param([object] $Source, [string] $Name)

        if ($null -eq $Source) { return '' }
        if ($null -eq $Source.PSObject.Properties[$Name]) { return '' }

        return [string] $Source.$Name
    }

    # NAME, VALUE, AND WHICH PROPERTY IT GOES IN. Text for a TextBox and
    # Password for a PasswordBox - the same pair wizard.yaml's collect
    # declarations use, and the same pair Get-HDTWizardHarvest reads back with.
    # A host that worked the property out from the control's type would be
    # deciding something, which is what an untested adapter may not do.
    $add = {
        param([string] $Name, [string] $Text, [string] $Property = 'Text')

        return [pscustomobject] @{
            Name     = $Name
            Text     = $Text
            Property = $Property
        }
    }

    # -- 1. the lease, shown rather than guessed ----------------------------

    if ($null -ne $NetworkConfiguration) {
        $field += & $add 'HDTIpAddressBox' (& $textOf $NetworkConfiguration 'IPAddress')
        $field += & $add 'HDTSubnetMaskBox' (& $textOf $NetworkConfiguration 'SubnetMask')
        $field += & $add 'HDTGatewayBox' (& $textOf $NetworkConfiguration 'Gateway')
        $field += & $add 'HDTDnsBox' (& $textOf $NetworkConfiguration 'DnsServerText')
    }

    # -- 2. what the image it booted already knows --------------------------

    if ($null -ne $Bootstrap) {
        $deployRoot = & $textOf $Bootstrap 'DeployRoot'
        $field += & $add 'HDTDeployRootBox' $deployRoot

        $userName = & $textOf $Bootstrap 'UserName'
        $userId = $userName
        $userDomain = ''

        if ($userName.Contains('\')) {
            $part = @($userName.Split('\'))
            $userDomain = [string] $part[0]
            $userId = [string] $part[$part.Count - 1]
        }

        # BLANK MEANS LOCAL. See the header: the domain box shows a domain only
        # when it is not simply the server the share lives on.
        $server = ''
        if ($deployRoot.StartsWith('\\')) {
            $segment = @($deployRoot.TrimStart('\').Split('\') | Where-Object { $_ })
            if ($segment.Count -ge 1) { $server = [string] $segment[0] }
        }

        if ($userDomain -eq $server) { $userDomain = '' }

        $field += & $add 'HDTUserIdBox' $userId
        $field += & $add 'HDTUserDomainBox' $userDomain
    }

    # -- 3. the password, which IS prefilled -------------------------------
    #
    # AN EARLIER VERSION REFUSED TO, and the reasoning was that a prefilled
    # PasswordBox puts the share password on a screen in a room where somebody
    # is deploying a machine. Two facts overturned it:
    #
    #   IT IS ALREADY IN THE IMAGE. bootstrap.json inside the boot media
    #   carries this credential; anybody holding the media has the password
    #   already, which is exactly why DESIGN 6.3 says to treat boot media as a
    #   credential. Withholding it from the screen protects nothing.
    #
    #   A PasswordBox SHOWS DOTS. It is masked unless the technician presses the
    #   eye - so it is not on screen in any readable sense until somebody
    #   deliberately asks for it.
    #
    #   AND THE SCREEN IS SHOWN WHEN THE SHARE CANNOT BE REACHED, which is
    #   precisely the moment a technician needs to try the same account against
    #   a corrected UNC. Making them retype a password they cannot see written
    #   down anywhere is how that attempt fails for a second, unrelated reason.

    if ($null -ne $Bootstrap -and $null -ne $Bootstrap.PSObject.Members['GetCredential']) {
        $secret = ''

        try {
            $credential = $Bootstrap.GetCredential()
            if ($null -ne $credential) {
                $secret = [string] $credential.GetNetworkCredential().Password
            }
        } catch {
            # An image built with no embedded credential answers nothing here,
            # and that is an ordinary boot rather than a failure.
            $secret = ''
        }

        if (-not [string]::IsNullOrEmpty($secret)) {
            $field += & $add 'HDTPasswordBox' $secret 'Password'
        }
    }


    return $field
}

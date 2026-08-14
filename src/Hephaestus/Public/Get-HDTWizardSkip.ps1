function Get-HDTWizardSkip {
    <#
        .SYNOPSIS
            Resolves MDT's Skip* properties for the Welcome screen, from the
            boot image.

        .DESCRIPTION
            W2 of the WPF-first direction (.planning/WPF-FIRST.md), and MDT's
            Skip* mechanism under the HDT prefix so an MDT admin recognises it
            instantly:

              HDTSkipWelcome     the Welcome screen entirely
              HDTSkipStaticIp    the network pane; DHCP is used
              HDTSkipDeployRoot  the share box; bootstrap.json's value is used
              HDTSkipCredential  the account pane; the embedded credential wins

            THEY COME FROM bootstrap.json AND NOT FROM rules.yaml, and that is a
            CORRECTION to WPF-FIRST recorded in the document itself. rules.yaml
            lives ON THE SHARE, and the Welcome screen is what makes the share
            reachable - configuring the network and collecting the credential is
            its whole job. A HDTSkipWelcome on the share is a rule the machine
            cannot read until after the screen it was meant to skip has already
            been shown.

            MDT HAS THE SAME SPLIT FOR THE SAME REASON. SkipBDDWelcome is in
            Bootstrap.ini, which is inside the boot image; every other Skip*
            property is in CustomSettings.ini, on the share. The later panes -
            task sequence, computer name, summary - run after connecting and do
            resolve through the ordinary rules engine.

            THE DEFAULT IS SKIPPED, AND IT IS THE MOST IMPORTANT LINE HERE.
            WPF-FIRST: "THE UNATTENDED PATH IS THE DEFAULT, NOT THE EXCEPTION."
            A wizard that appeared by default would make every image already
            built start waiting for a human who is not there, and the E2E suite
            that proves zero-keystroke deployment would be proving something
            else. So an unset welcome rule means SKIPPED unless something
            genuinely has to be asked.

            THE ONLY THING DECIDABLE BEFORE THE SHARE IS REACHABLE is whether
            the image can authenticate at all, and DESIGN 6.3 already settled
            how that is spelled: promptForCredential. An image that carries a
            working credential asks nothing and shows nothing; an image built
            with -PromptForCredential is the one that stops for a person.

            AN EXPLICIT RULE ALWAYS WINS over any of that. A site that wants the
            screen on an image that could have skipped it sets welcome to false,
            and gets it.

            A BOOT WITH NO BOOTSTRAP DOCUMENT SKIPS. Failing towards the
            unattended path is the safe direction: the deployment either
            proceeds or fails loudly, rather than sitting on a screen in a room
            nobody is in.

        .PARAMETER Bootstrap
            What Get-HDTBootstrapConfiguration returned. Null is not an error.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Welcome, StaticIp,
            DeployRoot, Credential (all booleans - true means SKIP), Pane
            (Name/Visible for each pane control) and Source (Rule/Value/Source
            provenance for each rule).

        .EXAMPLE
            $skip = Get-HDTWizardSkip -Bootstrap (Get-HDTBootstrapConfiguration -Path 'X:\HDT\bootstrap.json')
            if (-not $skip.Welcome) { Show-HDTWizard -XamlPath $p -Pane $skip.Pane }

            The whole contract: ask first, and show only what is left to ask.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $Bootstrap
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A skip key that is absent, or present and null, means THE IMAGE SAID
    # NOTHING - which is a different fact from false and is what the defaults
    # below are for. Every image built before this existed is in that state.
    $stated = {
        param([string] $Name)

        if ($null -eq $Bootstrap) { return $null }
        if ($null -eq $Bootstrap.PSObject.Properties['Skip']) { return $null }
        if ($null -eq $Bootstrap.Skip) { return $null }
        if ($null -eq $Bootstrap.Skip.PSObject.Properties[$Name]) { return $null }
        if ($null -eq $Bootstrap.Skip.$Name) { return $null }

        return [bool] $Bootstrap.Skip.$Name
    }

    $prompt = $false
    if ($null -ne $Bootstrap -and $null -ne $Bootstrap.PSObject.Properties['PromptForCredential']) {
        $prompt = [bool] $Bootstrap.PromptForCredential
    }

    # THE DEFAULTS, and each one is an argument rather than a preference:
    #
    #   welcome     skipped unless the image cannot authenticate unaided. See
    #               the header - this is what keeps every existing image
    #               unattended.
    #   staticIp    shown. A machine whose network is wrong is the commonest
    #               reason a technician is looking at this screen at all.
    #   deployRoot  shown, prefilled. Inferring it away is fine right up until
    #               the prefilled share is the unreachable one.
    #   credential  skipped when the image already carries one, because then the
    #               pane has nothing to ask and an empty password box reads as
    #               an instruction to fill it in.
    $rule = @(
        @{ Name = 'Welcome'; Rule = 'HDTSkipWelcome'; Default = (-not $prompt) }
        @{ Name = 'StaticIp'; Rule = 'HDTSkipStaticIp'; Default = $false }
        @{ Name = 'DeployRoot'; Rule = 'HDTSkipDeployRoot'; Default = $false }
        @{ Name = 'Credential'; Rule = 'HDTSkipCredential'; Default = (-not $prompt) }
    )

    $result = [ordered] @{
        Welcome    = $true
        StaticIp   = $false
        DeployRoot = $false
        Credential = $true
        Pane       = @()
        Source     = @()
    }

    foreach ($current in $rule) {
        $name = [string] $current.Name

        $value = & $stated $name
        $source = 'bootstrap.json'

        if ($null -eq $value) {
            $value = [bool] $current.Default
            $source = 'default'
        }

        $result[$name] = [bool] $value

        $result['Source'] += [pscustomobject] @{
            Rule   = [string] $current.Rule
            Value  = [bool] $value
            Source = $source
        }
    }

    # THE PANE CONTROLS THE HOST COLLAPSES, by name. Visible is the inverse of
    # skipped, so the host never has to reason about the word "skip" - it sets
    # visibility and nothing else.
    foreach ($pane in @(
            @{ Name = 'HDTNetworkPane'; Skipped = $result['StaticIp'] }
            @{ Name = 'HDTDeployRootPane'; Skipped = $result['DeployRoot'] }
            @{ Name = 'HDTCredentialPane'; Skipped = $result['Credential'] })) {

        $result['Pane'] += [pscustomobject] @{
            Name    = [string] $pane.Name
            Visible = (-not [bool] $pane.Skipped)
        }
    }

    return [pscustomobject] $result
}

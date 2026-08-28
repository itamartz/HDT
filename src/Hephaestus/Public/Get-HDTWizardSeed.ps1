function Get-HDTWizardSeed {
    <#
        .SYNOPSIS
            What the rules already answered, put in the boxes before the
            technician types.

        .DESCRIPTION
            EVERY BOX A RULE CAN ANSWER COMES UP ANSWERED. Before this, a box
            held whatever the MARKUP said: HDTJoinWorkgroupBox carried
            Text="WORKGROUP" as a literal and everything else came up empty, so
            a share whose rules.yaml had already answered a question still
            showed a blank box asking it again. Only the computer name was
            seeded, by its own command. (MDT prefills its panes from
            CustomSettings.ini the same way.)

            THE REASON IT WAITED IS REAL, NOT AN OVERSIGHT, AND THE OTHER HALF
            OF THE FIX IS IN THE HARVEST. Every value the wizard collects
            re-enters the engine as the Wizard source - the HIGHEST precedence
            in DESIGN 3.1 - so a box seeded from a rule and never touched would
            be collected as though somebody had typed it. The deployment would
            be right and the provenance would LIE: the report would say a name
            was typed at the bench when a rule on the share produced it, which
            is the one question provenance exists to answer.

            So New-HDTWizardHost remembers what it seeded and drops a value that
            comes back unchanged. The rule stands, with its own provenance;
            change the box and the answer is yours, recorded as Wizard, which is
            then true.

            THE PAGE'S OWN collect LIST DECIDES WHAT GETS SEEDED. A page already
            declares which control fills which variable; this reads the same
            declaration backwards. Nothing new to author, and nothing that can
            drift out of step with the markup.

            A LIST OF TICKS IS NOT SEEDED HERE. `select: many` is the
            Applications page, whose rows AND ticks both come from
            Get-HDTWizardApplication - it reads the catalog, so it is the only
            thing that can know which rows exist to tick. A seed writing a
            joined string into that control would fight it and lose.

            AN UNANSWERED VARIABLE LEAVES AN EMPTY BOX, which is the honest
            screen: nothing knows the value, so nothing is shown.

            EACH CONTROL ONCE, first declaration wins. ComputerDetail's account
            box fills HDTDomainAdmin and, through the split,
            HDTDomainAdminDomain; two seeds for one control would have the
            second overwrite the first, and which won would depend on the order
            the page happened to list them in.

        .PARAMETER Page
            The pages, as Import-HDTWizardDocument projects them. All of them:
            Show-HDTWizardShell applies fields once and every page swap
            re-applies the same set.

        .PARAMETER Variable
            The resolved variables. Null is treated as empty - the payload calls
            this on a share it may have only just reached, and neither absence
            is a reason to lose the screen.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per control, with Name,
            Property, Text and Seed - the same field shape Get-HDTWizardField,
            Get-HDTWizardSequence and Get-HDTWizardComputerName produce. Seed is
            always true here: every value came out of the resolved variables,
            which is what the host has to be told before it will remember one.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'Z:\Deploy'
            $ask = Import-HDTWizardDocument -Provider $provider
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            Get-HDTWizardSeed -Page $ask.Page -Variable $resolved.Variable

            One field per box the rules can already fill in.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'Z:\Deploy'
            $ask = Import-HDTWizardDocument -Provider $provider
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            $seed = Get-HDTWizardSeed -Page $ask.Page -Variable $resolved.Variable
            Show-HDTWizardShell -Page $ask.Page -Field @($seed)

            What the payload does: the seed is one more set of fields, applied
            by name like every other.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Page,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $field = New-Object -TypeName System.Collections.ArrayList

    if ($null -eq $Variable) { return [pscustomobject[]] @() }

    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($current in @($Page)) {

        if ($null -eq $current) { continue }
        if ($null -eq $current.PSObject.Properties['Collect']) { continue }

        foreach ($declaration in @($current.Collect)) {

            if ($null -eq $declaration) { continue }
            if ($null -eq $declaration.PSObject.Properties['Control']) { continue }
            if ($null -eq $declaration.PSObject.Properties['Variable']) { continue }

            $control = ([string] $declaration.Control).Trim()
            $name = ([string] $declaration.Variable).Trim()

            if ([string]::IsNullOrWhiteSpace($control)) { continue }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            # SEE THE HEADER: the catalog command owns that control entirely.
            if ($null -ne $declaration.PSObject.Properties['Select'] -and
                ([string] $declaration.Select) -eq 'many') { continue }

            if (-not $Variable.Contains($name)) { continue }

            $value = [string] $Variable[$name]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }

            if (-not $seen.Add($control)) { continue }

            $property = 'Text'
            if ($null -ne $declaration.PSObject.Properties['Property'] -and
                -not [string]::IsNullOrWhiteSpace([string] $declaration.Property)) {

                $property = [string] $declaration.Property
            }

            # EVERY FIELD THIS COMMAND EMITS IS A REAL SEED, BY CONSTRUCTION:
            # the value came out of the resolved variables and nothing here
            # invents one. New-HDTWizardHost believes no field that does not say
            # this, because a value the WIZARD chose for itself carries no
            # provenance to protect and dropping it on the way out is how a
            # technician's accepted answer disappears.
            [void] $field.Add([pscustomobject] @{
                    Name     = $control
                    Property = $property
                    Text     = $value
                    Seed     = $true
                })
        }
    }

    return [pscustomobject[]] @($field)
}

function Get-HDTWizardPage {
    <#
        .SYNOPSIS
            Works out which wizard pages this deployment still has to ask.

        .DESCRIPTION
            DESIGN 11.2'S SKIP MODEL, MADE REAL. The keys existed and nothing
            read them: HDTSkipWizard appeared only in the variable name map and
            error text, and HDTSkipTaskSequence, HDTSkipComputerName and
            HDTSkipSummary appeared nowhere in the engine at all. Only the
            Welcome screen was skippable, from bootstrap.json. An administrator
            could be told exactly what to set, set it, and watch the wizard
            appear anyway.

            THE SKIP VARIABLE DECIDES, NOT THE PRESENCE OF A VALUE. Setting
            HDTComputerName does not hide the Computer Details page;
            HDTSkipComputerName does, and it matters because a prefilled page a
            technician CONFIRMS is a real workflow. A page that vanished as soon
            as a rule guessed a name would take that away, and a guessed name is
            precisely the one worth confirming: SPIKES S9.11's machine was named
            by a rule nobody checked. (MDT decides the same way, from
            SkipComputerName.)

            A SKIPPED PAGE WHOSE VALUE IS MISSING IS AN ERROR, NOT A PROMPT.
            DESIGN 11.2, in those words. Showing it anyway produces a deployment
            nobody can reproduce, and inventing a value produces a machine
            nobody named. The refusal names both the variable that should have
            been set and the rule that skipped the page, because an
            administrator who set one and forgot the other cannot tell which
            from a message that names neither.

            HDTSkipWizard IS THE BLUNT ONE and is checked the same way, which is
            why it is also the commonest way to get the refusal above: it skips
            pages an administrator may not have realised collected anything.

            TRUTH IS READ LOOSELY, ON PURPOSE. rules.yaml gives a real boolean;
            a command line, a machine override or a hand-edited file can give
            'true', 'YES' or '1'. A skip that silently failed to apply because
            it arrived as text is a wizard appearing on a machine nobody is
            standing at.

        .PARAMETER Page
            The catalogue - every page this wizard could ask, in order. Each
            carries Id, Title, the Skip variable that hides it, and optionally
            Collect naming the variable it fills.

        .PARAMETER Variable
            The resolved variables, from Resolve-HDTVariable.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Page (what to ask,
            in order), Skipped (Id and the Rule that did it) and
            IsWizardNeeded.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'C:\HDTLab\Share'
            $wizard = Import-HDTWizardDocument -Provider $provider
            $ask = Get-HDTWizardPage -Page $wizard.Page -Variable ([ordered] @{})

            Which pages a technician still has to be asked, given what the rules
            already resolved. A page whose every field is answered is not a page.

        .EXAMPLE
            if (@($ask.Page).Count -gt 0) { @($ask.Page | ForEach-Object { $_.Title }) } else { 'nothing to ask' }

            The whole contract: decide first, and open nothing if there is nothing left
            to ask. A wizard that appears to confirm what a rule already decided is
            a wizard somebody clicks through without reading.

    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Page,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Variable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (@($Page).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message 'there are no wizard pages in the catalogue, so there is nothing to decide about.'))
    }

    $resolved = $Variable
    if ($null -eq $resolved) { $resolved = @{} }

    # See the header: text and booleans both arrive here, and a skip that
    # silently did not apply is a wizard nobody is there to answer.
    $isTrue = {
        param([string] $Name)

        if (-not $resolved.ContainsKey($Name)) { return $false }

        $value = $resolved[$Name]
        if ($null -eq $value) { return $false }
        if ($value -is [bool]) { return [bool] $value }

        return (@('true', 'yes', '1', 'on') -contains ([string] $value).Trim().ToLowerInvariant())
    }

    $skipAll = & $isTrue 'HDTSkipWizard'

    $ask = @()
    $skipped = @()

    foreach ($current in @($Page)) {

        $rule = ''
        if ($null -ne $current.PSObject.Properties['Skip']) { $rule = [string] $current.Skip }

        $isSkipped = $skipAll
        $by = 'HDTSkipWizard'

        if (-not $isSkipped -and -not [string]::IsNullOrWhiteSpace($rule) -and (& $isTrue $rule)) {
            $isSkipped = $true
            $by = $rule
        }

        if (-not $isSkipped) {
            $ask += $current
            continue
        }

        # THE REFUSAL. A page that is not going to be asked must already have
        # the answer it would have collected.
        $collect = $null
        if ($null -ne $current.PSObject.Properties['Collect']) { $collect = $current.Collect }

        # EVERY VARIABLE THE PAGE WOULD HAVE COLLECTED, not just the first. A
        # Computer Details page skipped with a name but no workgroup is the same
        # failure as one skipped with no name at all.
        #
        # A SECRET IS EXEMPT. HDTDomainAdminPassword is deliberately not written
        # into rules.yaml - the summary refuses to print it there - so demanding
        # it from the resolved variables would make the one page that handles a
        # password impossible to skip.
        foreach ($declaration in @($collect)) {
            if ($null -eq $declaration) { continue }

            $isSecret = $false
            if ($null -ne $declaration.PSObject.Properties['IsSecret']) { $isSecret = [bool] $declaration.IsSecret }
            if ($isSecret) { continue }

            # AND A PAGE WITH TWO MUTUALLY EXCLUSIVE HALVES DOES NOT DEMAND
            # BOTH. MDT's Computer Details pane offers a domain OR a workgroup,
            # and SkipDomainMembership needs whichever one the machine is
            # actually getting; demanding every variable meant a workgroup
            # machine could not skip the page without being handed a domain
            # name, an OU and a join account it would never use. The first real
            # zero-touch deployment in this lab failed on exactly that.
            #
            # THE DOCUMENT SAYS WHICH, because only the document knows. Working
            # it out here - "domain things do not matter when a workgroup is
            # set" - would be the engine guessing at the meaning of somebody
            # else's page, and a third-party page would get no such courtesy.
            $isOptional = $false
            if ($null -ne $declaration.PSObject.Properties['Optional']) { $isOptional = [bool] $declaration.Optional }
            if ($isOptional) { continue }

            $name = [string] $declaration.Variable

            $supplied = $false
            if ($resolved.ContainsKey($name)) {
                $supplied = -not [string]::IsNullOrWhiteSpace([string] $resolved[$name])
            }

            if (-not $supplied) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTConfigurationError' -Category InvalidData `
                            -Message ('the wizard page ''{0}'' is skipped by {1}, but nothing supplies {2}. A skipped page whose value is still missing is an error rather than a prompt (DESIGN 11.2) - set {2} in rules.yaml, or in Control\machines\<UUID>.yaml for this machine, or stop skipping the page.' -f
                                [string] $current.Id, $by, $name)))
            }
        }

        $skipped += [pscustomobject] @{
            Id    = [string] $current.Id
            Title = [string] $current.Title
            Rule  = $by
        }
    }

    return [pscustomobject] @{
        Page           = $ask
        Skipped        = $skipped
        IsWizardNeeded = (@($ask).Count -gt 0)
    }
}

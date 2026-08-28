function Invoke-HDTTattooStep {
    <#
        .SYNOPSIS
            Stamps the deployed machine with what built it.

        .DESCRIPTION
            WRITES WHAT BUILT THE MACHINE ONTO THE MACHINE, at the end of the
            deployment. Six months after a deployment somebody is standing in
            front of the machine asking which task sequence made it, from which
            share, and when. The deployment log answers all three - but it is on
            a share, in a folder named after a computer that may since have been
            renamed, and the person asking is looking at the machine rather than
            at the share. So the answer is written onto the machine, once, at
            the end:

              - name: Tattoo
                type: Tattoo

            EVERYTHING IT WRITES IS ALREADY RESOLVED, which is why the step takes
            no arguments. HDTTaskSequenceName and HDTTaskSequenceVersion are
            published by the engine when the sequence is imported - PSDTattoo.ps1
            has to go back to the deployment share and search it for those two -
            and New-HDTExecutionContext refreshes HDTDeploymentEnd before every
            step precisely so that the last step can subtract HDTDeploymentStart
            from it.

            IT WRITES TO HKLM:\SOFTWARE\Hephaestus\Deployment, AND NOT TO
            HKLM\SOFTWARE\Microsoft\Deployment 4, which is where MDT stamps its
            own. Writing there would make HDT claim to be an MDT installation to
            every inventory query that reads it, and a machine that has been
            through both must be readable as both.

            A VALUE THAT NEVER RESOLVED IS WRITTEN EMPTY, NOT SKIPPED. A key
            missing TaskSequenceVersion reads as "the tattoo did not run"; a
            TaskSequenceVersion of '' reads as "the sequence declares no
            version", which is the truth and a different fact. The empties are
            named in one warning so the authoring mistake behind them is visible
            in the log.

            A SITE MAY ADD ITS OWN with a values: mapping, expanded against the
            live variables like every other authored string. An extra that
            collides with a standard name overrides it and says so: a silent
            substitution would make the tattoo lie about which sequence ran.

            IT WRITES THROUGH IRegistryService (rule 5), so the whole step runs
            under Pester against the hand-written fake. A registry that refuses
            it is a FAILED step and not a throw: the machine is otherwise
            deployed, and the loop is what decides what a failed step means.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Optional
            properties: path, and a values mapping.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Tattoo' })[0]

            Invoke-HDTTattooStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTTattooStep -Step $step -Context $context
            $result.Data.Path

            The registry key it stamped, which is where a technician looks six months
            later to find out what built the machine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $Context.Service.GetRequired('Registry', 'Tattoo')
    $property = $Step.Property

    # A variable that was never resolved reads as an empty string rather than
    # throwing under StrictMode, which is the whole distinction this step draws
    # between "no value" and "no tattoo".
    $valueOf = {
        param([string] $Name)

        if ($null -eq $Context.Variable) { return '' }
        if (-not $Context.Variable.Contains($Name)) { return '' }

        return [string] $Context.Variable[$Name]
    }

    # -- where ---------------------------------------------------------------

    $path = 'HKLM:\SOFTWARE\Hephaestus\Deployment'

    if ($null -ne $property -and $property.Contains('path') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['path'])) {

        $path = Expand-HDTVariableToken -Value ([string] $property['path']) -Scope $Context.Variable
    }

    # -- what ----------------------------------------------------------------

    # THE ORDER IS THE ORDER IT IS READ IN, which is why this is an ordered
    # dictionary and not a hashtable: regedit sorts alphabetically, but the log
    # record below carries this shape verbatim and a technician reads it top to
    # bottom - identity, then provenance, then when, then the metal.
    $stamp = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $stamp['ComputerName'] = & $valueOf 'HDTComputerName'
    $stamp['DeployRoot'] = & $valueOf 'HDTDeployRoot'
    $stamp['TaskSequenceID'] = & $valueOf 'HDTTaskSequenceID'
    $stamp['TaskSequenceName'] = & $valueOf 'HDTTaskSequenceName'
    $stamp['TaskSequenceVersion'] = & $valueOf 'HDTTaskSequenceVersion'
    $stamp['DeploymentType'] = & $valueOf 'HDTDeploymentType'
    $stamp['DeploymentStart'] = & $valueOf 'HDTDeploymentStart'
    $stamp['DeploymentEnd'] = & $valueOf 'HDTDeploymentEnd'
    $stamp['DeploymentDuration'] = ''
    $stamp['RunId'] = [string] $Context.RunId

    # _HDTVersion IS THE ENGINE'S OWN, PUBLISHED BY THE CONTEXT. Reaching for
    # Get-Module here would be a second answer to "which engine ran this" for a
    # value the context already sets from Get-HDTModuleVersion.
    $stamp['EngineVersion'] = & $valueOf '_HDTVersion'

    $stamp['Make'] = & $valueOf 'HDTMake'
    $stamp['Model'] = & $valueOf 'HDTModel'
    $stamp['SerialNumber'] = & $valueOf 'HDTSerialNumber'

    # -- how long ------------------------------------------------------------
    #
    # THE SUBTRACTION New-HDTExecutionContext KEEPS HDTDeploymentEnd FRESH FOR.
    # Both ends are ISO 8601 UTC, so they are parsed as round-trip values and
    # not against whatever culture the deployed machine came up in.
    #
    # NOT ToString('hh\:mm\:ss'): hh is hours WITHIN a day, so a deployment that
    # took 26 hours - a slow share and a large image is enough - would tattoo
    # itself as having taken two. TotalHours is the whole count.
    $startTime = [datetime]::MinValue
    $endTime = [datetime]::MinValue

    $haveStart = [datetime]::TryParse([string] $stamp['DeploymentStart'],
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $startTime)

    $haveEnd = [datetime]::TryParse([string] $stamp['DeploymentEnd'],
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $endTime)

    if ($haveStart -and $haveEnd -and $endTime -ge $startTime) {
        $span = $endTime - $startTime

        $stamp['DeploymentDuration'] = '{0:00}:{1:00}:{2:00}' -f
            [int] [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
    }

    # -- and whatever the site adds ------------------------------------------

    $override = New-Object -TypeName System.Collections.ArrayList

    if ($null -ne $property -and $property.Contains('values') -and
        ($property['values'] -is [System.Collections.IDictionary])) {

        foreach ($key in @($property['values'].Keys)) {
            $name = [string] $key

            if ($stamp.Contains($name)) { [void] $override.Add($name) }

            $raw = $property['values'][$key]
            $value = $raw

            if ($raw -is [string]) {
                $value = Expand-HDTVariableToken -Value $raw -Scope $Context.Variable
            }

            $stamp[$name] = [string] $value
        }
    }

    # -- write it ------------------------------------------------------------

    try {
        # THE KEY FIRST. IRegistryService.SetValue fails on a key that does not
        # exist - the real adapter is a thin wrapper over the registry cmdlet
        # that behaves that way, and the fake is deliberately no more forgiving.
        #
        # (The cmdlet is not named here on purpose: tests/contract/StepContract
        # greps these files for direct calls, and it greps the comments too.)
        $registry.NewKey($path)

        foreach ($name in @($stamp.Keys)) {
            # REG_SZ, ALL OF IT. A tattoo is read by people and by inventory
            # tools that expect strings; MDT's is strings and so is PSD's, and a
            # DWORD duration would be the one value nobody could read at a
            # glance.
            $registry.SetValue($path, $name, [string] $stamp[$name], 'String')
        }
    } catch {
        $message = "step '{0}' could not stamp '{1}': {2}" -f $Step.Name, $path, $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Severity Error -Event step.fail -Component 'Tattoo' -Message $message

        return (New-HDTStepResult -Status Failed -Message $message)
    }

    # -- and say what it wrote ------------------------------------------------
    #
    # THE WHOLE STAMP ON ONE RECORD, so the tattoo can be read out of the
    # deployment log without going back to the machine - which is the position a
    # technician is in once the machine is on somebody's desk.
    Write-HDTLog -Context $Context.Log -Component 'Tattoo' `
        -Message ("stamped '{0}' with {1} value(s)." -f $path, @($stamp.Keys).Count) `
        -Data ([ordered] @{ path = $path; value = $stamp })

    $empty = @(@($stamp.Keys) | Where-Object { [string]::IsNullOrEmpty([string] $stamp[$_]) })

    if (@($empty).Count -gt 0) {
        Write-HDTLog -Context $Context.Log -Severity Warning -Component 'Tattoo' `
            -Message ("{0} tattoo value(s) resolved to nothing and are stamped empty: {1}." -f
                @($empty).Count, (@($empty) -join ', ')) `
            -Data ([ordered] @{ path = $path; empty = [string[]] @($empty) })
    }

    if (@($override).Count -gt 0) {
        Write-HDTLog -Context $Context.Log -Severity Warning -Component 'Tattoo' `
            -Message ("the step's values: mapping replaced {0} value(s) the engine had resolved: {1}." -f
                @($override).Count, (@($override) -join ', ')) `
            -Data ([ordered] @{ path = $path; overridden = [string[]] @($override) })
    }

    return (New-HDTStepResult -Status Completed `
            -Message ("stamped '{0}' with {1} value(s)" -f $path, @($stamp.Keys).Count))
}

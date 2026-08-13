function Get-HDTStepType {
    <#
        .SYNOPSIS
            Discovers every step type in the session, by convention.

        .DESCRIPTION
            DESIGN 4.2: "third-party step types can be dropped into Modules\ -
            the engine discovers them by convention, so extending HDT does not
            mean forking it". This is that discovery, and it is the whole
            registry: there is no list of step types anywhere in the engine.

            A step type <Type> is implemented by:

              Invoke-HDT<Type>Step -Step -Context            required
              Test-HDT<Type>StepApplicable -Step -Context    optional, default true
              Get-HDT<Type>StepDescription -Step             optional, default
                                                             '<Type>: <name>'

            It enumerates every function named Invoke-HDT*Step in the session and
            keeps the ones matching ^Invoke-HDT(?<type>[A-Za-z0-9]+)Step$, so a
            module imported out of a workspace's Modules\ contributes without the
            engine knowing it exists. Invoke-HDTStep itself does not match: its
            type part is empty, so the dispatcher never discovers itself.

            NO FUTURE HDT FUNCTION MAY BE NAMED Invoke-HDT*Step unless it is a
            step type. The name is the registry.

            TWO MODULES EXPORTING ONE TYPE IS A TERMINATING ERROR naming both
            sources. PowerShell would otherwise resolve the name to whichever
            module was imported last, and a third party silently shadowing
            ApplyImage is exactly the failure that must not be quiet.

            The registry is sorted by Type, so it is deterministic between runs
            and between engines rather than following whatever order the session
            happens to enumerate functions in.

        .PARAMETER Name
            One or more type names to return. Matched case-insensitively. Omit it
            for the whole registry.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per type:

              Type                the type name, e.g. ApplyImage
              InvokeCommand       the CommandInfo for Invoke-HDT<Type>Step
              TestCommand         the CommandInfo, or $null
              DescriptionCommand  the CommandInfo, or $null
              Source              the module that exported it, or an empty string

        .EXAMPLE
            Get-HDTStepType | Format-Table Type, Source

        .EXAMPLE
            Get-HDTStepType -Name CommandLine
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [string[]] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE ENUMERATION GOES THROUGH Get-Module, NOT Get-Command -All. Verified on
    # this machine: from inside a module's own session state, Get-Command -All
    # returns only the WINNING definition of a shadowed name, so the duplicate
    # this function exists to report would be invisible from exactly where it
    # runs. A module's ExportedFunctions table is per module and cannot be
    # shadowed, so every definition is seen.
    $byName = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $add = {
        param([string] $CommandName, [object] $Command, [string] $Source)

        if (-not $byName.Contains($CommandName)) {
            $byName[$CommandName] = New-Object -TypeName System.Collections.ArrayList
        }

        if (@($byName[$CommandName] | ForEach-Object { $_.Source }) -notcontains $Source) {
            [void] $byName[$CommandName].Add([pscustomobject] @{ Command = $Command; Source = $Source })
        }
    }

    foreach ($module in @(Get-Module)) {
        foreach ($commandName in @($module.ExportedFunctions.Keys)) {
            if (($commandName -notlike 'Invoke-HDT*Step') -and
                ($commandName -notlike 'Test-HDT*StepApplicable') -and
                ($commandName -notlike 'Get-HDT*StepDescription')) {
                continue
            }

            & $add ([string] $commandName) $module.ExportedFunctions[$commandName] ([string] $module.Name)
        }
    }

    # A step type dot-sourced into the session rather than shipped in a module.
    # It has no module name, so it can only be reached this way.
    #
    # -ListImported IS LOAD-BEARING, not tidiness: a wildcard Get-Command without
    # it triggers a scan of every module on every PSModulePath to populate the
    # command-analysis cache, which was observed taking minutes on a cold cache.
    # Discovery runs once per step dispatch when the loop does not pass a
    # registry, so it may not do that.
    foreach ($command in @(Get-Command -CommandType Function -ListImported -ErrorAction SilentlyContinue `
                -Name 'Invoke-HDT*Step', 'Test-HDT*StepApplicable', 'Get-HDT*StepDescription')) {

        if (-not [string]::IsNullOrWhiteSpace([string] $command.ModuleName)) {
            continue
        }

        & $add ([string] $command.Name) $command ''
    }

    $registry = New-Object -TypeName System.Collections.ArrayList

    foreach ($commandName in @($byName.Keys)) {
        $match = [regex]::Match($commandName, '^Invoke-HDT(?<type>[A-Za-z0-9]+)Step$')
        if (-not $match.Success) {
            continue
        }

        $type = $match.Groups['type'].Value
        $entry = @($byName[$commandName])

        if ($entry.Count -gt 1) {
            $where = @($entry | ForEach-Object {
                    if ([string]::IsNullOrWhiteSpace($_.Source)) { '<no module>' } else { $_.Source }
                }) -join ' and '

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("the step type '{0}' is exported by more than one module ({1}). One of them would silently shadow the other, so HDT refuses to guess. Remove one from the workspace Modules directory." -f $type, $where)))
        }

        $source = [string] $entry[0].Source

        # A companion is taken from the SAME source as the Invoke command, so a
        # third party cannot half-override another vendor's step type.
        $test = $null
        $testName = 'Test-HDT{0}StepApplicable' -f $type
        if ($byName.Contains($testName)) {
            $candidate = @($byName[$testName] | Where-Object { $_.Source -eq $source })
            if ($candidate.Count -gt 0) {
                $test = $candidate[0].Command
            }
        }

        $description = $null
        $descriptionName = 'Get-HDT{0}StepDescription' -f $type
        if ($byName.Contains($descriptionName)) {
            $candidate = @($byName[$descriptionName] | Where-Object { $_.Source -eq $source })
            if ($candidate.Count -gt 0) {
                $description = $candidate[0].Command
            }
        }

        [void] $registry.Add([pscustomobject] @{
                Type               = $type
                InvokeCommand      = $entry[0].Command
                TestCommand        = $test
                DescriptionCommand = $description
                Source             = $source
            })
    }

    $result = @($registry | Sort-Object -Property Type)

    if ($PSBoundParameters.ContainsKey('Name') -and $null -ne $Name) {
        $result = @($result | Where-Object { $Name -contains $_.Type })
    }

    return $result
}

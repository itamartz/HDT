function Resolve-HDTApplicationOrder {
    <#
        .SYNOPSIS
            Turns an application catalog and a selection into the ordered install
            plan.

        .DESCRIPTION
            DESIGN 8's "both resolve to the same ordered install plan, which is
            logged before execution". Selection arrives either from the
            Applications variable - rules or wizard - or as a fixed list in the
            step, and both come through here, so there is one ordering and one
            place a cycle is caught.

            The sort is Kahn's algorithm over the dependency graph, with one
            deliberate constraint on top of it.

            DETERMINISM IS THE POINT, not a nicety. A topological sort has freedom
            wherever two applications are independent of each other, and an
            implementation that spends that freedom on hashtable enumeration order
            produces a different plan on different runs of the same deployment.
            The plan is logged before execution and read afterwards when a build
            went wrong, so this one spends it on the id in ORDINAL order: ready
            applications are emitted smallest id first, whatever order the catalog
            or the selection arrived in. Three tests hold that in place, including
            one that reverses the catalog and one that reverses the selection.

            THE PLAN IS THE SELECTION PLUS ITS TRANSITIVE CLOSURE, and nothing
            else. Selecting an application selects what it needs; it does not
            select the rest of the catalog. Selecting the same application twice,
            or two applications that share a dependency, installs each thing once.

            A CYCLE IS AN AUTHORING ERROR AND IT NAMES EVERY MEMBER. Anything
            left unemitted when no application has an unsatisfied dependency is,
            by construction, exactly the applications in cycles - so they are
            listed in the message rather than summarised as "a cycle was
            detected".

            A DEPENDENCY THAT IS NOT IN THE CATALOG names both ends. The usual
            cause is an application that was never imported, and being told only
            the missing id leaves an administrator grepping for who wanted it.

            Assert-HDTApplicationDocument has already refused an application that
            depends on itself, so a cycle of length one never reaches this
            function.

        .PARAMETER Application
            The catalog, as Get-HDTApplication returns it. Each entry needs an Id
            and a Dependencies list; the objects themselves are what comes back
            out, not rebuilt copies.

        .PARAMETER Id
            The selection. Omit it to order the whole catalog; pass an empty array
            for an empty plan.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the selected
            applications and their transitive dependencies, dependencies first.

        .EXAMPLE
            $root = 'C:\HDTLab\Share'
            $fs = New-HDTFileSystem
            $catalog = @(Get-HDTApplication -WorkspaceRoot $root -FileSystem $fs)
            $context = @('Igor-Pavlov-7-Zip-24.09')
            Resolve-HDTApplicationOrder -Application $catalog -Id 'Contoso-Suite'

        .EXAMPLE
            $catalog = Get-HDTApplication -WorkspaceRoot $root -FileSystem $fs
            Resolve-HDTApplicationOrder -Application $catalog -Id ($context.Variable['HDTApplications'] -split ',')

            The Applications variable resolving to the same plan a fixed list in
            the step would have produced.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Application,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- the catalog, indexed -------------------------------------------------

    $byId = @{}

    foreach ($current in @($Application)) {
        $currentId = [string] $current.Id

        if ($byId.ContainsKey($currentId)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("two applications in this workspace declare the id '{0}'. An id is the folder name under Applications\, so naming it does not identify one of them." -f $currentId)))
        }

        $byId[$currentId] = $current
    }

    # -- the selection, closed over its dependencies --------------------------

    $selected = @($Id)
    if (-not $PSBoundParameters.ContainsKey('Id')) {
        $selected = @(@($Application) | ForEach-Object { [string] $_.Id })
    }

    $wanted = New-Object -TypeName System.Collections.ArrayList
    $pending = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($selected)) {
        [void] $pending.Add([string] $current)
    }

    while ($pending.Count -gt 0) {
        $currentId = [string] $pending[0]
        $pending.RemoveAt(0)

        if ($wanted -contains $currentId) { continue }

        if (-not $byId.ContainsKey($currentId)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("'{0}' is not an application in this workspace. Import it, or correct the id that names it." -f $currentId)))
        }

        [void] $wanted.Add($currentId)

        foreach ($dependencyId in @($byId[$currentId].Dependencies)) {
            $dependency = [string] $dependencyId

            if (-not $byId.ContainsKey($dependency)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                            -Message ("'{0}' depends on '{1}', which is not an application in this workspace. Import '{1}' or remove the dependency." -f $currentId, $dependency)))
            }

            [void] $pending.Add($dependency)
        }
    }

    # -- the sort -------------------------------------------------------------

    # Kahn's algorithm. 'Remaining' is what has not been emitted yet; an
    # application is ready when every dependency of it that is in the plan has
    # already been emitted.
    $remaining = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @($wanted)) { [void] $remaining.Add([string] $current) }

    $emitted = New-Object -TypeName System.Collections.ArrayList
    $plan = New-Object -TypeName System.Collections.ArrayList

    while ($remaining.Count -gt 0) {
        $ready = New-Object -TypeName System.Collections.ArrayList

        foreach ($currentId in @($remaining)) {
            $satisfied = $true

            foreach ($dependencyId in @($byId[$currentId].Dependencies)) {
                if ($emitted -notcontains [string] $dependencyId) {
                    $satisfied = $false
                    break
                }
            }

            if ($satisfied) { [void] $ready.Add([string] $currentId) }
        }

        if ($ready.Count -eq 0) {
            # Nothing is ready and something is left: every application still
            # here is in a cycle or depends on one. Listing them is the whole
            # value of the message.
            $stuck = [string[]] @($remaining)
            [array]::Sort($stuck, [System.StringComparer]::Ordinal)

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("these applications depend on each other in a cycle and cannot be ordered: {0}. A dependency chain has to end somewhere." -f ($stuck -join ', '))))
        }

        # THE DETERMINISM. Ordinal, not culture-aware: a plan must not depend on
        # the locale of the machine that built it.
        $readyId = [string[]] @($ready)
        [array]::Sort($readyId, [System.StringComparer]::Ordinal)

        $next = $readyId[0]

        [void] $plan.Add($byId[$next])
        [void] $emitted.Add($next)
        [void] $remaining.Remove($next)
    }

    return @($plan)
}

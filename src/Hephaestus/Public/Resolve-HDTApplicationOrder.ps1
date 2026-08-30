function Resolve-HDTApplicationOrder {
    <#
        .SYNOPSIS
            Turns an application catalog and a selection into the ordered install
            plan, and records why every entry is in it.

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

            AND IT SAYS WHY, WHICH IT USED TO KEEP TO ITSELF. A real deployment
            asked for one application and installed two; the whole log record of
            the second was its id in the plan line. Nothing said that nothing had
            requested it and nothing named what had, so an administrator could
            not tell a dependency from a typo in HDTApplications. Every fact
            needed to answer that lived in this function as a local variable and
            went out of scope when it returned:

              the CLOSURE knows who named an id, at what depth, and by what chain
              the SORT knows what an entry waited for and what tie it won

            Provenance and Decision are how those leave. They are collections the
            CALLER owns and this fills - the shape Expand-HDTVariableToken already
            uses for its Unresolved list - rather than a second return value,
            because the plan itself is what nearly every caller wants and adding
            a wrapper object around it would break all of them. It also means a
            PARTIAL trace survives a terminating error: a step that fails on an
            unorderable plan can still log the closure that led up to the cycle,
            which is exactly the run where somebody needs it.

            REQUIREDBY IS EVERY REQUESTER, NOT THE FIRST ONE FOUND. A dependency
            two selected applications share is required by both, and an
            application that was requested by name AND needed by another is both -
            Reason says RequestedAndRequired rather than picking a side. Path,
            by contrast, is the SHORTEST chain that reached it, because the walk
            is breadth-first and the first arrival is the shortest one.

        .PARAMETER Application
            The catalog, as Get-HDTApplication returns it. Each entry needs an Id
            and a Dependencies list; the objects themselves are what comes back
            out, not rebuilt copies.

        .PARAMETER Id
            The selection. Omit it to order the whole catalog; pass an empty array
            for an empty plan.

        .PARAMETER Provenance
            An optional dictionary this fills with one record per planned
            application, keyed by id and inserted in PLAN order, so enumerating it
            is reading the plan. Each record carries Id, Order, Requested,
            RequiredBy, Depth, Path, Reason, WaitedFor and Ready. Pass an ordered,
            case-insensitive dictionary; the ids the catalog holds are what the
            keys are spelled as.

        .PARAMETER Decision
            An optional list this appends the resolution itself to, in the order
            it happened: Selection, Edge, Duplicate, Round and, where one is
            found, Cycle. It is the closure walk and the sort written down rather
            than inferred from their result.

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

        .EXAMPLE
            $catalog = Get-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share' -FileSystem (New-HDTFileSystem)
            $why = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $trace = New-Object -TypeName System.Collections.ArrayList
            $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id 'Contoso-Suite' -Provenance $why -Decision $trace)
            $why['Contoso-Agent'].RequiredBy

            Contoso-Suite - the answer to "nobody asked for this, so what did?".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Application,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Id,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Provenance,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IList] $Decision
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # One writer for the trace, so every site below is a single line and a caller
    # that wants none pays for nothing but a null check.
    $note = {
        param([string] $Kind, [System.Collections.IDictionary] $Field)

        if ($null -eq $Decision) { return }

        $entry = [ordered] @{ Kind = $Kind }
        foreach ($key in @($Field.Keys)) { $entry[[string] $key] = $Field[$key] }

        [void] $Decision.Add([pscustomobject] $entry)
    }

    # Ordinal, not culture-aware, everywhere a list of ids is reported - for the
    # reason the sort is ordinal. A trace that reorders itself on a machine with
    # a different locale is not evidence of anything.
    $sorted = {
        param([object[]] $Value)

        $text = [string[]] @(@($Value) | ForEach-Object { [string] $_ })
        [array]::Sort($text, [System.StringComparer]::Ordinal)

        # THE COMMA IS LOAD-BEARING. A one-element array returned from a
        # scriptblock is unwrapped to the element, so a single ready application
        # came back as a STRING and $readyId[0] was its first character - a plan
        # of one that ordered a one-letter id nothing in the catalog answers to.
        return , $text
    }

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
    $wholeCatalog = -not $PSBoundParameters.ContainsKey('Id')
    if ($wholeCatalog) {
        $selected = @(@($Application) | ForEach-Object { [string] $_.Id })
    }

    & $note 'Selection' ([ordered] @{
            Id           = [string[]] @($selected)
            WholeCatalog = $wholeCatalog
        })

    $wanted = New-Object -TypeName System.Collections.ArrayList
    $pending = New-Object -TypeName System.Collections.ArrayList

    # WHY THE QUEUE CARRIES MORE THAN AN ID NOW. NamedBy is what makes "nothing
    # requested this" answerable at all, and Path is what makes a THREE-deep
    # chain readable: A -> B -> C says C is here because of B, and B because of
    # A, which two separate records never quite say.
    $enqueue = {
        param([string] $ItemId, [object] $NamedBy, [int] $Depth, [string[]] $Path)

        [void] $pending.Add([pscustomobject] @{
                Id      = $ItemId
                NamedBy = $NamedBy
                Depth   = $Depth
                Path    = [string[]] $Path
            })
    }

    foreach ($current in @($selected)) {
        & $enqueue ([string] $current) $null 0 ([string[]] @([string] $current))
    }

    $discovery = @{}

    while ($pending.Count -gt 0) {
        $item = $pending[0]
        $pending.RemoveAt(0)

        $currentId = [string] $item.Id

        if ($wanted -contains $currentId) {
            # THE COLLAPSE IS A DECISION, and until this record existed the only
            # evidence of it was an absence from the plan. Two applications that
            # share a dependency, or a selection that names one twice, land here.
            & $note 'Duplicate' ([ordered] @{
                    Id      = $currentId
                    NamedBy = $item.NamedBy
                })

            continue
        }

        if (-not $byId.ContainsKey($currentId)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("'{0}' is not an application in this workspace. Import it, or correct the id that names it." -f $currentId)))
        }

        [void] $wanted.Add($currentId)

        # BREADTH-FIRST, so the first arrival is the SHORTEST chain. The queue is
        # FIFO by construction above; recording the path on any other walk order
        # would record a chain that happens to be long.
        $discovery[$currentId] = [pscustomobject] @{
            Depth = [int] $item.Depth
            Path  = [string[]] @($item.Path)
        }

        foreach ($dependencyId in @($byId[$currentId].Dependencies)) {
            $dependency = [string] $dependencyId

            & $note 'Edge' ([ordered] @{
                    Id        = $currentId
                    DependsOn = $dependency
                })

            if (-not $byId.ContainsKey($dependency)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                            -Message ("'{0}' depends on '{1}', which is not an application in this workspace. Import '{1}' or remove the dependency." -f $currentId, $dependency)))
            }

            & $enqueue $dependency $currentId ([int] $item.Depth + 1) ([string[]] (@($item.Path) + @($dependency)))
        }
    }

    # -- who asked for what ---------------------------------------------------

    # REQUESTED IS THE SELECTION, matched the way the closure matched it - the
    # catalog index is case-insensitive, so a selection spelled in another case
    # resolved to the same application and has to report as having done so.
    $requested = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' `
        -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($current in @($selected)) { [void] $requested.Add([string] $current) }

    # EVERY REQUESTER, NOT THE FIRST. A shared dependency is required by both of
    # the applications that share it, and a record naming one of them invites an
    # administrator to remove the wrong dependency and find it still installed.
    $requiredBy = @{}
    foreach ($currentId in @($wanted)) { $requiredBy[$currentId] = New-Object -TypeName System.Collections.ArrayList }

    foreach ($currentId in @($wanted)) {
        foreach ($dependencyId in @($byId[$currentId].Dependencies)) {
            $dependency = [string] $dependencyId

            if ($requiredBy.ContainsKey($dependency) -and $requiredBy[$dependency] -notcontains $currentId) {
                [void] $requiredBy[$dependency].Add($currentId)
            }
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
    $round = @{}
    $roundNumber = 0

    while ($remaining.Count -gt 0) {
        $roundNumber++

        $ready = New-Object -TypeName System.Collections.ArrayList
        $blocked = New-Object -TypeName System.Collections.ArrayList

        foreach ($currentId in (& $sorted @($remaining))) {
            $waiting = New-Object -TypeName System.Collections.ArrayList

            foreach ($dependencyId in @($byId[$currentId].Dependencies)) {
                if ($emitted -notcontains [string] $dependencyId) {
                    [void] $waiting.Add([string] $dependencyId)
                }
            }

            if ($waiting.Count -eq 0) {
                [void] $ready.Add([string] $currentId)
            } else {
                # WHAT IT IS WAITING FOR, not merely that it waited. A plan whose
                # order surprises somebody is explained by this list and by
                # nothing else in the log.
                [void] $blocked.Add([pscustomobject] @{
                        Id        = [string] $currentId
                        BlockedOn = & $sorted @($waiting)
                    })
            }
        }

        if ($ready.Count -eq 0) {
            # Nothing is ready and something is left: every application still
            # here is in a cycle or depends on one. Listing them is the whole
            # value of the message.
            $stuck = & $sorted @($remaining)

            & $note 'Cycle' ([ordered] @{
                    Number = $roundNumber
                    Stuck  = $stuck
                })

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("these applications depend on each other in a cycle and cannot be ordered: {0}. A dependency chain has to end somewhere." -f ($stuck -join ', '))))
        }

        # THE DETERMINISM. Ordinal, not culture-aware: a plan must not depend on
        # the locale of the machine that built it.
        $readyId = & $sorted @($ready)

        $next = $readyId[0]

        # WHAT IT WAITED FOR is its dependencies in the plan, all of them emitted
        # by now; what it BEAT is the rest of the ready set. Together they are
        # the answer to "why is this one here and not there".
        $waitedFor = New-Object -TypeName System.Collections.ArrayList
        foreach ($dependencyId in @($byId[$next].Dependencies)) {
            if ($requiredBy.ContainsKey([string] $dependencyId)) {
                [void] $waitedFor.Add([string] $dependencyId)
            }
        }

        $round[$next] = [pscustomobject] @{
            Number    = $roundNumber
            Ready     = $readyId
            WaitedFor = & $sorted @($waitedFor)
        }

        & $note 'Round' ([ordered] @{
                Number  = $roundNumber
                Ready   = $readyId
                Blocked = [object[]] @($blocked)
                Emitted = $next
            })

        [void] $plan.Add($byId[$next])
        [void] $emitted.Add($next)
        [void] $remaining.Remove($next)
    }

    # -- the record, in plan order --------------------------------------------

    # FILLED LAST AND IN PLAN ORDER, so enumerating it is reading the plan. Order
    # is not known until the sort has run, and a dictionary written during the
    # closure would enumerate in discovery order - which is a different sequence
    # from the one that installs, and reading it as the plan is how a log gets
    # misread.
    if ($null -ne $Provenance) {
        $position = 0

        foreach ($entry in @($plan)) {
            $position++
            $currentId = [string] $entry.Id

            $isRequested = $requested.Contains($currentId)
            $requester = & $sorted @($requiredBy[$currentId])

            $reason = 'Required'
            if ($isRequested -and @($requester).Count -gt 0) {
                $reason = 'RequestedAndRequired'
            } elseif ($isRequested) {
                $reason = 'Requested'
            }

            $Provenance[$currentId] = [pscustomobject] ([ordered] @{
                    Id         = $currentId
                    Order      = $position
                    Requested  = $isRequested
                    RequiredBy = [string[]] $requester
                    Depth      = [int] $discovery[$currentId].Depth
                    Path       = [string[]] @($discovery[$currentId].Path)
                    Reason     = $reason
                    WaitedFor  = [string[]] @($round[$currentId].WaitedFor)
                    Ready      = [string[]] @($round[$currentId].Ready)
                })
        }
    }

    return @($plan)
}

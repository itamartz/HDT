function Write-HDTApplicationPlanLog {
    <#
        .SYNOPSIS
            Writes the install plan and the reason for every line of it.

        .DESCRIPTION
            DESIGN 8's "logged before execution", answered properly. The plan line
            said WHAT would install and nothing said WHY.

            THE RUN THAT FORCED THIS. run-20260830-204613 asked for one
            application - HDTApplications = 'TightVNC-Software-Tightvnc-2.8.88'
            (Rule) - and installed two, because TightVNC's app.yaml declares a
            dependency on Acrobat. The whole log record of that decision was
            Acrobat's id inside 'install plan, in order:'. Nothing said Acrobat
            was never requested and nothing named what had required it, so an
            administrator could not tell a dependency from a typo in
            HDTApplications, and on a machine where the extra install was
            unwanted there was no thread to pull.

            PROVENANCE IS ALREADY A FIRST-CLASS IDEA IN THIS ENGINE. rules.yaml
            resolution records the source of every variable and
            Write-HDTVariableLog prints "HDTApplications = '...' (Rule)". The
            install plan was the one derived structure that threw it away, so
            this follows that idiom rather than inventing a second vocabulary:
            applications are named in single quotes and the edge is spelled
            "depends on", the way Resolve-HDTApplicationOrder's cycle message and
            its missing-dependency message already name them.

            AT Info, NOT Debug. An install nobody requested is exactly the thing
            an administrator needs to see without having turned debug logging on
            beforehand - and they cannot turn it on beforehand, because they did
            not know it was going to happen. Debug is for VOLUME: the dependency
            edges and the sort rounds, which are the graph and the algorithm and
            which a plan of forty applications has hundreds of.

            AND AS DATA. The message is what a technician reads; data.requested,
            data.requiredBy and data.path are what answers "which machines
            installed something nobody asked for" across a fleet of JSONL files,
            which is a query rather than a grep.

            IT RUNS ON A PLAN THAT COULD NOT BE ORDERED TOO. Provenance and
            Decision are collections the CALLER owns and the resolver fills, so a
            partial trace survives the terminating error a cycle throws. There is
            no plan to report then, and this writes the closure it got through
            and the cycle that stopped it - which is the one run where somebody
            needs the resolution written down.

        .PARAMETER Context
            A New-HDTLogContext context.

        .PARAMETER Plan
            The ordered plan Resolve-HDTApplicationOrder returned. Empty where the
            resolution failed, and then the plan lines are simply not written.

        .PARAMETER Provenance
            The dictionary Resolve-HDTApplicationOrder filled: one record per
            planned application, keyed by id, in plan order.

        .PARAMETER Decision
            The list Resolve-HDTApplicationOrder appended its resolution to -
            Selection, Edge, Duplicate, Round and Cycle records.

        .PARAMETER Source
            Optional map of id to the name of the input that asked for it - the
            step's selection, HDTApplications, HDTMandatoryApplications. An id
            that is not in it reports as "the selection", which is true and
            useless rather than false and useful.

        .PARAMETER Component
            The log component. InstallApplications unless a caller says otherwise.

        .OUTPUTS
            None.

        .EXAMPLE
            $why = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $trace = New-Object -TypeName System.Collections.ArrayList
            $catalog = @(Get-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share' -FileSystem (New-HDTFileSystem))
            $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id 'Contoso-Suite' -Provenance $why -Decision $trace)
            Write-HDTApplicationPlanLog -Context $context.Log -Plan $plan -Provenance $why -Decision $trace
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Appends to a log; there is nothing to confirm and nothing to roll back.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Plan,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Provenance,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IList] $Decision,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Source,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Component = 'InstallApplications'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NO -Event, AND DELIBERATELY. DESIGN 4.4's event vocabulary is closed and
    # holds no application name; step.start has already fired for this step and a
    # second lifecycle event here would make the stream lie about how many steps
    # ran. These are messages, and data is what a consumer filters on.

    # -- the small renderers --------------------------------------------------

    # Applications are named in single quotes, comma separated, the way the cycle
    # message names them. One place, so the twelve messages below cannot drift
    # into twelve spellings of the same list.
    $quoted = {
        param([object[]] $Value)

        return (@(@($Value) | ForEach-Object { "'{0}'" -f [string] $_ }) -join ', ')
    }

    $plural = {
        param([int] $Count, [string] $Singular, [string] $Plural)

        if ($Count -eq 1) { return $Singular }
        return $Plural
    }

    $say = {
        param([string] $Message, [string] $Severity, [System.Collections.IDictionary] $Data)

        Write-HDTLog -Context $Context -Message $Message -Severity $Severity -Component $Component -Data $Data
    }

    $planned = [string[]] @(@($Plan) | ForEach-Object { [string] $_.Id })

    # -- the plan, and what of it nobody asked for ----------------------------

    if (@($planned).Count -gt 0 -and $null -ne $Provenance) {
        $requestedId = New-Object -TypeName System.Collections.ArrayList
        $requiredId = New-Object -TypeName System.Collections.ArrayList

        foreach ($id in @($planned)) {
            if ($Provenance.Contains($id) -and $Provenance[$id].Requested) {
                [void] $requestedId.Add($id)
            } else {
                [void] $requiredId.Add($id)
            }
        }

        # THE LINE ITSELF IS UNCHANGED. It is the one an administrator already
        # knows to grep for, and data is where the split between what was asked
        # for and what was pulled in goes.
        & $say ('install plan, in order: {0}' -f ($planned -join ', ')) 'Info' ([ordered] @{
                planned   = $planned
                requested = [string[]] @($requestedId)
                required  = [string[]] @($requiredId)
            })

        & $say ('the selection named {0} {1} and the dependency closure added {2} more, for a plan of {3}.' -f
            $requestedId.Count, (& $plural $requestedId.Count 'application' 'applications'),
            $requiredId.Count, @($planned).Count) 'Info' ([ordered] @{
                requested = $requestedId.Count
                required  = $requiredId.Count
                planned   = @($planned).Count
            })
    }

    # -- the closure, as it happened ------------------------------------------

    foreach ($entry in @($Decision)) {
        if ($entry.Kind -eq 'Edge') {
            & $say ("dependency edge: '{0}' depends on '{1}'." -f $entry.Id, $entry.DependsOn) 'Debug' ([ordered] @{
                    id        = [string] $entry.Id
                    dependsOn = [string] $entry.DependsOn
                })
        } elseif ($entry.Kind -eq 'Duplicate') {
            # THE COLLAPSE, SAID OUT LOUD. Two applications that share a
            # dependency install it once, and until this line the only evidence
            # of that decision was an absence from the plan.
            if ([string]::IsNullOrEmpty([string] $entry.NamedBy)) {
                $message = ("'{0}' was named more than once by the selection; it is in the plan once and installs once." -f $entry.Id)
            } else {
                $message = ("'{0}' was named again by '{1}', which also depends on it; it is in the plan once and installs once." -f
                    $entry.Id, $entry.NamedBy)
            }

            & $say $message 'Info' ([ordered] @{
                    id      = [string] $entry.Id
                    namedBy = $(if ([string]::IsNullOrEmpty([string] $entry.NamedBy)) { $null } else { [string] $entry.NamedBy })
                })
        }
    }

    # -- why each application is in the plan, and where -----------------------

    if (@($planned).Count -gt 0 -and $null -ne $Provenance) {
        $total = @($planned).Count

        foreach ($id in @($planned)) {
            if (-not $Provenance.Contains($id)) { continue }

            $record = $Provenance[$id]

            $requester = [string[]] @($record.RequiredBy)
            $requesterText = & $quoted $requester
            $dependVerb = & $plural @($requester).Count 'depends' 'depend'

            $sourceName = 'the selection'
            if ($null -ne $Source -and $Source.Contains($id)) {
                $sourceName = [string] $Source[$id]
            }

            if ($record.Reason -eq 'RequestedAndRequired') {
                $message = ("'{0}' is in the plan because {1} asked for it, and because {2} {3} on it." -f
                    $id, $sourceName, $requesterText, $dependVerb)
            } elseif ($record.Reason -eq 'Requested') {
                $message = ("'{0}' is in the plan because {1} asked for it." -f $id, $sourceName)
            } else {
                # THE SENTENCE THE REAL RUN WAS MISSING. "Nothing asked for it by
                # name" is the whole difference between a dependency and a typo,
                # and the chain is what turns a name into somewhere to go.
                $message = ("'{0}' is in the plan because {1} {2} on it. Nothing asked for it by name; the chain that pulled it in is {3}." -f
                    $id, $requesterText, $dependVerb, (@($record.Path) -join ' -> '))
            }

            & $say $message 'Info' ([ordered] @{
                    id         = $id
                    order      = [int] $record.Order
                    requested  = [bool] $record.Requested
                    source     = $(if ($record.Requested) { $sourceName } else { $null })
                    requiredBy = $requester
                    depth      = [int] $record.Depth
                    path       = [string[]] @($record.Path)
                    reason     = [string] $record.Reason
                })

            # WHERE IT SITS, which is a different question from why it is here at
            # all. A plan whose order surprises somebody is explained by what an
            # entry waited for and what it beat, and by nothing else in the log.
            $waited = [string[]] @($record.WaitedFor)

            if (@($waited).Count -eq 0) {
                $position = ("plan position {0} of {1}: '{2}' was ready immediately; it depends on nothing in the plan." -f
                    $record.Order, $total, $id)
            } else {
                $position = ("plan position {0} of {1}: '{2}' was ready once {3} had installed, which it depends on." -f
                    $record.Order, $total, $id, (& $quoted $waited))
            }

            $beaten = [string[]] @(@($record.Ready) | Where-Object { $_ -ne $id })

            if (@($beaten).Count -gt 0) {
                $position += (' {0} {1} ready too, and the tie broke on the id in ordinal order.' -f
                    (& $quoted $beaten), (& $plural @($beaten).Count 'was' 'were'))
            }

            & $say $position 'Info' ([ordered] @{
                    id        = $id
                    order     = [int] $record.Order
                    of        = $total
                    waitedFor = $waited
                    readyWith = $beaten
                })
        }
    }

    # -- the sort, round by round ---------------------------------------------

    foreach ($entry in @($Decision)) {
        if ($entry.Kind -eq 'Round') {
            $blocked = @($entry.Blocked)

            if (@($blocked).Count -eq 0) {
                $tail = 'nothing else was left'
            } else {
                $tail = ('still blocked {0}' -f ((@($blocked) | ForEach-Object {
                                "'{0}' on {1}" -f $_.Id, (& $quoted @($_.BlockedOn))
                            }) -join ', '))
            }

            & $say ('sort round {0}: ready {1}; emitted ''{2}''; {3}.' -f
                $entry.Number, (& $quoted @($entry.Ready)), $entry.Emitted, $tail) 'Debug' ([ordered] @{
                    round   = [int] $entry.Number
                    ready   = [string[]] @($entry.Ready)
                    emitted = [string] $entry.Emitted
                    blocked = [object[]] @($blocked)
                })
        } elseif ($entry.Kind -eq 'Cycle') {
            # A WARNING, NOT AN ERROR, because the step's own failure is the
            # error and two error records for one event make a reader hunt for a
            # second fault. This one says how far the resolution got.
            & $say ('sort round {0} found nothing ready and {1} {2} left: {3}. They depend on each other, so this plan cannot be ordered.' -f
                $entry.Number, @($entry.Stuck).Count,
                (& $plural @($entry.Stuck).Count 'application' 'applications'),
                (& $quoted @($entry.Stuck))) 'Warning' ([ordered] @{
                    round = [int] $entry.Number
                    stuck = [string[]] @($entry.Stuck)
                })
        }
    }
}

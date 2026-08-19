function Get-HDTConsoleDependencyChoice {
    <#
        .SYNOPSIS
            What an application's "Depends on" can be set to, and what it cannot.

        .DESCRIPTION
            A DEPENDENCY IS AN APPLICATION ID, AND TYPING ONE IS THE PROBLEM.
            Every way of getting it wrong fails late and badly: a misspelled id
            is not caught until a deployment runs and Resolve-HDTApplicationOrder
            refuses the whole plan - not just that application - on the machine
            in front of somebody. A pair that ends up depending on each other
            fails the same way, and nothing on the share looks wrong until then.

            SO IT IS PICKED. The list is the applications on this share, which
            makes a missing id impossible to produce, and the ticks are what the
            document already says.

            A CHOICE THAT WOULD CLOSE A LOOP IS OFFERED AND REFUSED, not hidden.
            An item that vanishes is a window somebody argues with; an item that
            is there, greyed, naming the loop it would make, is a window that
            answers "why can I not tick this". The chain is followed, not just
            the first step: A depends on B and B on C, so C depending on A closes
            a loop three long, and that is exactly what the resolver refuses.

            AN APPLICATION THAT WILL NOT READ IS NOT OFFERED. A row whose app.yaml
            failed to parse carries its folder name as an id and nothing else, so
            depending on it would write an id that may not be what the document
            says.

            THIS IS THE DECISION, NOT THE DIALOG. What is on the list, what is
            ticked and what cannot be is settled here, against no window at all.

        .PARAMETER Application
            The share's application rows, as Get-HDTConsoleWorkspace returns
            them: Id, Name, Dependency and Status.

        .PARAMETER Id
            The application being edited. It is never offered to itself.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per offer:

              Id        the id a document would hold
              Display   the name a technician reads
              Selected  the document already depends on it
              Blocked   choosing it would close a loop
              Choosable the same answer the other way up, because a tick box
                        binds IsEnabled and XAML cannot negate a binding
              Reason    which loop, when it would

        .EXAMPLE
            Get-HDTConsoleDependencyChoice -Application $share.Application -Id 'Contoso-Suite'

        .LINK
            Set-HDTApplication

        .LINK
            Resolve-HDTApplicationOrder
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Application,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $readable = @($Application | Where-Object { [string] $_.Status -ne 'Error' })

    $dependencyOf = @{}
    $nameOf = @{}

    foreach ($current in @($readable)) {
        $key = ([string] $current.Id).ToLowerInvariant()

        $dependencyOf[$key] = @(@($current.Dependency) | ForEach-Object { ([string] $_).ToLowerInvariant() })
        $nameOf[$key] = [string] $current.Name
    }

    $me = $Id.ToLowerInvariant()

    $mine = @()
    if ($dependencyOf.ContainsKey($me)) { $mine = @($dependencyOf[$me]) }

    # DOES THIS CANDIDATE ALREADY DEPEND ON ME, at any depth? If it does, my
    # depending on it closes a loop - which is the one thing
    # Resolve-HDTApplicationOrder cannot order.
    #
    # $seen IS WHAT MAKES IT TERMINATE. A share that already holds a cycle -
    # hand-edited, or written before this window existed - would otherwise walk
    # it forever, and a console that hangs on a bad document is worse than one
    # that shows it.
    $reaches = {
        param([string] $From, [string] $Wanted, $Seen)

        if ($Seen.Contains($From)) { return $false }
        [void] $Seen.Add($From)

        if (-not $dependencyOf.ContainsKey($From)) { return $false }

        foreach ($step in @($dependencyOf[$From])) {
            if ($step -eq $Wanted) { return $true }
            if (& $reaches $step $Wanted $Seen) { return $true }
        }

        return $false
    }

    $offer = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($readable)) {
        $key = ([string] $current.Id).ToLowerInvariant()
        if ($key -eq $me) { continue }

        $blocked = [bool] (& $reaches $key $me (New-Object -TypeName 'System.Collections.Generic.HashSet[string]'))
        $reason = ''

        if ($blocked) {
            $reason = "'{0}' already depends on '{1}', so making it a dependency the other way round is a loop nothing can install." -f
            [string] $current.Name, (Get-HDTConsoleDisplayText -Text $nameOf[$me] -Fallback $Id)
        }

        [void] $offer.Add([pscustomobject] @{
                Id       = [string] $current.Id
                Display  = [string] $current.Name
                Selected = [bool] ($mine -contains $key)
                Blocked  = $blocked

                # THE SAME ANSWER THE OTHER WAY UP. The dialog binds IsEnabled
                # to this: a binding cannot negate, and a converter for one
                # boolean is a class in a module that loads markup with
                # XamlReader.
                Choosable = -not $blocked
                Reason   = $reason
            })
    }

    # NAME ORDER, so the list does not reshuffle as the share grows.
    return [pscustomobject[]] @(@($offer) | Sort-Object -Property Display)
}

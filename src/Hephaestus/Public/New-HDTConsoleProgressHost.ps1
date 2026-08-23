function New-HDTConsoleProgressHost {
    <#
        .SYNOPSIS
            The IProgressHost for a machine that cannot draw a window: it writes
            DESIGN 11.1's console lines instead.

        .DESCRIPTION
            THE FALLBACK IS A HOST, NOT A BRANCH AT THE CALL SITE. When the
            window cannot be opened, Start-HDTProgressDisplay hands back one of
            these instead of the WPF one - so the engine calls Update the same
            way whatever machine it is on, and there is no `if ($mode -eq
            'Window')` anywhere for somebody to forget.

            That matters more than it looks. DESIGN 11.1's fallback exists for
            "a boot image built without the right components, an exotic display,
            a serial console" - all machines nobody is testing on - and a branch
            at every call site is a branch that is wrong on exactly those.

            IT REPEATS NOTHING. The same line twice tells a technician the
            deployment is stuck when it is only the caller polling; a console
            scrolls, so every line printed pushes the last real change further
            up. Only a line that DIFFERS is written.

            THE LINE ITSELF IS Format-HDTProgressLine's, which is pure and
            tested. What is left here is writing it, which is why this adapter
            can be exempt from tests at all (CLAUDE.md rule 1).

            Write-Information, NOT Write-Host. The payload sets
            $InformationPreference and the stream is redirectable, so a lab
            harness can capture the deployment's own account of itself. Write-Host
            goes to a screen nobody is reading on the machines this exists for.

        .OUTPUTS
            A PSCustomObject with Open(xaml), Update(progress), SetComputerName
            and Close() - the same shape New-HDTProgressHost has, so callers
            cannot tell them apart.

        .EXAMPLE
            $displayHost = New-HDTConsoleProgressHost
            $displayHost.Open('X:\HDT\UI\HDTProgress.xaml')

            DESIGN 11.1's progress window, in its own runspace. A WPF window owns the
            thread it was made on, so one on the engine's thread would be a
            deployment that stopped at the first step to draw a bar about it.

        .EXAMPLE
            $displayHost.SetComputerName('PC-0001')
            $displayHost.Close()

            Update and SetComputerName write into a synchronised hashtable the two
            runspaces share; the UI thread's own timer reads it. Neither touches
            the window, because reaching across a thread to a WPF object throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    # Open takes markup it has no use for, ON PURPOSE: the signature has to match
    # New-HDTProgressHost's or the two are not interchangeable, and being
    # interchangeable is the entire reason this object exists.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Open mirrors the WPF host signature so the two hosts are interchangeable; there is nothing to load.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        ComputerName = ''
        LastLine     = ''
    }

    # NOTHING TO OPEN. The signature matches the WPF host so the two are
    # interchangeable, and that is the whole point of this object.
    $service | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param([string] $Xaml)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetComputerName -Value {
        param([string] $Name)

        $this.ComputerName = $Name
    }

    $service | Add-Member -MemberType ScriptMethod -Name Update -Value {
        param([object] $Progress)

        if ($null -eq $Progress) { return }

        $line = Format-HDTProgressLine -Progress $Progress
        if ($line -eq $this.LastLine) { return }

        $this.LastLine = $line
        Write-Information -MessageData $line -InformationAction Continue
    }

    $service | Add-Member -MemberType ScriptMethod -Name Close -Value { }

    return $service
}

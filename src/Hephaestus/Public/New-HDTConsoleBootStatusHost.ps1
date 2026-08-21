function New-HDTConsoleBootStatusHost {
    <#
        .SYNOPSIS
            The IBootStatusHost for a machine that cannot draw the overlay: it
            writes nothing, because the console it would have written to is
            still on screen.

        .DESCRIPTION
            THE FALLBACK IS A HOST, NOT A BRANCH AT THE CALL SITE. When the
            overlay cannot be opened, Start-HDTBootStatus hands back one of these
            instead of the WPF one - so the payload calls Write the same way
            whatever machine it is on, and there is no `if ($mode -eq 'Window')`
            around every line for somebody to forget. That matters more than it
            looks: the machines this exists for - a boot image built without
            WinPE-NetFx, an exotic display, a serial console - are the machines
            nobody is testing on.

            AND IT WRITES NOTHING, WHICH IS NOT AN OVERSIGHT. Unlike
            New-HDTConsoleProgressHost, which is the only thing reporting on that
            machine, this one is a SECOND copy of a line the payload's own $say
            has already written with Write-Information. Printing it again would
            double every line of a deployment's account of itself.

            THE CONSOLE IS STILL THERE TO READ IT, and that is the contract this
            object is half of: Start-HDTDeployment hides the WinPE console ONLY
            when Mode is Window. A machine that could not draw the overlay keeps
            its console, so nobody is ever left looking at a blank screen.

        .OUTPUTS
            A PSCustomObject with Open(xaml, commandPromptPath, text),
            Write(line) and Close() - the same shape New-HDTBootStatusHost has,
            so callers cannot tell them apart.

        .EXAMPLE
            $status = Start-HDTBootStatus -XamlPath $p
            $status.StatusHost.Write($line)

            Draws a line in the overlay on a machine that has one, and does
            nothing on a machine whose console is still showing it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    # Open and Write take arguments they have no use for, ON PURPOSE: the
    # signatures have to match New-HDTBootStatusHost's or the two are not
    # interchangeable, and being interchangeable is the entire reason this object
    # exists.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'The methods mirror the WPF host signature so the two hosts are interchangeable; there is nothing to draw.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        LastLine = ''
    }

    $service | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param([string] $Xaml, [string] $CommandPromptPath, [hashtable] $Text)
    }

    $service | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([string] $Line)

        # RECORDED, NOT PRINTED. $say already put this on the console; keeping
        # the last one is what lets a caller assert this object was used at all.
        $this.LastLine = $Line
    }

    $service | Add-Member -MemberType ScriptMethod -Name Close -Value { }

    return $service
}

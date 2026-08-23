function Step-HDTWizardPage {
    <#
        .SYNOPSIS
            Decides which wizard page is current, and what the shell shows
            around it.

        .DESCRIPTION
            THE NAVIGATOR FOR HDTWizardShell.xaml, and every branch the shell
            has lives here. The shell window opens ONCE and the page inside it
            is swapped in place - MDT's LiteTouch behaviour, and the reason the
            rail is a list rather than a TabControl: the order is the
            deployment's order, and a page becomes reachable by being reached.

            SO SOMETHING HAS TO DECIDE, ON EVERY CLICK, which page is now
            current, what the rail shows, whether Back is available, what the
            Next button says, and whether Next has run off the end of the list.
            That is this command, and it is pure - no window, no file system,
            no WPF, no clock.

            WHY THE SPLIT IS NOT NEGOTIABLE. New-HDTWizardHost is exempt from
            TDD as a thin WPF adapter (CLAUDE.md rule 1), and the price of that
            exemption is that the adapter must have NOTHING IN IT WORTH TESTING.
            The moment page order lived in the host, the host would be worth
            testing and could not be exempt - which is the trap it fell into
            once already, when it read the network and then crashed the first
            time it was really run, in WinPE, on a bench.

            Done IS THE ONE THAT MATTERS. It is what closes the window and lets
            the deployment start, so every other answer leaves it false. An
            off-by-one at the end of this list is a disk partitioned one page
            before the technician confirmed it.

            THE RAIL CARRIES NO COLOUR. Each row states what it IS - Done,
            Current or Pending - and HDTWizardShell.xaml's DataTemplate decides
            what those look like. A brush computed here would be a second place
            the look is defined, and the first one to drift from HDTTheme.xaml.

        .PARAMETER Page
            The ordered pages this deployment will actually ask, already
            filtered - a page that is skipped is not in this list and does not
            appear in the rail either (DESIGN 11.2). Each entry carries Id,
            Title, Heading, Subheading and the page's own markup.

        .PARAMETER Index
            Which page is current now, zero-based.

        .PARAMETER Action
            'Start' to render the current page unchanged, 'Next' or 'Back' to
            move. Anything else is refused rather than guessed at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Index, Page,
            Heading, Subheading, Rail, BackEnabled, NextCaption, Done and
            Action.

        .EXAMPLE
            Step-HDTWizardPage -Page $page -Index 0 -Action 'Start'

            The first page, as the shell opens.

        .EXAMPLE
            $state = Step-HDTWizardPage -Page $page -Index $state.Index -Action 'Next'
            if ($state.Done) { $window.Close() }

            What the host does on every click of Next.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # EMPTY IS ALLOWED THROUGH THE BINDER SO IT CAN BE REFUSED BY NAME. The
        # binder's own message for an empty mandatory array names the parameter
        # and nothing else; the refusal below names the decision the caller got
        # wrong, which is showing a wizard that has nothing to ask.
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Page,

        [Parameter(Mandatory = $true)]
        [int] $Index,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Start', 'Next', 'Back')]
        [string] $Action
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $ordered = @($Page)
    $count = @($ordered).Count

    # AN EMPTY LIST IS NOT AN EMPTY WIZARD, IT IS NO WIZARD. Every page skipped
    # means the shell must not be SHOWN, and that is the caller's decision - the
    # same rule HDTSkipWelcome follows in Get-HDTWizardSkip. A shell opened on
    # nothing would return an Action for a window with no content in it, which
    # is indistinguishable from a technician answering one that had.
    if ($count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ('the wizard has no pages to show. Every page being skipped means NOT SHOWING THE WIZARD, which is the caller''s decision - see DESIGN 11.2 and HDTSkipWizard.')))
    }

    if ($Index -lt 0 -or $Index -ge $count) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ('page index {0} is outside this wizard, which has {1} page(s). Valid indexes are 0 to {2}.' -f
                        $Index, $count, ($count - 1))))
    }

    # WHERE THE CLICK LANDS. Back stops at the front rather than wrapping:
    # the shell disables the button there, but a disabled button is a
    # presentation choice and this is the guarantee underneath it.
    $next = $Index
    if ($Action -eq 'Next') { $next = $Index + 1 }
    if ($Action -eq 'Back' -and $Index -gt 0) { $next = $Index - 1 }

    $done = $next -ge $count

    $current = $null
    $heading = ''
    $subheading = ''

    if (-not $done) {
        $current = $ordered[$next]
        $heading = [string] $current.Heading
        $subheading = [string] $current.Subheading
    }

    # THE RAIL STILL LISTS EVERY PAGE WHEN THE WIZARD IS DONE. It is the last
    # thing on screen before the window closes, and a rail that emptied itself
    # would flash blank on the way out.
    $rail = @()
    for ($position = 0; $position -lt $count; $position++) {

        $state = 'Pending'
        if ($position -lt $next) { $state = 'Done' }
        if ($position -eq $next) { $state = 'Current' }

        $rail += [pscustomobject] @{
            Id    = [string] $ordered[$position].Id
            Title = [string] $ordered[$position].Title
            State = $state
        }
    }

    # DEPLOY, NOT NEXT, ON THE LAST PAGE. MDT's Finish. The button that starts a
    # deployment must not read like the button that turns a page.
    $caption = 'Next'
    if (-not $done -and $next -eq ($count - 1)) { $caption = 'Deploy' }

    return [pscustomobject] @{
        Index       = $next
        Page        = $current
        Heading     = $heading
        Subheading  = $subheading
        Rail        = $rail
        BackEnabled = ($next -gt 0 -and -not $done)
        NextCaption = $caption
        Done        = $done
        Action      = $Action
    }
}

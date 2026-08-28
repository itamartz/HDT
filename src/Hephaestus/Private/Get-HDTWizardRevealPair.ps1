function Get-HDTWizardRevealPair {
    <#
        .SYNOPSIS
            Every reveal eye on a loaded page, with the two boxes each one
            swaps between.

        .DESCRIPTION
            THE HOST USED TO ANSWER THIS WITH THREE HARDCODED NAMES.
            New-HDTWizardHost looked up HDTPasswordRevealToggle,
            HDTPasswordBox and HDTPasswordRevealBox and wired that trio and no
            other - so a page could carry ONE revealable password, and the
            administrator password page, which has two boxes, could carry none.

            PasswordBox.Password IS NOT A DependencyProperty. It cannot be
            bound, styled or DataTriggered, and there is no code-behind in
            WinPE to reveal it - so a revealable password is two controls in
            one grid cell with something swapping which is visible. That
            "something" is the adapter, and what it needs from here is the list
            of trios to wire.

            THE CONVENTION IS THE TOGGLE'S OWN NAME, so nothing has to be
            written down twice: strip RevealToggle and what is left is the
            base.

              HDTPasswordRevealToggle -> HDTPassword
                                      -> HDTPasswordBox, HDTPasswordRevealBox

            A LONE TOGGLE IS SKIPPED, NOT AN ERROR. One host applies every
            page in the wizard and no page has all the controls - the field
            loop beside it skips an unknown name for exactly the same reason.
            A half-authored page must still open; in WinPE the alternative is a
            technician looking at a black screen.

            THE ORDER IS THE TOGGLE NAME. A caller wiring handlers does not
            care, but a test asserting the SET does, and rule 8 says the test
            is written against the set.

        .PARAMETER Root
            The element whose tree to search - a window, or the root of a page
            loaded into one. A page carries its own name scope, so this must be
            the element the boxes were parsed under and not the window above
            it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one per complete
            trio, with Toggle, Password and Reveal.

        .EXAMPLE
            foreach ($pair in Get-HDTWizardRevealPair -Root $pageRoot) {
                $pair.Toggle.Add_Checked({ ... }.GetNewClosure())
            }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [object] $Root
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $suffix = 'RevealToggle'
    $toggle = New-Object -TypeName System.Collections.ArrayList
    $found = New-Object -TypeName System.Collections.ArrayList

    # THE LOGICAL TREE, NOT THE VISUAL ONE. Nothing here has been rendered -
    # this runs under Pester with no desktop, and in the host before the window
    # is shown - so the visual tree of a templated control does not exist yet.
    # The tree XamlReader parsed does, and every named control is in it.
    #
    # BREADTH FIRST OVER A QUEUE RATHER THAN RECURSION, because a page is a
    # grid inside a panel inside a grid and PowerShell's recursion is not free.
    $queue = New-Object -TypeName System.Collections.Queue
    $queue.Enqueue($Root)

    while ($queue.Count -gt 0) {

        $node = $queue.Dequeue()

        # A RadioButton AND A CheckBox ARE BOTH ToggleButtons, which is why the
        # name decides and not the type.
        if ($node -is [System.Windows.Controls.Primitives.ToggleButton]) {

            $name = [string] $node.Name

            if ($name.Length -gt $suffix.Length -and
                $name.EndsWith($suffix, [System.StringComparison]::Ordinal)) {

                [void] $toggle.Add($node)
            }
        }

        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
            if ($child -is [System.Windows.DependencyObject]) { $queue.Enqueue($child) }
        }
    }

    foreach ($current in @($toggle | Sort-Object -Property { [string] $_.Name })) {

        $name = [string] $current.Name
        $base = $name.Substring(0, $name.Length - $suffix.Length)

        $password = $Root.FindName(('{0}Box' -f $base))
        $reveal = $Root.FindName(('{0}RevealBox' -f $base))

        if ($null -eq $password -or $null -eq $reveal) { continue }

        [void] $found.Add([pscustomobject] @{
                Toggle   = $current
                Password = $password
                Reveal   = $reveal
            })
    }

    return [pscustomobject[]] @($found)
}

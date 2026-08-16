function New-HDTWizardHost {
    <#
        .SYNOPSIS
            The real IWizardHost: loads XAML with XamlReader and shows the
            window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY THIN.
            HDT's only exception to TDD is a thin adapter over
            something that cannot be faked - here WPF itself - and THE PRICE OF
            THAT EXEMPTION IS THAT THE ADAPTER MUST HAVE NOTHING IN IT WORTH
            TESTING. That is a condition, not a description, and this file
            stopped meeting it once: it read the network, decided which named
            boxes were present, decided what belonged in each, and swallowed
            every failure. The first time it was ever really executed, it
            crashed - on a bench, in WinPE, which is exactly where an untested
            adapter's bugs get found.

            SO THE DECISIONS LEFT. Get-HDTWizardField works out what every box
            should say and is unit tested against fakes; Show-HDTWizard owns
            what an answer means and is unit tested against
            New-HDTFakeWizardHost. What is left here is load the markup, set
            text by name, attach handlers by name, show it - and that is what
            the exemption was written for.

            WPF IN WinPE IS NOT A GUESS. friendsOfMDT/PSD ships
            Scripts/PSDWizard.xaml and loads it exactly this way inside WinPE
            (PSDWizardNew.psm1), which is the proof that PresentationFramework
            is usable there. What makes it possible is WinPE-NetFx, one of the
            six required components Get-HDTBootImageComponent always injects -
            so no boot image change is needed to show a window.

            XamlReader::Load PARSES MARKUP ONLY. There is no compiler in WinPE,
            so the window carries no x:Class and no code-behind; handlers are
            attached here, by name, after the tree exists. Every name this file
            reaches for must exist in a shipped window, and
            tests/contract/WinPeUiStack.Contract.Tests.ps1 asserts that - a name
            nothing answers to is a control that silently does nothing on the
            one machine nobody can debug.

            THE DEFAULT ANSWER IS EMPTY, NOT 'Cancel'. A window closed with the
            X never runs any handler, so this returns what it was given -
            nothing - and Show-HDTWizard is what turns that into a Cancel. The
            adapter does not get to make that decision, because then two places
            would have an opinion about what a dismissed window means.

        .OUTPUTS
            A PSCustomObject with a Show(xaml, title, field) method returning
            'Next', 'Cancel', 'CommandPrompt', or an empty string.

        .EXAMPLE
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWizard.xaml' -WizardHost (New-HDTWizardHost)

        .EXAMPLE
            $field = Get-HDTWizardField -NetworkConfiguration (Get-HDTNetworkConfiguration)
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWelcome.xaml' -Field $field

            The Welcome screen with the lease the machine actually got in it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Show is where a window appears, and it is a method.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Answer = ''
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        param([string] $Xaml, [string] $Title, [object[]] $Field)

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $window.Title = $Title

        $this.Answer = ''

        # THE HOST, CAPTURED BY NAME. Inside an Add_Click handler $this is the
        # BUTTON that raised the event, not this object - and the enclosing
        # function's $service is not in scope inside a ScriptMethod at all, so
        # the handlers below were closing over a variable that did not exist.
        # Under StrictMode that throws, which is exactly what it did the first
        # time this adapter was ever really run.
        #
        # W1 did not catch it because W1's WinPE probe loads the XAML itself to
        # answer "does WPF render here"; the desktop tool is the first thing to
        # go through this host end to end. An adapter is exempt from unit tests
        # (CLAUDE.md rule 1) precisely because it is thin - so the first real
        # execution IS its test, and this is what that test found.
        $wizardHost = $this

        # WHAT GOES IN THE BOXES WAS DECIDED SOMEWHERE ELSE. Get-HDTWizardField
        # works it out - the lease, the share, the account - and this applies it
        # by name and interprets none of it. That is what put this adapter back
        # inside its own TDD exemption: the exemption is conditional on being
        # branch-free, and the version that read the network here was not.
        #
        # A NAME NOTHING ANSWERS TO IS SKIPPED, because the same host shows
        # every page and no page has all the controls.
        foreach ($current in @($Field)) {
            $control = $window.FindName([string] $current.Name)
            if ($null -ne $control) { $control.Text = [string] $current.Text }
        }

        # DRAG BY THE BANNER. WindowStyle=None removes the title bar - which is
        # right for WinPE, where an X is a third way out of a deployment wizard -
        # but it also removes the thing you grab to move the window. A banner
        # that answers DragMove gives that back without giving back the X.
        #
        # OPTIONAL BY DESIGN: a page with no HDTDragBanner simply cannot be
        # moved, which is fine on a machine with nothing else on screen.
        $banner = $window.FindName('HDTDragBanner')
        if ($null -ne $banner) {
            $banner.Add_MouseLeftButtonDown({
                    # DragMove throws unless the primary button is genuinely
                    # down, and a stray synthetic event would otherwise take the
                    # whole wizard down with it.
                    if ($_.ButtonState -eq 'Pressed') { $window.DragMove() }
                }.GetNewClosure())
        }

        # THE BUTTON MAP, and it is the whole of what this host decides: which
        # named control reports which answer. Show-HDTWizard owns what those
        # answers MEAN, including that anything else is a Cancel - so a page
        # missing a button simply cannot produce that answer, rather than
        # producing a different one.
        foreach ($pair in @(
                @{ Name = 'HDTNextButton'; Answer = 'Next' },
                @{ Name = 'HDTCancelButton'; Answer = 'Cancel' },
                @{ Name = 'HDTOpenCmdButton'; Answer = 'CommandPrompt' })) {

            $button = $window.FindName([string] $pair.Name)
            if ($null -eq $button) { continue }

            $answer = [string] $pair.Answer

            # GetNewClosure snapshots $answer per iteration; without it every
            # handler would report whatever the loop variable held last.
            $button.Add_Click({
                    $wizardHost.Answer = $answer
                    $window.Close()
                }.GetNewClosure())
        }

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}

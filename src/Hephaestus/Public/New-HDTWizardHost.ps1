function New-HDTWizardHost {
    <#
        .SYNOPSIS
            The real IWizardHost: loads XAML with XamlReader and shows the
            window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY
            BRANCH-FREE. CLAUDE.md rule 1's only exception to TDD is a thin
            adapter over something that cannot be faked - here WPF itself - and
            the price of that exception is that there is nothing in it worth
            testing. Every decision the wizard makes lives in Show-HDTWizard,
            which is asserted against New-HDTFakeWizardHost.

            WPF IN WinPE IS NOT A GUESS. friendsOfMDT/PSD ships
            Scripts/PSDWizard.xaml and loads it exactly this way inside WinPE
            (PSDWizardNew.psm1), which is the proof that PresentationFramework
            is usable there. What makes it possible is WinPE-NetFx, one of the
            six required components Get-HDTBootImageComponent always injects -
            so no boot image change is needed to show a window.

            XamlReader::Load PARSES MARKUP ONLY. There is no compiler in WinPE,
            so the window carries no x:Class and no code-behind; handlers are
            attached here, by name, after the tree exists. HDTNextButton and
            HDTCancelButton are the two names the markup promises and
            tests/unit/Show-HDTWizard.Tests.ps1 asserts.

            THE DEFAULT ANSWER IS EMPTY, NOT 'Cancel'. A window closed with the
            X never runs either handler, so this returns what it was given -
            nothing - and Show-HDTWizard is what turns that into a Cancel. The
            adapter does not get to make that decision, because then two places
            would have an opinion about what a dismissed window means.

        .OUTPUTS
            A PSCustomObject with a Show(xaml, title) method returning 'Next',
            'Cancel', or an empty string.

        .EXAMPLE
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWizard.xaml' -WizardHost (New-HDTWizardHost)
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
        param([string] $Xaml, [string] $Title)

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

        # THE LEASE, SHOWN RATHER THAN GUESSED. Under DHCP the address boxes
        # are read-only and display what the machine actually got, so a
        # technician can see whether the network came up before deciding to
        # override it. Empty boxes under "obtain automatically" say nothing.
        #
        # BEST EFFORT: a page with no address boxes, or a machine with no
        # lease, simply leaves them blank. Nothing here may stop a wizard from
        # opening - a network read is diagnosis, not a precondition.
        try {
            $addressBox = $window.FindName('HDTIpAddressBox')
            if ($null -ne $addressBox) {
                $network = Get-HDTNetworkConfiguration

                $addressBox.Text = [string] $network.IPAddress

                foreach ($pair in @(
                        @{ Name = 'HDTSubnetMaskBox'; Value = [string] $network.SubnetMask },
                        @{ Name = 'HDTGatewayBox'; Value = [string] $network.Gateway },
                        @{ Name = 'HDTDnsBox'; Value = [string] $network.DnsServerText })) {

                    $box = $window.FindName([string] $pair.Name)
                    if ($null -ne $box) { $box.Text = [string] $pair.Value }
                }
            }
        } catch {
            $null = $_
        }

        $next = $window.FindName('HDTNextButton')
        $cancel = $window.FindName('HDTCancelButton')

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

        $next.Add_Click({
                $wizardHost.Answer = 'Next'
                $window.DialogResult = $true
                $window.Close()
            }.GetNewClosure())

        $cancel.Add_Click({
                $wizardHost.Answer = 'Cancel'
                $window.DialogResult = $false
                $window.Close()
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}

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

        $next = $window.FindName('HDTNextButton')
        $cancel = $window.FindName('HDTCancelButton')

        $next.Add_Click({
                $service.Answer = 'Next'
                $window.DialogResult = $true
                $window.Close()
            }.GetNewClosure())

        $cancel.Add_Click({
                $service.Answer = 'Cancel'
                $window.DialogResult = $false
                $window.Close()
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}

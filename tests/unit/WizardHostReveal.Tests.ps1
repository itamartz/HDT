# The password eye, wired by New-HDTWizardHost.Apply against the real pages.
#
# THE ADAPTER IS TDD-EXEMPT ONLY WHILE IT IS THIN, and this part of it stopped
# being thin twice. It hardcoded three control names, so a page could carry one
# eye; and while the eye was ON it left PasswordBox.Password holding the value
# from before the reveal - which is the value $harvest collects and the value
# the validator judges. A technician who typed a password with the eye open and
# pressed Next shipped a DIFFERENT password to the one on the screen in front
# of them, silently, on the local Administrator account of every machine.
#
# APPLY RUNS WITH NO DESKTOP. WPF builds and raises events off a retained visual
# tree; ShowDialog is the only thing that needs a window station, and nothing
# here calls it. So the wiring is testable, and being untestable was never the
# reason it had no test.
#
# IT PRESSES THE REAL PAGES, NOT A FIXTURE. The trap the loop replaces is a
# closure that captures the LAST pair for every handler, and a page with one
# pair cannot show it - AdminPassword, with two, is the only proof there is.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # A PAGE, APPLIED. The same two calls Show-HDTWizardShell makes for every
    # page it swaps in - load the markup into its own name scope, then hand the
    # root to the host.
    function New-HDTTestAppliedPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Parses markup into an in-memory tree; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [string] $Name)

        $path = [System.IO.Path]::Combine(
            $script:repoRoot, 'src', 'Hephaestus', 'Templates', 'Wizard', $Name)

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList (
            [xml] ([System.IO.File]::ReadAllText($path)))

        $root = [System.Windows.Markup.XamlReader]::Load($reader)

        (New-HDTWizardHost).Apply($root, @(), @())

        return $root
    }

    $script:visible = [System.Windows.Visibility]::Visible
    $script:collapsed = [System.Windows.Visibility]::Collapsed
}

Describe 'the administrator password page, with an eye on each box' {

    BeforeEach {
        $script:root = New-HDTTestAppliedPage -Name 'AdminPassword.xaml'

        $script:passwordBox = $script:root.FindName('HDTAdminPasswordBox')
        $script:passwordReveal = $script:root.FindName('HDTAdminPasswordRevealBox')
        $script:passwordToggle = $script:root.FindName('HDTAdminPasswordRevealToggle')

        $script:confirmBox = $script:root.FindName('HDTAdminPasswordConfirmBox')
        $script:confirmReveal = $script:root.FindName('HDTAdminPasswordConfirmRevealBox')
        $script:confirmToggle = $script:root.FindName('HDTAdminPasswordConfirmRevealToggle')
    }

    It 'shows the dots and hides the reveal box until somebody asks' {
        $script:passwordBox.Visibility | Should -Be $script:visible
        $script:passwordReveal.Visibility | Should -Be $script:collapsed
        $script:passwordToggle.IsChecked | Should -Not -BeTrue
    }

    It 'swaps the first box when the first eye is pressed' {
        $script:passwordBox.Password = 'Sekret1!'
        $script:passwordToggle.IsChecked = $true

        $script:passwordBox.Visibility | Should -Be $script:collapsed
        $script:passwordReveal.Visibility | Should -Be $script:visible
        $script:passwordReveal.Text | Should -Be 'Sekret1!'
    }

    It 'leaves the confirmation box alone when the first eye is pressed' {
        # THE CLOSURE TRAP, ASSERTED. A handler that closed over the loop
        # variable rather than its own pair would reveal the LAST pair whichever
        # eye was pressed - and on a one-pair page that is invisible.
        $script:passwordToggle.IsChecked = $true

        $script:confirmBox.Visibility | Should -Be $script:visible
        $script:confirmReveal.Visibility | Should -Be $script:collapsed
    }

    It 'swaps the second box when the second eye is pressed' {
        $script:confirmBox.Password = 'Sekret1!'
        $script:confirmToggle.IsChecked = $true

        $script:confirmBox.Visibility | Should -Be $script:collapsed
        $script:confirmReveal.Visibility | Should -Be $script:visible
        $script:confirmReveal.Text | Should -Be 'Sekret1!'
    }

    It 'leaves the first box alone when the second eye is pressed' {
        $script:confirmToggle.IsChecked = $true

        $script:passwordBox.Visibility | Should -Be $script:visible
        $script:passwordReveal.Visibility | Should -Be $script:collapsed
    }

    It 'keeps the password box holding what was typed while the eye is open' {
        # THE DEFECT THIS FILE WAS WRITTEN FOR. $harvest reads
        # HDTAdminPasswordBox.Password - the name the page's collect
        # declaration gives - and the validator watches PasswordChanged on the
        # same control. Neither knows the reveal box exists, so a value that
        # lives only there is a value that never leaves the screen.
        $script:passwordToggle.IsChecked = $true
        $script:passwordReveal.Text = 'TypedWithTheEyeOn1!'

        $script:passwordBox.Password | Should -Be 'TypedWithTheEyeOn1!'
    }

    It 'keeps the confirmation box holding what was typed while its eye is open' {
        $script:confirmToggle.IsChecked = $true
        $script:confirmReveal.Text = 'TypedWithTheEyeOn1!'

        $script:confirmBox.Password | Should -Be 'TypedWithTheEyeOn1!'
    }

    It 'raises PasswordChanged so the validator judges what is on the screen' {
        # THE VALIDATOR SUBSCRIBES TO PasswordChanged, so pushing the value back
        # is not only about harvest: it is what makes Next open and close while
        # a technician types with the eye on.
        $script:heard = 0
        $script:passwordBox.Add_PasswordChanged({ $script:heard++ })

        $script:passwordToggle.IsChecked = $true
        $script:passwordReveal.Text = 'Sekret1!'

        $script:heard | Should -BeGreaterThan 0
    }

    It 'terminates when the eye is opened over a box that already has a value' {
        # Checked writes Reveal.Text from Password, which raises TextChanged,
        # which writes Password back. Password does not raise TextChanged, so
        # the second write ends it - but a page that hung here would hang in
        # WinPE with no way out, so it is asserted rather than reasoned about.
        $script:passwordBox.Password = 'Sekret1!'
        $script:passwordToggle.IsChecked = $true

        $script:passwordBox.Password | Should -Be 'Sekret1!'
        $script:passwordReveal.Text | Should -Be 'Sekret1!'
    }

    It 'gives what was typed while revealed back to the password box when the eye closes' {
        $script:passwordToggle.IsChecked = $true
        $script:passwordReveal.Text = 'Sekret1!'
        $script:passwordToggle.IsChecked = $false

        $script:passwordBox.Visibility | Should -Be $script:visible
        $script:passwordReveal.Visibility | Should -Be $script:collapsed
        $script:passwordBox.Password | Should -Be 'Sekret1!'
    }

    It 'flips each tooltip on its own toggle' {
        $script:passwordToggle.ToolTip | Should -Be 'Show the password'
        $script:confirmToggle.ToolTip | Should -Be 'Show the password'

        $script:passwordToggle.IsChecked = $true

        $script:passwordToggle.ToolTip | Should -Be 'Hide the password'
        $script:confirmToggle.ToolTip | Should -Be 'Show the password'

        $script:passwordToggle.IsChecked = $false

        $script:passwordToggle.ToolTip | Should -Be 'Show the password'
    }
}

Describe 'the computer details page, which has one eye and had the only one' {

    BeforeAll {
        $script:detailRoot = New-HDTTestAppliedPage -Name 'ComputerDetail.xaml'
    }

    It 'still swaps the domain join password box' {
        $toggle = $script:detailRoot.FindName('HDTPasswordRevealToggle')
        $box = $script:detailRoot.FindName('HDTPasswordBox')
        $reveal = $script:detailRoot.FindName('HDTPasswordRevealBox')

        $toggle.IsChecked = $true
        $reveal.Text = 'JoinPass1!'

        $box.Visibility | Should -Be $script:collapsed
        $reveal.Visibility | Should -Be $script:visible
        $box.Password | Should -Be 'JoinPass1!'
    }
}

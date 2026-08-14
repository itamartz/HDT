# THE UI STACK THAT SHIPS INTO THE BOOT IMAGE IS WPF, AND ONLY WPF.
#
# WHY THIS IS A CONTRACT. WinPE carries what WinPE-NetFx puts there. WPF -
# PresentationFramework, PresentationCore, WindowsBase - is present because that
# component is one of the six Get-HDTBootImageComponent always injects, and the
# PSD reference implementation proves the stack works there - NOTICE.md carries
# that attribution, and this file derives no code, so it must not name the
# project in a way that reads as one. System.Windows.Forms is NOT
# guaranteed by it. A window that mixes the two builds and unit-tests perfectly
# on a developer machine, where both are installed, and then fails on the one
# machine that matters - in WinPE, on a bench, with a technician watching.
#
# It is easy to reach for by accident: DoEvents is the reflex answer to "pump
# the message loop", and it is a WinForms call. The first draft of
# tests/e2e/payload/Start-HDTWizardProbe.ps1 used exactly that, and it would
# have failed in WinPE rather than on the machine that wrote it.
#
# SCOPED TO src/, DELIBERATELY. tests/helpers runs on the DEVELOPER'S machine -
# Save-HDTLabVmScreen turns Hyper-V thumbnail bytes into a PNG with
# System.Drawing and never goes near a boot image - so scanning the whole
# repository would fail on code that is already correct, and a contract that
# cries wolf is one somebody deletes.
#
# ANTI-VACUITY. "No file references X" is trivially true of no files, which is
# the shape SPIKES S9.15b records, so the scan asserts a floor on what it read
# before it asserts what it did not find.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src'

    $script:sourceFile = @(Get-ChildItem -LiteralPath $script:sourceRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.xaml')

    $script:scanned = @($script:sourceFile | ForEach-Object {
            [pscustomobject] @{
                Relative = $_.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                Text     = [System.IO.File]::ReadAllText($_.FullName)
            }
        })

    $script:totalLength = 0
    foreach ($row in $script:scanned) { $script:totalLength += $row.Text.Length }
}

Describe 'the WinPE UI stack' {

    Context 'it scanned something' {

        It 'found the engine source' {
            @($script:scanned).Count | Should -BeGreaterThan 50 -Because (
                'every assertion below is vacuously true of an empty scan')
        }

        It 'read a meaningful volume of it' {
            $script:totalLength | Should -BeGreaterThan 100000
        }

        It 'included the wizard window and its command' {
            @($script:scanned | Where-Object { $_.Relative -like '*HDTWizard.xaml' }).Count | Should -Be 1
            @($script:scanned | Where-Object { $_.Relative -like '*Show-HDTWizard.ps1' }).Count | Should -Be 1
        }
    }

    Context 'nothing that ships into the image reaches for WinForms' {

        It 'references no <_>' -ForEach @('System.Windows.Forms', 'WindowsFormsIntegration') {
            $name = $PSItem
            $offender = @($script:scanned |
                    Where-Object { $_.Text -match [regex]::Escape($name) } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                "{0} is not guaranteed by WinPE-NetFx, so a window using it works on a developer machine and fails in WinPE. Found in: {1}. Use the WPF dispatcher instead" -f
                    $name, (($offender -join ', ')))
        }

        It 'pumps the message loop with the WPF dispatcher, not DoEvents' {
            $offender = @($script:scanned |
                    Where-Object { $_.Text -match 'DoEvents' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'DoEvents is a WinForms call. Found in: {0}. Dispatcher.Invoke with DispatcherPriority::Background is the WPF equivalent' -f (($offender -join ', ')))
        }
    }

    Context 'the wizard window is loadable by XamlReader in WinPE' {

        It 'declares no code-behind class' {
            # There is no compiler in WinPE to build a partial class against, so
            # XamlReader::Load - which parses markup only - is the only way in.
            $window = @($script:scanned | Where-Object { $_.Relative -like '*HDTWizard.xaml' })[0]
            $document = [xml] $window.Text

            $document.DocumentElement.GetAttribute('Class', 'http://schemas.microsoft.com/winfx/2006/xaml') |
                Should -BeNullOrEmpty
        }

        It 'references no external resource dictionary' {
            # Another file that would have to reach the RAM disk intact. Every
            # increment that adds one has to add it to the image as well, and
            # this is where that gets noticed.
            $window = @($script:scanned | Where-Object { $_.Relative -like '*HDTWizard.xaml' })[0]

            $window.Text | Should -Not -Match 'ResourceDictionary\s+Source='
        }
    }
}

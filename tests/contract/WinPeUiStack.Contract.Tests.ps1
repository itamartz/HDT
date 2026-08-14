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
    # SCOPED TO THE ENGINE, NOT ALL OF src. src\HDT.Console is a DESKTOP app -
    # it never enters a boot image, so WinPE's constraints do not apply to it
    # and it has no Next/Cancel buttons to name. Scanning it made this contract
    # fail on a perfectly correct file belonging to another workstream, which is
    # exactly how a contract earns its own deletion.
    $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

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

    Context 'every wizard window is loadable by XamlReader in WinPE' {

        # ITERATED, NOT NAMED. The first version of this contract checked
        # HDTWizard.xaml by name, so the second page - HDTWizardCredential.xaml
        # - would have escaped every assertion below simply by being new. Each
        # increment of the WPF-first direction adds a page; none of them may opt
        # out of the rules by existing.

        BeforeAll {
            $script:window = @($script:scanned | Where-Object { $_.Relative -like '*.xaml' })
        }

        It 'found at least one window' {
            @($script:window).Count | Should -BeGreaterThan 0 -Because (
                'the assertions below are vacuous with nothing to check')
        }

        It 'declares no code-behind class in any window' {
            # There is no compiler in WinPE to build a partial class against, so
            # XamlReader::Load - which parses markup only - is the only way in.
            $offender = @()
            foreach ($row in $script:window) {
                $document = [xml] $row.Text
                if (-not [string]::IsNullOrEmpty($document.DocumentElement.GetAttribute('Class', 'http://schemas.microsoft.com/winfx/2006/xaml'))) {
                    $offender += $row.Relative
                }
            }

            @($offender).Count | Should -Be 0 -Because ('code-behind in: {0}' -f ($offender -join ', '))
        }

        It 'references no external resource dictionary in any window' {
            # Another file that would have to reach the RAM disk intact. Every
            # increment that adds one has to add it to the image as well, and
            # this is where that gets noticed.
            $offender = @($script:window |
                    Where-Object { $_.Text -match 'ResourceDictionary\s+Source=' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because ('external resources in: {0}' -f ($offender -join ', '))
        }

        It 'parses as XML' {
            foreach ($row in $script:window) {
                { [xml] $row.Text } | Should -Not -Throw -Because $row.Relative
            }
        }

        It 'names its buttons so the backend can find them' {
            # FindName is how handlers are attached with no code-behind, so a
            # page whose buttons are anonymous cannot be wired at all.
            foreach ($row in $script:window) {
                $row.Text | Should -BeLike '*HDTNextButton*' -Because $row.Relative
                $row.Text | Should -BeLike '*HDTCancelButton*' -Because $row.Relative
            }
        }
    }

    Context 'every name the engine reaches for is a name a window answers to' {

        # THE FAILURE THIS CATCHES, AND WHY IT IS HERE RATHER THAN IN A UNIT
        # TEST. New-HDTWizardHost is exempt from TDD as a thin WPF adapter
        # (CLAUDE.md rule 1), so nothing executes its FindName calls until a
        # machine in WinPE does. FindName does not throw on a name nothing
        # answers to - it returns null - so a renamed control does not fail, it
        # SILENTLY DOES NOTHING, on the one machine with no debugger attached.
        #
        # Comparing the two sides of that name is the part that needs no display,
        # so it is the part that can be automated.

        BeforeAll {
            $script:declaredName = @($script:scanned |
                    Where-Object { $_.Relative -like '*.xaml' } |
                    ForEach-Object {
                        [regex]::Matches($_.Text, 'x:Name\s*=\s*"([^"]+)"') |
                            ForEach-Object { $_.Groups[1].Value }
                        } |
                    Sort-Object -Unique)

            # Only HDT-prefixed names: a template part like HDTButtonSurface is
            # declared inside a ControlTemplate and is not addressable from the
            # window, but everything the engine looks up is.
            $script:requestedName = @($script:scanned |
                    Where-Object { $_.Relative -like '*.ps1' } |
                    ForEach-Object {
                        $relative = $_.Relative
                        [regex]::Matches($_.Text, "FindName\(\s*'(HDT[A-Za-z0-9]+)'\s*\)") |
                            ForEach-Object {
                                [pscustomobject] @{ Name = $_.Groups[1].Value; Relative = $relative }
                            }
                        })
        }

        It 'found the names on both sides' {
            @($script:declaredName).Count | Should -BeGreaterThan 5 -Because (
                'the assertion below is vacuous with nothing declared')
            @($script:requestedName).Count | Should -BeGreaterThan 0 -Because (
                'the assertion below is vacuous with nothing requested')
        }

        It 'looks up no control that no window declares' {
            $offender = @($script:requestedName |
                    Where-Object { $script:declaredName -notcontains $_.Name } |
                    ForEach-Object { '{0} ({1})' -f $_.Name, $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'FindName returns null rather than throwing, so this is a control that silently does nothing in WinPE. Found: {0}' -f
                    ($offender -join ', '))
        }
    }
}

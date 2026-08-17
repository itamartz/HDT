# dism.exe's progress meter, read back as a number.
#
# DESIGN 11.1's progress comes from the log the engine already writes, and until
# now the longest step in a deployment - the apply - wrote one line when it
# started and one when it finished. dism prints a percentage as it works;
# Expand-WindowsImage does not (its progress goes to PowerShell's progress
# STREAM, which nothing in WinPE is reading), which is why the adapter runs the
# tool MDT ran.
#
# THE PARSER IS WHERE THE LOGIC LIVES, because the adapter that runs dism is not
# unit tested (CLAUDE.md rule 1) and so must stay branch-free. It hands each
# line here.
#
# EVERY LINE IN THE FIXTURE IS REAL. tests/fixtures/image/dism-apply-image-output.txt
# is a captured dism.exe /Apply-Image run on this machine - the ADK winpe.wim
# applied to a scratch directory - not a transcript typed from memory. The
# meter's shape is not obvious: it pads with spaces at 1%, with '=' at 85%, and
# at 100% the number is embedded in a solid bar with no space around it at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:fixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-apply-image-output.txt'
    $script:fixture = [string[]] [System.IO.File]::ReadAllLines($script:fixturePath)

    $script:parse = {
        param([string[]] $Line)

        return @(InModuleScope Hephaestus -Parameters @{ Line = $Line } {
                param($Line)

                foreach ($text in $Line) { ConvertFrom-HDTDismProgressLine -Line $text }
            })
    }
}

Describe 'ConvertFrom-HDTDismProgressLine' {

    Context 'the captured run' {

        It 'has a fixture to read' {
            $script:fixture.Count | Should -BeGreaterThan 100
        }

        It 'reads the first meter line as 1' {
            & $script:parse @('[                           1.0%                           ] ') |
                Should -Be 1
        }

        It 'reads a half-filled meter as its number' {
            & $script:parse @('[===========================85.0%=================         ] ') |
                Should -Be 85
        }

        It 'reads the solid bar at the end as 100' {
            # The one a naive regex misses: at 100% there is no space between the
            # '=' run and the number.
            & $script:parse @('[==========================100.0%==========================] ') |
                Should -Be 100
        }

        It 'ends the captured run at 100' {
            $percent = @(& $script:parse $script:fixture)

            $percent[-1] | Should -Be 100
        }

        It 'never goes backwards across the captured run' {
            $percent = @(& $script:parse $script:fixture)

            $previous = 0
            foreach ($value in $percent) {
                $value | Should -BeGreaterOrEqual $previous
                $previous = $value
            }
        }

        It 'reads a percentage from every meter line and from no other line' {
            $meter = @($script:fixture | Where-Object { $_ -match '%' })

            @(& $script:parse $script:fixture).Count | Should -Be $meter.Count
        }
    }

    Context 'lines that are not the meter' {

        It 'returns nothing for <Name>' -ForEach @(
            @{ Name = 'the banner'; Line = 'Deployment Image Servicing and Management tool' }
            @{ Name = 'the version'; Line = 'Version: 10.0.26100.8521' }
            @{ Name = 'the verb'; Line = 'Applying image' }
            @{ Name = 'the closing sentence'; Line = 'The operation completed successfully.' }
            @{ Name = 'an empty line'; Line = '' }
            @{ Name = 'a blank line'; Line = '   ' }
            @{ Name = 'an error'; Line = 'Error: 0x80070002' }
        ) {
            @(& $script:parse @($Line)) | Should -BeNullOrEmpty
        }

        It 'returns nothing for a percentage in prose' {
            # A DISM error sentence that happens to carry a number is not a
            # progress report, and a bar that jumped to 50% because of one would
            # be lying at the moment somebody was reading it hardest.
            @(& $script:parse @('The image is 50% larger than the volume.')) | Should -BeNullOrEmpty
        }

        It 'returns nothing for a null line' {
            @(& $script:parse @($null)) | Should -BeNullOrEmpty
        }
    }

    Context 'the number itself' {

        It 'floors a fraction rather than rounding it' {
            # 99.9% is not 100%: the number a technician reads must never say
            # finished before the tool has.
            & $script:parse @('[=========================99.9%============================] ') | Should -Be 99
        }

        It 'returns an integer' {
            (& $script:parse @('[=                          2.0%                           ] '))[0] |
                Should -BeOfType ([int])
        }

        It 'reads a meter with no fractional part' {
            & $script:parse @('[==============             50%                            ] ') | Should -Be 50
        }
    }
}

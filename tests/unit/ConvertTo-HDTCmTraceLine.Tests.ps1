# DESIGN 4.4.2's second format: one physical CMTrace line per log call, so an
# administrator's existing CMTrace/OneTrace workflow reads an HDT deployment on
# day one.
#
# The function is pure - timestamp, component, thread and file in, one string out
# - so every assertion here is exact rather than approximate.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:stamp = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)
}

Describe 'ConvertTo-HDTCmTraceLine' {

    It 'wraps the message in the LOG marker' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1 to W:\ in 95s' -Component 'ImageService' `
                -Severity 'Info' -Timestamp $Stamp -ThreadId 4820 -File 'Invoke-HDTApplyImage.ps1'
        }

        # StartsWith, not -BeLike: '[' opens a character class in a wildcard
        # pattern, and this format is made of square brackets.
        $line.StartsWith('<![LOG[Applied index 1 to W:\ in 95s]LOG]!><') | Should -BeTrue
    }

    It 'emits the exact DESIGN 4.4.2 line' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1' -Component 'ImageService' `
                -Severity 'Info' -Timestamp $Stamp -ThreadId 4820 -File 'Invoke-HDTApplyImage.ps1'
        }

        $line | Should -BeExactly ('<![LOG[Applied index 1]LOG]!><time="00:11:02.481+000" date="08-13-2026" ' +
            'component="ImageService" context="" type="1" thread="4820" file="Invoke-HDTApplyImage.ps1">')
    }

    It 'formats the time as HH:mm:ss.fff+000' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike '*time="00:11:02.481+000"*'
    }

    It 'formats the date as MM-dd-yyyy' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike '*date="08-13-2026"*'
    }

    It 'maps <Severity> to type <Type>' -ForEach @(
        @{ Severity = 'Info'; Type = '1' }
        @{ Severity = 'Debug'; Type = '1' }
        @{ Severity = 'Warning'; Type = '2' }
        @{ Severity = 'Error'; Type = '3' }
    ) {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp; Severity = $Severity } {
            param($Stamp, $Severity)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity $Severity `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike ('*type="{0}"*' -f $Type)
    }

    It 'emits exactly one physical line for a multi-line message' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message "first`r`nsecond`nthird`rfourth" -Component 'Engine' `
                -Severity 'Error' -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        @($line -split "`n").Count | Should -Be 1
        $line | Should -Not -Match "`r"
    }

    It 'replaces a CRLF in the message with a space' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message "first`r`nsecond" -Component 'Engine' `
                -Severity 'Error' -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line.StartsWith('<![LOG[first second]LOG]!>') | Should -BeTrue
    }

    It 'emits the whole line in the invariant culture' {
        # A German culture renders a dotted date and a comma decimal separator. A
        # CMTrace parser expects neither, and the engine ships to machines whose
        # culture nobody chose.
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object -TypeName System.Globalization.CultureInfo -ArgumentList 'de-DE'

            $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
                param($Stamp)
                ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                    -Timestamp $Stamp -ThreadId 4820 -File 'a.ps1'
            }

            $line | Should -BeExactly ('<![LOG[x]LOG]!><time="00:11:02.481+000" date="08-13-2026" ' +
                'component="Engine" context="" type="1" thread="4820" file="a.ps1">')
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'includes the thread id it was given' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 12345 -File 'a.ps1'
        }

        $line | Should -BeLike '*thread="12345"*'
    }

    It 'includes the file it was given' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'Update-VendorBios.ps1'
        }

        $line | Should -BeLike '*file="Update-VendorBios.ps1">'
    }

    It 'leaves context empty' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike '*context=""*'
    }

    It 'is private' {
        Get-Command -Name ConvertTo-HDTCmTraceLine -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

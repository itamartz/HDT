# A driver's date, as a screen should show it.
#
# THE COLUMN SORTED WRONG AND NOBODY NOTICED. The console's driver grid binds
# strings, so clicking the Date header sorts TEXT - and as text '11/28/2024'
# comes before '06/11/2025'. The column put a 2024 driver above a 2025 one while
# claiming to say which was newer, which is the one question it exists to answer.
#
# AND IT COULD NOT BE READ. DriverVer is specified MM/DD/YYYY whatever the
# vendor's country, so an .inf writes 06/11/2025 for the 11th of June and every
# administrator outside the United States reads the 6th of November.
#
# yyyy-MM-dd FIXES BOTH AT ONCE and needs no converter, no comparer and no
# column template.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:show = {
        param([string] $Date)

        $module = Get-Module -Name Hephaestus
        return & $module { param($D) Format-HDTDriverDate -Date $D } $Date
    }

    $script:read = {
        param([string] $Date)

        $module = Get-Module -Name Hephaestus
        return & $module { param($D) ConvertTo-HDTDriverDate -Value $D } $Date
    }
}

Describe 'Format-HDTDriverDate' {

    It 'renders the .inf''s own American form as ISO' {
        & $script:show '11/28/2024' | Should -BeExactly '2024-11-28'
    }

    It 'reads a single-digit month and day' {
        & $script:show '6/1/2025' | Should -BeExactly '2025-06-01'
    }

    It 'sorts in the order it claims, which the raw form did not' {
        # THE ASSERTION THE WHOLE CHANGE IS FOR. Sorted as text, these are the
        # two dates that were in the wrong order on screen.
        $sorted = @('11/28/2024', '06/11/2025' | ForEach-Object { & $script:show $_ } | Sort-Object)

        $sorted[0] | Should -BeExactly '2024-11-28'
        $sorted[1] | Should -BeExactly '2025-06-11'

        # And the raw strings sort the other way round, which is the defect.
        $raw = @('11/28/2024', '06/11/2025' | Sort-Object)
        $raw[0] | Should -BeExactly '06/11/2025'
    }

    It 'leaves a date it cannot read exactly as the file wrote it' {
        # An odd-looking date an administrator can compare against the .inf beats
        # an empty cell, which says the field is missing when it is not.
        & $script:show 'NT_x86' | Should -BeExactly 'NT_x86'
    }

    It 'answers empty for an .inf that carries no DriverVer at all' {
        & $script:show '' | Should -BeExactly ''
    }
}

Describe 'ConvertTo-HDTDriverDate and the forms vendors ship' {

    It 'reads the specified MM/dd/yyyy form as the eleventh of June' {
        # THE TRAP THIS PINS. Read with a British machine's culture, 06/11/2025
        # is the 6th of November - and every driver's date would be wrong for
        # eleven days of each month and right for the rest.
        (& $script:read '06/11/2025').Month | Should -Be 6
        (& $script:read '06/11/2025').Day | Should -Be 11
    }

    It 'also reads an ISO date, because a four-digit year cannot be ambiguous' {
        (& $script:read '2025-06-11').Month | Should -Be 6
        (& $script:read '2025/06/11').Day | Should -Be 11
    }

    It 'still sorts an unreadable date last rather than first' {
        # Last, not first: an unreadable date is not evidence of being newer,
        # and this is the final tie-break in the PnP match.
        & $script:read 'NT_x86' | Should -Be ([datetime]::MinValue)
    }
}

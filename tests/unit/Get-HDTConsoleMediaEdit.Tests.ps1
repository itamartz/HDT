# TYPING INTO A MEDIA ROW, AND THE COMMAND THAT TAKES IT.
#
# Get-HDTConsoleApplicationEdit exists because four of an application's rows
# are not strings. A media row has exactly ONE that is not: Enabled shows as
# 'yes' or 'no - Update Media Content refuses it while it is off' (the
# explanation belongs in the box's -Hint, not in what gets typed back), and
# Set-HDTMedia takes it as [bool]. description, selectionProfile and output are
# plain strings and the capital-letter rule already names their parameter -
# this file exists for the one row that is not, and proves the other three
# fall through to the same rule Application's rows do.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Get-HDTTestEdit {
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Property, [string] $Text)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ P = $Property; T = $Text } {
            param($P, $T)
            Get-HDTConsoleMediaEdit -Property $P -Text $T
        }
    }
}

Describe 'Get-HDTConsoleMediaEdit' {

    Context 'the rows that are plain strings' {

        It 'names the parameter for a key that is only a capital away' -ForEach @(
            @{ Property = 'description'; Parameter = 'Description' }
            @{ Property = 'output'; Parameter = 'Output' }
        ) {
            (Get-HDTTestEdit -Property $Property -Text 'anything').Parameter | Should -BeExactly $Parameter
        }

        It 'names SelectionProfile for selectionProfile, camelCase and all' {
            # THE ONE KEY THAT IS NOT A SINGLE CAPITAL AWAY FROM ITS PARAMETER
            # BY ACCIDENT - selectionProfile is already camelCase in media.yaml,
            # so the capital-first-letter rule gets it right for the same reason
            # it gets 'description' right, not by coincidence.
            (Get-HDTTestEdit -Property 'selectionProfile' -Text 'hydration').Parameter | Should -BeExactly 'SelectionProfile'
        }

        It 'passes the text through as the value' {
            (Get-HDTTestEdit -Property 'description' -Text 'The bench disc.').Value | Should -BeExactly 'The bench disc.'
        }

        It 'echoes the value quoted, for the command the footer shows' {
            (Get-HDTTestEdit -Property 'output' -Text 'D:\HDT_HYDRA.iso').Text | Should -BeExactly "'D:\HDT_HYDRA.iso'"
        }
    }

    Context 'Enabled, the one row that is not a string' {

        It 'reads <_> as true' -ForEach @('yes', 'Yes', 'YES', 'true', 'True', '1') {
            $edit = Get-HDTTestEdit -Property 'enabled' -Text $_

            $edit.Parameter | Should -BeExactly 'Enabled'
            $edit.Value | Should -BeTrue
            $edit.Value | Should -BeOfType ([bool])
        }

        It 'reads <_> as false' -ForEach @('no', 'No', 'NO', 'false', 'False', '0') {
            (Get-HDTTestEdit -Property 'enabled' -Text $_).Value | Should -BeFalse
        }

        It 'echoes $true or $false, which is what -Enabled actually takes' {
            (Get-HDTTestEdit -Property 'enabled' -Text 'yes').Text | Should -BeExactly '$true'
            (Get-HDTTestEdit -Property 'enabled' -Text 'no').Text | Should -BeExactly '$false'
        }

        It 'trims surrounding space, because a box is typed into by hand' {
            (Get-HDTTestEdit -Property 'enabled' -Text '  yes  ').Value | Should -BeTrue
        }

        It 'refuses anything that is not yes or no' {
            { Get-HDTTestEdit -Property 'enabled' -Text 'maybe' } | Should -Throw -ExceptionType ([System.ArgumentException])
        }

        It 'names the box in its refusal, the way every other refusal here does' {
            { Get-HDTTestEdit -Property 'enabled' -Text 'maybe' } | Should -Throw '*Enabled*'
        }
    }
}

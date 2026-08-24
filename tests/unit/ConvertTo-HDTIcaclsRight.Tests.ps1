# The right name -> icacls permission mapping.
#
# IT IS A FUNCTION RATHER THAN A switch INSIDE THE ADAPTER because of hard rule
# 1: a thin adapter over an external tool is not unit tested, and must therefore
# stay branch-free. The branch has to live somewhere that IS tested, so it lives
# here and New-HDTFileSystem's GrantAccess calls it.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'ConvertTo-HDTIcaclsRight' {

    # (OI)(CI) IS WHAT MAKES A GRANT REACH THE FILES. Without the pair, a right
    # granted on a folder applies to the folder object and nothing inside it -
    # so the account can list the share root and open not one document in it.
    # docs/share-account.md grants both flags on every row for that reason.
    It 'maps <Name> to <Expected>' -ForEach @(
        @{ Name = 'Read'; Expected = '(OI)(CI)(RX)' }
        @{ Name = 'Modify'; Expected = '(OI)(CI)(M)' }
    ) {
        InModuleScope Hephaestus -Parameters @{ Name = $Name; Expected = $Expected } {
            ConvertTo-HDTIcaclsRight -Right $Name | Should -BeExactly $Expected
        }
    }

    It 'is case insensitive, because a caller types the word rather than a token' {
        InModuleScope Hephaestus {
            ConvertTo-HDTIcaclsRight -Right 'read' | Should -BeExactly '(OI)(CI)(RX)'
        }
    }

    # NO FullControl ROW, AND THAT IS THE POINT. Test-HDTShareAcl reports
    # FullControl anywhere as Critical - a deployment account holding it is the
    # exposure the checker exists to catch - so a command that could grant it
    # would be handing out the finding it later warns about.
    It 'refuses <Bad>, which is not a right this toolkit grants' -ForEach @(
        @{ Bad = 'FullControl' }
        @{ Bad = 'Write' }
        @{ Bad = 'rx' }
    ) {
        InModuleScope Hephaestus -Parameters @{ Bad = $Bad } {
            { ConvertTo-HDTIcaclsRight -Right $Bad } | Should -Throw
        }
    }
}

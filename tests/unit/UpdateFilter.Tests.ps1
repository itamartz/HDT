# The three pure decisions behind DESIGN 10.1's WindowsUpdate step: which KB
# number an update carries, whether an exclude pattern rules it out, and which
# of a search's results are in scope at all.
#
# THEY ARE THEIR OWN FUNCTIONS BECAUSE THIS IS WHERE THE STEP'S BEHAVIOUR IS
# ACTUALLY DECIDED. IUpdateSessionService.SearchUpdate is flat and unfiltered on
# purpose (08-01-02) - the adapter cannot be unit tested, so nothing that can be
# a decision is allowed to live in it. All three take values and return values:
# no service, no context, no log.
#
# NOTHING HERE INSTALLS, DOWNLOADS OR SEARCHES FOR ANYTHING. There is no agent
# in this file at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # THE PHASE'S REAL STAGING, not an invented shape: KB5121003 is the 2026-08
    # cumulative update for Windows 11 24H2 x64 and KB5120710 the matching
    # .NET 3.5/4.8.1 cumulative. KBArticleId carries the number WITHOUT the
    # prefix, which is what the agent returns.
    $script:newUpdate = {
        param([string] $Id, [string] $Title, [string[]] $Kb, [string[]] $Category)

        return [pscustomobject] @{
            UpdateId     = $Id
            Title        = $Title
            KBArticleId  = [string[]] @($Kb)
            Category     = [string[]] @($Category)
            IsDownloaded = $false
            EulaAccepted = $true
            SizeByte     = [long] 0
        }
    }

    $script:cu = & $script:newUpdate '11111111-1111-1111-1111-111111111111' `
        '2026-08 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5121003)' `
    @('5121003') @('Security Updates', 'Windows 11')

    $script:net = & $script:newUpdate '22222222-2222-2222-2222-222222222222' `
        '2026-08 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11 (KB5120710)' `
    @('5120710') @('Security Updates')

    $script:preview = & $script:newUpdate '33333333-3333-3333-3333-333333333333' `
        '2026-09 Preview Cumulative Update for Windows 11 (KB5122222)' `
    @('5122222') @('Update Rollups')
}

Describe 'Get-HDTUpdateKbNumber' {

    It 'returns KB-prefixed numbers from an update that carries bare ones' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            @(Get-HDTUpdateKbNumber -Update $Update) | Should -Be @('KB5121003')
        }
    }

    It 'leaves a number that already carries the prefix alone' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{ Title = 'x'; KBArticleId = [string[]] @('KB5121003') }

            @(Get-HDTUpdateKbNumber -Update $update) | Should -Be @('KB5121003')
        }
    }

    It 'uppercases a lowercase kb prefix' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{ Title = 'x'; KBArticleId = [string[]] @('kb5121003') }

            @(Get-HDTUpdateKbNumber -Update $update) | Should -Be @('KB5121003')
        }
    }

    It 'returns every KB an update carries, not only the first' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{ Title = 'x'; KBArticleId = [string[]] @('5121003', '5120710') }

            @(Get-HDTUpdateKbNumber -Update $update) | Should -Be @('KB5121003', 'KB5120710')
        }
    }

    It 'returns nothing for an update that carries none' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{ Title = 'A driver with no article'; KBArticleId = [string[]] @() }

            @(Get-HDTUpdateKbNumber -Update $update).Count | Should -Be 0
        }
    }

    # THE AGENT LEAVES KBArticleIDs EMPTY MORE OFTEN THAN ITS DOCUMENTATION
    # SUGGESTS, and the title almost always carries the number in brackets. A
    # log line that cannot name the KB is a log line an administrator cannot
    # search a support article with.
    It 'falls back to the KB number in the title when the agent reported none' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{
                Title       = '2026-08 Cumulative Update for Windows 11 (KB5121003)'
                KBArticleId = [string[]] @()
            }

            @(Get-HDTUpdateKbNumber -Update $update) | Should -Be @('KB5121003')
        }
    }
}

Describe 'Test-HDTUpdateExcluded' {

    It 'excludes by a wildcard on the title' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:preview } {
            param($Update)

            $decision = Test-HDTUpdateExcluded -Update $Update -Exclude @('*Preview*')

            $decision.Excluded | Should -BeTrue
        }
    }

    It 'excludes by an explicit KB number' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @('KB5121003')).Excluded | Should -BeTrue
        }
    }

    It 'excludes by an explicit KB number written without the prefix' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @('5121003')).Excluded | Should -BeTrue
        }
    }

    It 'matches a KB number case-insensitively' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @('kb5121003')).Excluded | Should -BeTrue
        }
    }

    It 'does not exclude an update a pattern does not match' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @('*Preview*', 'KB5001234')).Excluded | Should -BeFalse
        }
    }

    It 'does not exclude anything when the exclude list is empty' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @()).Excluded | Should -BeFalse
        }
    }

    It 'does not exclude anything when the exclude list is absent' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:cu } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update).Excluded | Should -BeFalse
        }
    }

    # THE LOG HAS TO SAY WHICH ONE. "excluded" answers nothing; "excluded by
    # *Preview*" tells an administrator which line of their own sequence to
    # change.
    It 'reports WHICH pattern excluded it' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:preview } {
            param($Update)

            $decision = Test-HDTUpdateExcluded -Update $Update -Exclude @('KB5001234', '*Preview*')

            $decision.Pattern | Should -BeExactly '*Preview*'
        }
    }

    # A BARE NUMBER IS A KB NUMBER, NOT A TITLE SUBSTRING. Reading '5121003' as
    # a title match would be harmless here and catastrophic for a number that
    # appears in a build string - it would exclude half a catalogue silently.
    It 'does not let a bare number match a title that merely contains it' {
        InModuleScope Hephaestus {
            $update = [pscustomobject] @{
                Title       = 'Update for Windows 11 build 5121003 (KB5999999)'
                KBArticleId = [string[]] @('5999999')
            }

            (Test-HDTUpdateExcluded -Update $update -Exclude @('5121003')).Excluded | Should -BeFalse
        }
    }

    It 'treats a pattern with no wildcard and no digits as a literal title match' {
        InModuleScope Hephaestus -Parameters @{ Update = $script:preview } {
            param($Update)

            (Test-HDTUpdateExcluded -Update $Update -Exclude @('nothing like it')).Excluded | Should -BeFalse

            $exact = [pscustomobject] @{ Title = 'Malicious Software Removal Tool'; KBArticleId = [string[]] @() }
            (Test-HDTUpdateExcluded -Update $exact -Exclude @('Malicious Software Removal Tool')).Excluded |
                Should -BeTrue
        }
    }
}

Describe 'Select-HDTApplicableUpdate' {

    It 'returns every update when no categories and no excludes are given' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu, $script:net, $script:preview) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update)

            $decided.Count | Should -Be 3
            @($decided | Where-Object { $_.Applicable }).Count | Should -Be 3
            $decided[0].Reason | Should -BeExactly 'no category filter'
        }
    }

    It 'keeps only updates in the named categories' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu, $script:net, $script:preview) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update -Category @('SecurityUpdates'))

            @($decided | Where-Object { $_.Applicable } | ForEach-Object { $_.Update.UpdateId }) |
                Should -Be @($Update[0].UpdateId, $Update[1].UpdateId)
        }
    }

    It 'matches a category case-insensitively' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update -Category @('securityupdates'))

            $decided[0].Applicable | Should -BeTrue
        }
    }

    # WUA REPORTS 'Security Updates'; DESIGN 10.1's YAML WRITES
    # 'SecurityUpdates'; MDT writes both. The comparison removes the spaces so
    # neither spelling is wrong.
    It 'matches a category whose name the agent spells with spaces' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu) } {
            param($Update)

            (@(Select-HDTApplicableUpdate -Update $Update -Category @('Security Updates')))[0].Applicable |
                Should -BeTrue
        }
    }

    It 'drops an excluded update even when its category matches' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu, $script:net) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update -Category @('SecurityUpdates') -Exclude @('KB5121003'))

            $decided[0].Applicable | Should -BeFalse
            $decided[0].Reason | Should -BeExactly 'excluded by KB5121003'
            $decided[1].Applicable | Should -BeTrue
        }
    }

    # IT NEVER SILENTLY DROPS ANYTHING. "0 updates applicable" is not a log an
    # administrator can act on; "KB5121003, excluded by *Preview*" is.
    It 'reports why each update was kept or dropped' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu, $script:preview) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update -Category @('SecurityUpdates'))

            $decided.Count | Should -Be 2
            foreach ($row in $decided) { $row.Reason | Should -Not -BeNullOrEmpty }

            $decided[0].Reason | Should -BeExactly 'category SecurityUpdates'
            $decided[1].Reason | Should -BeExactly 'no category matched'
        }
    }

    It 'preserves the order the search returned' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:preview, $script:net, $script:cu) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update)

            @($decided | ForEach-Object { $_.Update.UpdateId }) |
                Should -Be @($Update[0].UpdateId, $Update[1].UpdateId, $Update[2].UpdateId)
        }
    }

    It 'returns nothing, not a null, when everything was filtered out' {
        InModuleScope Hephaestus {
            $decided = @(Select-HDTApplicableUpdate -Update @())

            $decided.Count | Should -Be 0
        }
    }

    It 'reports an update that matched no category as skipped rather than failing' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:preview) } {
            param($Update)

            $decided = @(Select-HDTApplicableUpdate -Update $Update -Category @('SecurityUpdates'))

            $decided[0].Applicable | Should -BeFalse
            $decided[0].Reason | Should -BeExactly 'no category matched'
        }
    }

    # The done criterion of plan 08-01-03 task 2, written out: the phase's real
    # staging, both in SecurityUpdates, kept with a reason - and the same pair
    # dropped by name when the sequence excludes one.
    It 'keeps the two staged updates and drops the one an exclude names' {
        InModuleScope Hephaestus -Parameters @{ Update = @($script:cu, $script:net) } {
            param($Update)

            $kept = @(Select-HDTApplicableUpdate -Update $Update -Category @('SecurityUpdates'))
            @($kept | Where-Object { $_.Applicable }).Count | Should -Be 2

            $dropped = @(Select-HDTApplicableUpdate -Update $Update -Exclude @('KB5121003'))
            $dropped[0].Applicable | Should -BeFalse
            $dropped[0].Reason | Should -BeExactly 'excluded by KB5121003'
            $dropped[1].Applicable | Should -BeTrue
        }
    }
}

Describe 'Get-HDTUpdateResultName' {

    # DESIGN 10.1 ASKS FOR THE CODE AND WHAT IT MEANS. A log line reading
    # "result code 4" makes an administrator look up an enumeration before they
    # can read their own deployment; "result code 4 (failed)" does not.
    It 'names each of the agent operation result codes' {
        InModuleScope Hephaestus {
            Get-HDTUpdateResultName -ResultCode 0 | Should -BeExactly 'not started'
            Get-HDTUpdateResultName -ResultCode 1 | Should -BeExactly 'in progress'
            Get-HDTUpdateResultName -ResultCode 2 | Should -BeExactly 'succeeded'
            Get-HDTUpdateResultName -ResultCode 3 | Should -BeExactly 'succeeded with errors'
            Get-HDTUpdateResultName -ResultCode 4 | Should -BeExactly 'failed'
            Get-HDTUpdateResultName -ResultCode 5 | Should -BeExactly 'aborted'
        }
    }

    # A CODE NOBODY HAS SEEN IS STILL REPORTED. Returning an empty string would
    # produce "result code 9 ()" in the one line an administrator is relying on.
    It 'reports a code outside the set rather than returning nothing' {
        InModuleScope Hephaestus {
            Get-HDTUpdateResultName -ResultCode 9 | Should -BeLike '*9*'
        }
    }
}

# Which variables are secret, and what a writer may put in a file instead.
#
# THE DEFECT THAT BUILT THIS PAIR. A real run left the local administrator
# password in clear in four places at once - the run's HDT.jsonl, its CMTrace
# HDT.log, its state.json, and both of those again on the deployment share -
# while Gather\provenance.json, written from the same resolution seconds
# earlier, correctly said "(set, not shown)". One writer asked whether the
# variable was secret. Three did not, and each would have answered differently
# if it had.
#
# SO THE ANSWER MOVED INTO ONE PLACE AND THE WRITERS LOST THE CHOICE.
# Test-HDTSecretVariable classifies; Protect-HDTSecretValue substitutes. This
# file is about those two, and SecretRedaction.Contract.Tests.ps1 is about
# every writer being made to use them.
#
# NO REALISTIC PASSWORD IN THIS FILE. Every value below is an obviously
# synthetic marker, because a fixture that looks like a credential is a
# credential as far as the next person grepping the repository is concerned.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:module = Get-Module -Name 'Hephaestus'

    # Both are private, so they are reached the way every other private helper
    # is tested here - through the module's own scope rather than by exporting
    # them for the tests' convenience.
    $script:isSecret = {
        param([string] $Name)

        return & $script:module { param($N) Test-HDTSecretVariable -Name $N } $Name
    }

    $script:protect = {
        param([string] $Name, [object] $Value)

        return & $script:module { param($N, $V) Protect-HDTSecretValue -Name $N -Value $V } $Name $Value
    }
}

Describe 'Test-HDTSecretVariable' {

    # DRIVEN OFF THE MAP, NOT OFF A LIST WRITTEN TWICE (CLAUDE.md rule 8). A
    # test naming HDTAdminPassword passes for HDTAdminPassword and fails for
    # nobody after it. Every variable the map declares secret is asserted, so a
    # row added tomorrow is covered by this file today.
    It 'says yes to every variable Get-HDTVariableMap declares secret' {
        $declared = @(Get-HDTVariableMap | Where-Object { $_.IsSecret } | ForEach-Object { [string] $_.HDTName })

        # Non-vacuity: a column nothing sets would make the loop below assert
        # nothing at all.
        @($declared).Count | Should -BeGreaterThan 0

        $missed = @($declared | Where-Object { -not (& $script:isSecret $PSItem) })

        ($missed -join ', ') | Should -BeExactly ''
    }

    # THE PATTERN IS THE HALF THE MAP CANNOT COVER. A customer's rules.yaml can
    # set any HDT* name, and a variable HDT has never heard of is precisely the
    # one no declared list contains.
    It 'says yes to an undeclared name whose shape says it carries one' -ForEach @(
        'HDTJoinPassword', 'HDTApiSecret', 'HDTVpnCredential', 'HDTVaultPassphrase',
        'HDTUnlockPin', 'HDTGraphToken') {

        (Get-HDTVariableMap -Name $PSItem) | Should -BeNullOrEmpty -Because 'the point is that the map does not know this name'

        & $script:isSecret $PSItem | Should -BeTrue
    }

    # AND THE MAP IS THE HALF THE PATTERN CANNOT COVER. MDT's own name for the
    # administrator password is AdminPassword, which matches nothing above.
    It 'says yes to a declared secret through the map even when the name alone would not' {
        & $script:module { Test-HDTSecretVariable -Name 'HDTUserPassword' } | Should -BeTrue
    }

    # A CLASSIFIER THAT SAYS YES TO EVERYTHING REDACTS THE WHOLE LOG AND ANSWERS
    # NOTHING, which is the other way to get this wrong. These are the values a
    # deployment is diagnosed from.
    It 'says no to a variable that plainly is not one' -ForEach @(
        'HDTComputerName', 'HDTOrgName', 'HDTJoinDomain', 'HDTMake', 'HDTModel',
        'HDTDeployRoot', 'HDTOSVolume', 'HDTAssetTag', 'HDTProductName') {

        & $script:isSecret $PSItem | Should -BeFalse
    }

    It 'says no to an empty name rather than redacting on a caller with nothing to classify' {
        & $script:isSecret '' | Should -BeFalse
    }

    # The cache is built once per session; a second call must answer the same.
    It 'answers the same on a second call, which is the one the cache serves' {
        & $script:isSecret 'HDTAdminPassword' | Should -BeTrue
        & $script:isSecret 'HDTAdminPassword' | Should -BeTrue
        & $script:isSecret 'HDTComputerName' | Should -BeFalse
    }
}

Describe 'Protect-HDTSecretValue' {

    It 'returns an ordinary value untouched' {
        & $script:protect 'HDTComputerName' 'HDT-LAB-01' | Should -BeExactly 'HDT-LAB-01'
    }

    It 'replaces a secret value with the words the provenance file already uses' {
        & $script:protect 'HDTAdminPassword' 'MARKER-NOT-A-PASSWORD-01' |
            Should -BeExactly '(set, not shown)'
    }

    # NOT SET AND SET-BUT-HIDDEN ARE DIFFERENT FACTS. The first is a deployment
    # that is about to fail for want of a password, and saying "(set, not
    # shown)" about it would hide the reason.
    It 'leaves an empty secret empty, because unset is not the same as hidden' {
        & $script:protect 'HDTAdminPassword' '' | Should -BeExactly ''
    }

    It 'leaves a null secret null' {
        & $script:protect 'HDTAdminPassword' $null | Should -BeNullOrEmpty
    }

    It 'redacts an undeclared secret too, through the same classifier' {
        & $script:protect 'HDTJoinPassword' 'MARKER-NOT-A-PASSWORD-02' |
            Should -BeExactly '(set, not shown)'
    }

    # ONE PHRASING, NOT TWO. Gather\provenance.json and the wizard summary page
    # already say these words; a redaction that read differently would look like
    # a different mechanism to whoever is reading the two files side by side.
    It 'uses one phrasing for every secret it hides' {
        $shown = @(
            (& $script:protect 'HDTAdminPassword' 'MARKER-03'),
            (& $script:protect 'HDTBitLockerPin' 'MARKER-04'),
            (& $script:protect 'HDTJoinPassword' 'MARKER-05'))

        @($shown | Select-Object -Unique).Count | Should -Be 1
    }
}

# Behaviour that belongs to the ILsaService fake itself rather than to the
# contract: seeding, case handling, recording, and the guarantee that nothing
# here reaches real LSA private data.
#
# DESIGN 4.5.2: the deployment password is stored as an LSA secret named
# DefaultPassword, not as registry cleartext. That is the whole reason this
# service exists, so the fake has to be trustworthy about two things - it never
# reads or writes the host's real secrets, and it never puts a secret VALUE into
# a recorded operation, because a recorded operation is printed verbatim in a
# Pester failure message.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakeLsaService' {

    It 'returns a seeded secret' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }

        $lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
    }

    It 'returns null for a secret that was never set' {
        $lsa = New-HDTFakeLsaService

        $lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
    }

    It 'stores a secret' {
        $lsa = New-HDTFakeLsaService
        $lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')

        $lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
    }

    It 'overwrites a secret' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'first' }
        $lsa.SetSecret('DefaultPassword', 'second')

        $lsa.GetSecret('DefaultPassword') | Should -BeExactly 'second'
    }

    It 'removes a secret' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $lsa.RemoveSecret('DefaultPassword')

        $lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
    }

    It 'does not throw removing a secret that is absent' {
        # Teardown runs on machines in unknown states (DESIGN 4.5.3).
        $lsa = New-HDTFakeLsaService

        { $lsa.RemoveSecret('DefaultPassword') } | Should -Not -Throw
    }

    It 'compares secret names case-insensitively' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }

        $lsa.GetSecret('defaultpassword') | Should -BeExactly 'Sw0rdfish!'
    }

    It 'records SetSecret, GetSecret and RemoveSecret' {
        $lsa = New-HDTFakeLsaService
        $lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')
        $lsa.GetSecret('DefaultPassword') | Out-Null
        $lsa.RemoveSecret('DefaultPassword')

        $lsa.GetOperationName() | Should -Be @('SetSecret', 'GetSecret', 'RemoveSecret')
    }

    It 'records the name but not the value of a stored secret' {
        # $Operations is printed verbatim when an assertion fails. The one secret
        # HDT holds does not belong in a test report either.
        $lsa = New-HDTFakeLsaService
        $lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')

        @($lsa.Operations[0].Arguments)[0] | Should -BeExactly 'DefaultPassword'
        ($lsa.Operations | Out-String) | Should -Not -Match 'Sw0rdfish'
    }

    It 'does not record seeding' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $lsa.SeedSecret('Other', 'x')

        @($lsa.Operations).Count | Should -Be 0
    }

    It 'appends to the shared journal' {
        $journal = [System.Collections.ArrayList]::new()
        $lsa = New-HDTFakeLsaService -Journal $journal
        $lsa.RemoveSecret('DefaultPassword')

        @($journal).Count | Should -Be 1
        $journal[0].Service | Should -BeExactly 'LsaService'
        $journal[0].Operation | Should -BeExactly 'RemoveSecret'
    }

    It 'never touches real LSA storage' {
        # This host may genuinely carry a DefaultPassword LSA secret - S7's
        # machine did. An unseeded fake must still report absence rather than
        # quietly returning the real one.
        $lsa = New-HDTFakeLsaService

        $lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
    }

    It 'is independent between instances' {
        $first = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $second = New-HDTFakeLsaService

        $first.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
        $second.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
    }
}

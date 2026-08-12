# Behaviour that belongs to the fake itself rather than to the IScriptInvoker
# contract: seeding, path normalisation, invocation recording, and the guarantee
# that no real script is ever executed.
#
# The fake is only ever obtained through New-HDTFakeScriptInvoker. The class name
# is never written as a type literal here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:seededPath = 'Scripts/Get-ComputerName.ps1'
}

Describe 'New-HDTFakeScriptInvoker' {

    It 'returns the seeded result for a path' {
        $invoker = New-HDTFakeScriptInvoker -Result @{
            $script:seededPath = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
        }

        $invoker.Invoke($script:seededPath, @{}).HDTComputerName | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
    }

    It 'matches the path case-insensitively' {
        $invoker = New-HDTFakeScriptInvoker -Result @{
            $script:seededPath = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
        }

        $invoker.Invoke('scripts/get-computername.PS1', @{}).HDTComputerName | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
    }

    It 'normalises a backslash path to match a forward slash seed' {
        # rules.yaml writes 'Scripts\Get-ComputerName.ps1'; a test that seeded the
        # forward-slash form must still match, or every setFrom: test becomes a
        # test of which separator the author happened to type.
        $invoker = New-HDTFakeScriptInvoker -Result @{
            $script:seededPath = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
        }

        $invoker.Invoke('Scripts\Get-ComputerName.ps1', @{}).HDTComputerName | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
    }

    It 'trims a leading dot-slash from the path' {
        $invoker = New-HDTFakeScriptInvoker -Result @{
            $script:seededPath = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
        }

        $invoker.Invoke('./Scripts/Get-ComputerName.ps1', @{}).HDTComputerName | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
    }

    It 'throws FileNotFoundException for a path that was not seeded' {
        $invoker = New-HDTFakeScriptInvoker

        { $invoker.Invoke($script:seededPath, @{}) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'names the missing script in the message' {
        $invoker = New-HDTFakeScriptInvoker

        { $invoker.Invoke($script:seededPath, @{}) } | Should -Throw -ExpectedMessage '*Get-ComputerName.ps1*'
    }

    It 'returns null when a path is seeded with $null' {
        # "The script ran and emitted nothing" is a different fact from "no such
        # script", exactly as it is for the real adapter.
        $invoker = New-HDTFakeScriptInvoker -Result @{ 'Scripts/Get-Nothing.ps1' = $null }

        $invoker.Invoke('Scripts/Get-Nothing.ps1', @{}) | Should -BeNullOrEmpty
        { $invoker.Invoke('Scripts/Get-Nothing.ps1', @{}) } | Should -Not -Throw
    }

    It 'records the variables it was passed' {
        $invoker = New-HDTFakeScriptInvoker -Result @{ $script:seededPath = $null }
        $invoker.Invoke($script:seededPath, @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }) | Out-Null

        @($invoker.Operations).Count | Should -Be 1
        @($invoker.Operations[0].Arguments)[0] | Should -BeExactly $script:seededPath
        (@($invoker.Operations[0].Arguments)[1])['HDTSerialNumber'] | Should -BeExactly 'FIXTURE-SERIAL-0001'
    }

    It 'records an invocation that threw' {
        $invoker = New-HDTFakeScriptInvoker

        { $invoker.Invoke($script:seededPath, @{}) } | Should -Throw

        @($invoker.Operations).Count | Should -Be 1
    }

    It 'returns invocation names in order from GetOperationName' {
        $invoker = New-HDTFakeScriptInvoker -Result @{ $script:seededPath = $null }
        $invoker.Invoke($script:seededPath, @{}) | Out-Null
        $invoker.Invoke($script:seededPath, @{}) | Out-Null

        $invoker.GetOperationName() | Should -Be @('Invoke', 'Invoke')
    }

    It 'never runs a real script' {
        # Point the unseeded fake at a script that genuinely exists and would
        # leave a trace if it ran. It must refuse rather than execute.
        $real = Join-Path -Path $TestDrive -ChildPath 'Ran.ps1'
        $marker = Join-Path -Path $TestDrive -ChildPath 'marker.txt'
        Set-Content -LiteralPath $real -Value ("Set-Content -LiteralPath '{0}' -Value 'ran'" -f $marker) -Encoding UTF8

        $invoker = New-HDTFakeScriptInvoker

        { $invoker.Invoke($real, @{}) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'does not record seeding as an operation' {
        $invoker = New-HDTFakeScriptInvoker -Result @{ $script:seededPath = $null }

        @($invoker.Operations).Count | Should -Be 0
    }

    It 'is independent between instances' {
        $first = New-HDTFakeScriptInvoker -Result @{ $script:seededPath = $null }
        $second = New-HDTFakeScriptInvoker

        { $first.Invoke($script:seededPath, @{}) } | Should -Not -Throw
        { $second.Invoke($script:seededPath, @{}) } | Should -Throw
    }
}

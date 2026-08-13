# The IScriptInvoker contract (PROJECT constraint 4, DESIGN 3.3, DESIGN 12.2.1).
#
# DESIGN 3.3: when a rule needs real logic it calls a script -
# "setFrom: Scripts\Get-ComputerName.ps1", whose output object becomes the
# variable set. That script runs with the currently resolved variables, and the
# rule engine must be provable without executing anything, so invocation goes
# through this one-method interface.
#
# Every implementation must pass this file unchanged.
#
# WHY THE SCRIPTS ARE COMMITTED FIXTURES RATHER THAN $TestDrive FILES: the
# implementation registry is built at DISCOVERY time and each factory is invoked
# as & $Factory $repositoryRoot, so $TestDrive - which only exists during the
# run phase, per container - is not reachable from a factory. A committed
# fixture under tests/fixtures/scripts is reachable from both rows, and lets the
# real adapter execute a real script.
#
# EXCEPTION TYPES ARE ASSERTED AFTER UNWRAPPING. A fake is a PowerShell class,
# whose method throws the original exception type. A real adapter is a
# pscustomobject whose ScriptMethod wraps it in MethodInvocationException ->
# RuntimeException -> the original. The loop below is a no-op for the fake and
# unwraps twice for the adapter, so one assertion serves both rows. Assertions
# about a MESSAGE need no unwrapping: MethodInvocationException.Message embeds
# the inner message.
$script:HDTImplementation = @(
    @{
        Name    = 'FakeScriptInvoker'
        Factory = { New-HDTFakeScriptInvoker -Result @{
                'tests/fixtures/scripts/Get-ComputerName.ps1'    = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
                'tests/fixtures/scripts/Get-Nothing.ps1'         = $null
                'tests/fixtures/scripts/Write-HostAndObject.ps1' = [pscustomobject] @{ HDTBiosBaseline = 'ok' }
            } -Transcript @{
                'tests/fixtures/scripts/Write-HostAndObject.ps1' = @('checking vendor BIOS level')
            } }
        Skip    = $false
    }
    @{
        Name    = 'ScriptInvoker'
        Factory = { param($RepositoryRoot) New-HDTScriptInvoker -Root $RepositoryRoot }
        Skip    = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }
)

Describe 'IScriptInvoker contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        # Relative, exactly as rules.yaml writes it: the real adapter resolves it
        # against its -Root so a workspace works from a share or from media.
        $script:computerNameScript = 'tests/fixtures/scripts/Get-ComputerName.ps1'
        $script:nothingScript = 'tests/fixtures/scripts/Get-Nothing.ps1'
        $script:missingScript = 'tests/fixtures/scripts/Get-HDTNoSuchScript.ps1'

        # DESIGN 4.4.4: a script that only uses Write-Host must still land in the
        # log. This fixture writes one host line AND emits one object, so the two
        # can be told apart.
        $script:hostAndObjectScript = 'tests/fixtures/scripts/Write-HostAndObject.ps1'
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:invoker = & $Factory $script:repoRoot
        }

        It 'exposes Invoke' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            @($script:invoker | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name }) |
                Should -Contain 'Invoke'
        }

        It 'returns the object the script emitted' {
            $result = $script:invoker.Invoke($script:computerNameScript, @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' })

            $result | Should -Not -BeNullOrEmpty
            @($result.PSObject.Properties.Name) | Should -Contain 'HDTComputerName'
        }

        It 'passes the resolved variables to the script' {
            # On the real row this proves the script really received -Variable; on
            # the fake row it proves the seed comes back unchanged.
            $result = $script:invoker.Invoke($script:computerNameScript, @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' })

            $result.HDTComputerName | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
        }

        It 'throws FileNotFoundException for a script that does not exist' {
            $record = $null
            try { $script:invoker.Invoke($script:missingScript, @{}) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }

            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'names the missing script in the message' {
            { $script:invoker.Invoke($script:missingScript, @{}) } |
                Should -Throw -ExpectedMessage '*Get-HDTNoSuchScript.ps1*'
        }

        It 'returns null when the script emits nothing' {
            $script:invoker.Invoke($script:nothingScript, @{}) | Should -BeNullOrEmpty
        }

        It 'records each invocation in Operations' {
            $script:invoker.Invoke($script:nothingScript, @{}) | Out-Null
            $script:invoker.Invoke($script:computerNameScript, @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }) | Out-Null

            @($script:invoker.Operations).Count | Should -Be 2
            @($script:invoker.GetOperationName()) | Should -Be @('Invoke', 'Invoke')
        }

        It 'records the script path of each invocation' {
            $script:invoker.Invoke($script:nothingScript, @{}) | Out-Null

            @($script:invoker.Operations[0].Arguments)[0] | Should -BeExactly $script:nothingScript
        }

        It 'records the variables of each invocation' {
            $script:invoker.Invoke($script:computerNameScript, @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }) | Out-Null

            $recorded = @($script:invoker.Operations[0].Arguments)[1]

            $recorded | Should -Not -BeNullOrEmpty
            $recorded['HDTSerialNumber'] | Should -BeExactly 'FIXTURE-SERIAL-0001'
        }

        It 'exposes GetTranscript' {
            @($script:invoker | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name }) |
                Should -Contain 'GetTranscript'
        }

        It 'returns an empty transcript before the first invoke' {
            @($script:invoker.GetTranscript()).Count | Should -Be 0
        }

        It 'captures a Write-Host line into the transcript' {
            $script:invoker.Invoke($script:hostAndObjectScript, @{}) | Out-Null

            @($script:invoker.GetTranscript()) -join ' ' | Should -BeLike '*checking vendor BIOS level*'
        }

        It 'does not return the host line as the result' {
            # The assertion that would have broken silently when the adapter
            # switched from Select-Object -Last 1 to capturing *>&1: an
            # InformationRecord is a transcript line, never the result.
            $result = $script:invoker.Invoke($script:hostAndObjectScript, @{})

            @($result.PSObject.Properties.Name) | Should -Contain 'HDTBiosBaseline'
            $result.HDTBiosBaseline | Should -BeExactly 'ok'
        }

        It 'returns an empty transcript for a script that wrote nothing' {
            $script:invoker.Invoke($script:nothingScript, @{}) | Out-Null

            @($script:invoker.GetTranscript()).Count | Should -Be 0
        }

        It 'replaces the transcript on the next invoke' {
            $script:invoker.Invoke($script:hostAndObjectScript, @{}) | Out-Null
            $script:invoker.Invoke($script:nothingScript, @{}) | Out-Null

            @($script:invoker.GetTranscript()).Count | Should -Be 0
        }

        It 'returns an array from GetTranscript even for one line' {
            $script:invoker.Invoke($script:hostAndObjectScript, @{}) | Out-Null

            $script:invoker.GetTranscript() -is [System.Array] | Should -BeTrue
        }
    }
}

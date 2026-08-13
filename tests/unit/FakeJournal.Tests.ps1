# The shared operation journal (DESIGN 12.2.1).
#
# Each fake's own $Operations answers "what was THIS service asked to do".
# The headline test of phase 03 asks a different question - "in what order did
# the engine touch the services" - and no per-fake list can answer it. Every
# New-HDTFake* factory therefore takes -Journal, and every Record() appends to it
# in addition to $Operations, with a Sequence numbered globally across services.
#
# The -ForEach list below is the point of this file: a fake added later that
# forgets -Journal turns the suite red rather than quietly breaking the ordered
# assertion the engine test depends on.

$script:HDTJournalledFake = @(
    @{
        Name      = 'FileSystem'
        Service   = 'FileSystem'
        Factory   = { param($Journal) New-HDTFakeFileSystem -Journal $Journal }
        Exercise  = { param($Fake) $Fake.TestPath('C:\ws\rules.yaml') }
        Operation = 'TestPath'
        Argument  = @('C:\ws\rules.yaml')
    }
    @{
        Name      = 'CimProvider'
        Service   = 'CimProvider'
        Factory   = { param($Journal) New-HDTFakeCimProvider -Instance @{ Win32_BIOS = @([pscustomobject] @{ SerialNumber = 'FIXTURE-SERIAL-0001' }) } -Journal $Journal }
        Exercise  = { param($Fake) $Fake.GetInstance('Win32_BIOS') }
        Operation = 'GetInstance'
        Argument  = @('root/cimv2', 'Win32_BIOS')
    }
    @{
        Name      = 'RegistryService'
        Service   = 'RegistryService'
        Factory   = { param($Journal) New-HDTFakeRegistryService -Journal $Journal }
        Exercise  = { param($Fake) $Fake.GetValue('HKLM:\SOFTWARE\HDT', 'Leg') }
        Operation = 'GetValue'
        Argument  = @('HKLM:\SOFTWARE\HDT', 'Leg')
    }
    @{
        Name      = 'EnvironmentProvider'
        Service   = 'EnvironmentProvider'
        Factory   = { param($Journal) New-HDTFakeEnvironmentProvider -Journal $Journal }
        Exercise  = { param($Fake) $Fake.GetVariable('PROCESSOR_ARCHITECTURE') }
        Operation = 'GetVariable'
        Argument  = @('PROCESSOR_ARCHITECTURE')
    }
    @{
        Name      = 'ScriptInvoker'
        Service   = 'ScriptInvoker'
        Factory   = { param($Journal) New-HDTFakeScriptInvoker -Result @{ 'Scripts/Get-ComputerName.ps1' = $null } -Journal $Journal }
        Exercise  = { param($Fake) $Fake.Invoke('Scripts/Get-ComputerName.ps1', @{}) }
        Operation = 'Invoke'
        Argument  = @('Scripts/Get-ComputerName.ps1')
    }
    @{
        Name      = 'ProcessService'
        Service   = 'ProcessService'
        Factory   = { param($Journal) New-HDTFakeProcessService -Result @{ 'cmd.exe /c exit 0' = @{ ExitCode = 0 } } -Journal $Journal }
        Exercise  = { param($Fake) $Fake.Start('cmd.exe', '/c exit 0', '', 0) }
        Operation = 'Start'
        Argument  = @('cmd.exe', '/c exit 0', '', 0)
    }
    @{
        Name      = 'PowerService'
        Service   = 'PowerService'
        Factory   = { param($Journal) New-HDTFakePowerService -Journal $Journal }
        Exercise  = { param($Fake) $Fake.Restart(0) }
        Operation = 'Restart'
        Argument  = @(0)
    }
    @{
        Name      = 'LsaService'
        Service   = 'LsaService'
        Factory   = { param($Journal) New-HDTFakeLsaService -Journal $Journal }
        Exercise  = { param($Fake) $Fake.GetSecret('DefaultPassword') }
        Operation = 'GetSecret'
        Argument  = @('DefaultPassword')
    }
    @{
        Name      = 'RandomNumberGenerator'
        Service   = 'RandomNumberGenerator'
        Factory   = { param($Journal) New-HDTFakeRandomNumberGenerator -Byte ([byte[]] @(1, 2, 3)) -Journal $Journal }
        Exercise  = { param($Fake) $Fake.GetBytes((New-Object -TypeName 'System.Byte[]' -ArgumentList 1)) }
        Operation = 'GetBytes'
        Argument  = @(1)
    }
    @{
        Name      = 'Clock'
        Service   = 'Clock'
        Factory   = { param($Journal) New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -Journal $Journal }
        Exercise  = { param($Fake) $Fake.Sleep(1500) }
        Operation = 'Sleep'
        Argument  = @(1500)
    }
)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'the shared fake journal' {

    Context 'every fake honours -Journal' -ForEach $script:HDTJournalledFake {

        BeforeEach {
            $script:journal = [System.Collections.ArrayList]::new()
            $script:fake = & $Factory $script:journal
        }

        It 'appends to the journal for <Name>' {
            & $Exercise $script:fake | Out-Null

            @($script:journal).Count | Should -Be 1
            $script:journal[0].Sequence | Should -Be 1
        }

        It 'names the service in the journal entry for <Name>' {
            & $Exercise $script:fake | Out-Null

            $script:journal[0].Service | Should -BeExactly $Service
        }

        It 'records the operation name in the journal entry for <Name>' {
            & $Exercise $script:fake | Out-Null

            $script:journal[0].Operation | Should -BeExactly $Operation
        }

        It 'records the arguments in the journal entry for <Name>' {
            & $Exercise $script:fake | Out-Null

            $recorded = @($script:journal[0].Arguments)
            for ($index = 0; $index -lt @($Argument).Count; $index++) {
                $recorded[$index] | Should -Be @($Argument)[$index]
            }
        }

        It 'still records into its own Operations for <Name>' {
            & $Exercise $script:fake | Out-Null

            @($script:fake.Operations).Count | Should -Be 1
            $script:fake.Operations[0].Sequence | Should -Be 1
            $script:fake.Operations[0].Operation | Should -BeExactly $Operation
        }

        It 'exposes ServiceName for <Name>' {
            $script:fake.ServiceName | Should -BeExactly $Service
        }

        It 'behaves exactly as before when no journal is supplied for <Name>' {
            # A null journal is how "the caller did not ask for one" arrives here,
            # and it must be indistinguishable from omitting the parameter.
            $lonely = & $Factory $null

            { & $Exercise $lonely | Out-Null } | Should -Not -Throw
            @($lonely.Operations).Count | Should -Be 1
            $lonely.Operations[0].Operation | Should -BeExactly $Operation
        }
    }

    Context 'ordering across services' {

        BeforeEach {
            $script:journal = [System.Collections.ArrayList]::new()
            $script:fs = New-HDTFakeFileSystem -Journal $script:journal
            $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -Journal $script:journal
            $script:registry = New-HDTFakeRegistryService -Journal $script:journal
        }

        It 'numbers journal entries globally, in call order' {
            $script:fs.TestPath('C:\HDT\state.json') | Out-Null
            $script:clock.GetUtcNow() | Out-Null
            $script:registry.TestPath('HKLM:\SOFTWARE\HDT') | Out-Null
            $script:fs.WriteAllText('C:\HDT\state.json', '{}')

            @($script:journal | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2, 3, 4)
            @($script:journal | ForEach-Object { $_.Service }) |
                Should -Be @('FileSystem', 'Clock', 'RegistryService', 'FileSystem')
        }

        It 'supports the canonical Service.Operation assertion' {
            $script:fs.SeedFile('C:\HDT\state.json', '{}')
            $script:fs.ReadAllText('C:\HDT\state.json') | Out-Null
            $script:clock.GetUtcNow() | Out-Null
            $script:fs.AppendAllText('C:\HDT\Logs\HDT.jsonl', '{}')

            @($script:journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('FileSystem.ReadAllText', 'Clock.GetUtcNow', 'FileSystem.AppendAllText')
        }

        It 'keeps per-fake Operations numbering independent of the journal' {
            $script:fs.TestPath('C:\a') | Out-Null
            $script:clock.GetUtcNow() | Out-Null
            $script:fs.TestPath('C:\b') | Out-Null

            @($script:fs.Operations | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2)
            @($script:clock.Operations | ForEach-Object { $_.Sequence }) | Should -Be @(1)
            @($script:journal | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2, 3)
        }

        It 'records nothing in the journal for seeding' {
            $journal = [System.Collections.ArrayList]::new()
            $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = 'schemaVersion: 1' } -Journal $journal
            $registry = New-HDTFakeRegistryService -Value @{ 'HKLM:\SOFTWARE\HDT' = @{ Leg = 1 } } -Journal $journal
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -Journal $journal
            $clock.Advance(1000)
            $fs.SeedFile('C:\ws\sequence.yaml', 'steps: []')
            $registry.SeedValue('HKLM:\SOFTWARE\HDT', 'Leg', 2)

            @($journal).Count | Should -Be 0
        }

        It 'records a call that went on to throw' {
            $threw = $false
            try {
                $script:fs.ReadAllText('C:\HDT\missing.json')
            } catch {
                $threw = $true
            }

            $threw | Should -BeTrue
            @($script:journal).Count | Should -Be 1
            $script:journal[0].Service | Should -BeExactly 'FileSystem'
            $script:journal[0].Operation | Should -BeExactly 'ReadAllText'
        }

        It 'shares one journal between two instances of the same service' {
            $second = New-HDTFakeFileSystem -Journal $script:journal

            $script:fs.TestPath('C:\a') | Out-Null
            $second.TestPath('C:\b') | Out-Null

            @($script:journal | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2)
            @($script:journal | ForEach-Object { $_.Arguments[0] }) | Should -Be @('C:\a', 'C:\b')
        }
    }
}

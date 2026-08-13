# ROADMAP M1 EXIT CRITERION, asserted end to end:
#
#   "given a fixture machine's facts and a rules.yaml, the engine produces the
#    expected variable set AND explains every value."
#
# Both halves are here, in two Contexts, because half of it is not the criterion:
# a variable set nobody can explain is exactly the MDT situation HDT exists to
# replace.
#
# The whole phase is wired together - Get-HDTMachineFact, Import-HDTRuleDocument,
# Get-HDTMachineOverride, Resolve-HDTVariable, Get-HDTVariableProvenance,
# Export-HDTVariableProvenance - against nothing but fakes: no machine, no disk,
# no script execution. The third Context proves that claim rather than asserting
# it in a comment.
#
# The sample workspace under samples/ is the input, read off disk ONCE by the
# test and seeded into the fake filesystem. The sample and the CIM fixtures
# describe the same machine: the override file is named for the UUID in
# tests/fixtures/cim/Win32_ComputerSystemProduct.json.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:sampleRoot = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace'
    $script:uuid = '4C4C4544-0031-3610-8052-B7C04F515A31'

    # -- the services, all fake ------------------------------------------------

    $script:cim = New-HDTFakeCimProvider `
        -FixturePath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim') `
        -NamespaceFixturePath @{
        'root/cimv2/security/microsofttpm' = (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm')
    }

    $script:environment = New-HDTFakeEnvironmentProvider -Variable @{
        firmware_type          = 'UEFI'
        PROCESSOR_ARCHITECTURE = 'AMD64'
    }

    $script:registry = New-HDTFakeRegistryService -Value @{
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
    }

    $script:rulesPath = 'C:\ws\rules.yaml'
    $script:overridePath = 'C:\ws\Control\machines\{0}.yaml' -f $script:uuid

    $script:fileSystem = New-HDTFakeFileSystem -File @{
        $script:rulesPath    = (Get-Content -LiteralPath (Join-Path -Path $script:sampleRoot -ChildPath 'rules.yaml') -Raw)
        $script:overridePath = (Get-Content -LiteralPath (Join-Path -Path $script:sampleRoot -ChildPath ('Control/machines/{0}.yaml' -f $script:uuid)) -Raw)
    }

    # The setFrom script is never executed. This is what the real
    # samples/workspace/Scripts/Get-ComputerName.ps1 would have emitted for this
    # machine, seeded so phase 03 can swap in the real invoker unchanged.
    $script:invoker = New-HDTFakeScriptInvoker -Result @{
        'Scripts/Get-ComputerName.ps1' = [pscustomobject] @{ HDTAssetTag = 'ASSET-FIXTURE-SERIAL-0001' }
    }

    # -- the run ---------------------------------------------------------------

    $script:fact = Get-HDTMachineFact -CimProvider $script:cim `
        -RegistryService $script:registry -EnvironmentProvider $script:environment

    $script:document = Import-HDTRuleDocument -Path $script:rulesPath -FileSystem $script:fileSystem

    $script:override = Get-HDTMachineOverride -WorkspaceRoot 'C:\ws' `
        -Uuid $script:fact['HDTUUID'] -FileSystem $script:fileSystem

    $script:result = Resolve-HDTVariable `
        -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' } `
        -MachineOverride $script:override.Variable `
        -MachineOverridePath $script:override.Path `
        -RuleDocument $script:document `
        -Fact $script:fact `
        -SequenceDefault @{ HDTDiskLayout = 'uefi-standard'; HDTJoinWorkgroup = 'DEFAULT-WG' } `
        -ScriptInvoker $script:invoker
}

Describe 'Gather and resolve, end to end' {

    Context 'the expected variable set' {

        It 'resolves HDTTaskSequenceID to the command line value' {
            # Beats the override (OVR-CLIENT) and the Lab subnet rule (LAB-CLIENT).
            $script:result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'CMD-CLIENT'
        }

        It 'resolves HDTComputerName to the machine override value' {
            # Beats the Fallback rule's PC-%HDTSerialNumber%.
            $script:result.Variable['HDTComputerName'] | Should -BeExactly 'FIN-0007'
        }

        It 'resolves HDTJoinDomain from the Lab subnet rule' {
            # Proves the gathered gateway fact 10.20.30.1 matched a rule keyed on
            # a value that is a LIST on this machine.
            $script:result.Variable['HDTJoinDomain'] | Should -BeExactly 'lab.contoso.com'
        }

        It 'resolves HDTSkipWizard to the boolean true' {
            $script:result.Variable['HDTSkipWizard'] | Should -BeOfType ([bool])
            $script:result.Variable['HDTSkipWizard'] | Should -BeTrue
        }

        It 'does not resolve HDTDriverGroup' {
            # The Latitude naming rule does not match model 82RF, so a wildcard
            # that fails leaves nothing behind rather than an empty variable.
            $script:result.Variable.Contains('HDTDriverGroup') | Should -BeFalse
        }

        It 'resolves HDTAssetTag from the setFrom script' {
            $script:result.Variable['HDTAssetTag'] | Should -BeExactly 'ASSET-FIXTURE-SERIAL-0001'
        }

        It 'resolves HDTJoinWorkgroup from the Fallback rule, not the sequence default' {
            $script:result.Variable['HDTJoinWorkgroup'] | Should -BeExactly 'WORKGROUP'
        }

        It 'resolves HDTDiskLayout from the sequence default' {
            $script:result.Variable['HDTDiskLayout'] | Should -BeExactly 'uefi-standard'
        }

        It 'resolves HDTModel from the gathered facts' {
            $script:result.Variable['HDTModel'] | Should -BeExactly '82RF'
        }

        It 'resolves HDTIsLaptop to true from the gathered facts' {
            $script:result.Variable['HDTIsLaptop'] | Should -BeTrue
        }

        It 'resolves every gathered fact that no higher source overrode' {
            $missing = @()

            foreach ($name in @($script:fact.Keys)) {
                if (-not $script:result.Variable.Contains($name)) {
                    $missing += $name
                }
            }

            $missing -join ', ' | Should -BeExactly ''
        }
    }

    Context 'and explains every value' {

        It 'explains every resolved variable' {
            $unexplained = @()

            foreach ($name in @($script:result.Variable.Keys)) {
                if (-not $script:result.Provenance.Contains($name)) {
                    $unexplained += $name
                }
            }

            $unexplained -join ', ' | Should -BeExactly ''
        }

        It 'explains HDTTaskSequenceID as CommandLine' {
            $script:result.Provenance['HDTTaskSequenceID'].Source | Should -BeExactly 'CommandLine'
        }

        It 'explains HDTComputerName as MachineOverride, naming the override file' {
            $record = $script:result.Provenance['HDTComputerName']

            $record.Source | Should -BeExactly 'MachineOverride'
            $record.File | Should -BeExactly $script:overridePath
        }

        It 'explains HDTJoinDomain as Rule, naming the Lab subnet rule and rules.yaml' {
            $record = $script:result.Provenance['HDTJoinDomain']

            $record.Source | Should -BeExactly 'Rule'
            $record.Rule | Should -BeExactly 'Lab subnet'
            $record.RuleIndex | Should -Be 1
            $record.File | Should -BeExactly $script:rulesPath
        }

        It 'explains HDTAssetTag as RuleScript, naming the script' {
            $record = $script:result.Provenance['HDTAssetTag']

            $record.Source | Should -BeExactly 'RuleScript'
            $record.Rule | Should -BeExactly 'Scripted name for laptops'
            $record.File | Should -BeExactly 'Scripts\Get-ComputerName.ps1'
        }

        It 'explains HDTModel as GatheredFact' {
            $script:result.Provenance['HDTModel'].Source | Should -BeExactly 'GatheredFact'
        }

        It 'explains HDTDiskLayout as SequenceDefault' {
            $script:result.Provenance['HDTDiskLayout'].Source | Should -BeExactly 'SequenceDefault'
        }

        It 'uses only sources from the closed set' {
            $closed = @('CommandLine', 'MachineOverride', 'Rule', 'RuleScript', 'GatheredFact', 'SequenceDefault')

            foreach ($record in @(Get-HDTVariableProvenance -Resolution $script:result)) {
                $closed | Should -Contain $record.Source
            }
        }

        It 'orders the explanation by resolution order' {
            $record = @(Get-HDTVariableProvenance -Resolution $script:result)

            @($record | ForEach-Object { $_.Order }) | Should -Be @(1..$record.Count)
        }

        It 'reports no unresolved tokens for this workspace' {
            @($script:result.Unresolved) -join ', ' | Should -BeExactly ''
        }
    }

    Context 'the run touched nothing real' {

        It 'queried CIM only through the fake' {
            $script:cim.Operations.Count | Should -BeGreaterThan 0
        }

        It 'read the workspace only through the fake filesystem' {
            $script:fileSystem.GetOperationName() | Should -Contain 'ReadAllText'
            Test-Path -LiteralPath 'C:\ws' | Should -BeFalse
        }

        It 'ran no script' {
            # One setFrom rule matched, so the invoker was called exactly once -
            # and no PowerShell process ran, because the invoker is a fake.
            $script:invoker.Operations.Count | Should -Be 1
            $script:invoker.Operations[0].Arguments[0] | Should -BeExactly 'Scripts\Get-ComputerName.ps1'
        }

        It 'wrote no file to the real disk' {
            $exportPath = 'C:\ws\Logs\Gather\provenance.json'

            Export-HDTVariableProvenance -Resolution $script:result -Path $exportPath -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($exportPath) | Should -BeTrue
            Test-Path -LiteralPath $exportPath | Should -BeFalse
            Test-Path -LiteralPath 'C:\ws' | Should -BeFalse
        }
    }
}

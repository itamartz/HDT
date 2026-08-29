# MDT'S "Gather local only", WHICH IS THE WHOLE OF ITS Initialization GROUP.
#
# WHY A STEP AND NOT JUST ENGINE START-UP. HDT gathers once before the sequence
# begins, and DESIGN 3.2.1 already says the facts are "refreshed after OS apply"
# - the machine a sequence finishes on is not the machine it started on. Making
# that a step is what lets a sequence SAY WHERE, the way MDT's does, instead of
# the refresh being a rule in the engine that nobody reading the sequence can
# see.
#
# IT TOUCHES NO HARDWARE. Get-HDTMachineFact takes an ICimProvider and the step
# hands it the injected one, so the whole thing runs under Pester against a fake
# - which is the same rule every other step in this engine follows.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Get-HDTLogRecord, to read the step's own log back. What this step SAYS on a
    # successful run is most of what it does, and asserting only the return value
    # would leave every line of it unproven.
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # THE SAME CAPTURED CIM DATA Get-HDTMachineFact's own suite gathers against
    # - real shapes off a real machine, which is what CLAUDE.md asks fixtures to
    # be. Inventing a Win32_ComputerSystem here would test this step against a
    # machine that does not exist.
    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'

    $script:newCim = {
        $instance = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
            $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
        }

        return New-HDTFakeCimProvider -Instance $instance `
            -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }
    }

    $script:newStep = {
        param([System.Collections.IDictionary] $Property, [string] $Name = 'Gather')

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Name            = $Name
            Type            = 'Gather'
            Index           = 1
            GroupPath       = @('Initialization')
            RunIn           = 'WinPE'
            Condition       = ''
            Disabled        = $false
            ContinueOnError = $false
            Property        = $bag
        }
    }

    $script:newContext = {
        param([System.Collections.IDictionary] $Variable, [object] $Cim)

        $fileSystem = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 17, 12, 0, 0, [System.DateTimeKind]::Utc))

        # KEPT WHERE A TEST CAN READ THE LOG BACK. The step's whole job on a
        # successful run is what it SAYS; asserting only the return value would
        # leave every line of it unproven.
        $script:fileSystem = $fileSystem

        $registry = $null
        $environment = $null

        # The other two ports the gather reads - registry for SecureBoot, the
        # environment for the firmware type. Absent with the CIM provider, so
        # "no provider" stays one case rather than three.
        if ($null -ne $Cim) {
            $registry = New-HDTFakeRegistryService
            $environment = New-HDTFakeEnvironmentProvider
        }

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Cim $Cim `
            -Registry $registry -Environment $environment

        $log = New-HDTLogContext -RunId 'run-gather' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
        }

        return (New-HDTExecutionContext -RunId 'run-gather' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log)
    }
}

Describe 'Invoke-HDTGatherStep' {

    BeforeEach {
        # A REAL CAPTURED SHAPE, not an invented one: the fake CIM provider is
        # the same one every other suite in this toolkit gathers against.
        $script:cim = & $script:newCim
    }

    It 'is discovered as a step type the engine can run' {
        Get-HDTStepType -Name 'Gather' | Should -Not -BeNullOrEmpty
    }

    It 'can be added from a menu, which means it has a template' {
        (Get-HDTStepType -Name 'Gather').CanAdd | Should -BeTrue
    }

    It 'completes' {
        $context = & $script:newContext $null $script:cim
        $step = & $script:newStep $null

        (Invoke-HDTGatherStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
    }

    It 'puts the machine facts into the variables the sequence reads' {
        $context = & $script:newContext $null $script:cim
        $step = & $script:newStep $null

        [void] (Invoke-HDTGatherStep -Step $step -Context $context)

        $context.Variable.Contains('HDTMake') | Should -BeTrue
        $context.Variable.Contains('HDTIsUEFI') | Should -BeTrue
    }

    It 'says how many facts it gathered rather than just Completed' {
        $context = & $script:newContext $null $script:cim
        $step = & $script:newStep $null

        $result = Invoke-HDTGatherStep -Step $step -Context $context

        $result.Message | Should -Match '\d'
    }

    It 'refreshes a fact that has changed since the last gather' {
        # THE POINT OF RUNNING IT TWICE. The machine a sequence finishes on is
        # not the machine it started on - that is why MDT gathers in
        # Initialization, again in Preinstall and again in State Restore.
        $context = & $script:newContext ([ordered] @{ HDTMake = 'something stale' }) $script:cim
        $step = & $script:newStep $null

        [void] (Invoke-HDTGatherStep -Step $step -Context $context)

        [string] $context.Variable['HDTMake'] | Should -Not -Be 'something stale'
    }

    # THE ONE LINE DESCRIBING THE ONE THING THAT CHANGED HAS TO BE READABLE.
    # A real run logged "HDTAssetTag: ASSET-7FJ45S2 -> " with nothing after the
    # arrow, and nothing on the page said whether the new value was empty,
    # whether the rendering had failed, or which side of the arrow was which.
    It 'says (empty) rather than leaving a side of the arrow blank' {
        $context = & $script:newContext $null $script:cim
        $step = & $script:newStep $null

        [void] (Invoke-HDTGatherStep -Step $step -Context $context)

        # The first gather has nothing before it, so every changed line has an
        # empty left-hand side - which is exactly the shape that was unreadable.
        $line = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                Where-Object { $_.message -like '* -> *' })

        @($line).Count | Should -BeGreaterThan 0

        $blank = @($line | Where-Object { $_.message -like '*: -> *' -or $_.message -like '* -> ' })

        (@($blank | ForEach-Object { $_.message }) -join ' | ') | Should -BeExactly ''
        @($line | Where-Object { $_.message -like '*(empty) -> *' }).Count | Should -BeGreaterThan 0
    }

    It 'leaves variables it did not gather alone' {
        # A GATHER IS NOT A RESET. HDTComputerName came from rules.yaml or the
        # wizard, and a step that cleared everything it did not produce would
        # throw away the deployment's own decisions.
        $context = & $script:newContext ([ordered] @{ HDTComputerName = 'HDT-LAB-01' }) $script:cim
        $step = & $script:newStep $null

        [void] (Invoke-HDTGatherStep -Step $step -Context $context)

        [string] $context.Variable['HDTComputerName'] | Should -BeExactly 'HDT-LAB-01'
    }

    It 'refuses without a CIM provider rather than gathering nothing and passing' {
        # A GATHER THAT QUIETLY GATHERED NOTHING would leave every later
        # condition false and every check unmade, and look like a green step.
        $context = & $script:newContext $null $null
        $step = & $script:newStep $null

        (Invoke-HDTGatherStep -Step $step -Context $context).Status | Should -BeExactly 'Failed'
    }

    It 'writes a template that reads back as a Gather step' {
        $line = @(Get-HDTGatherStepTemplate)

        ($line -join "`n") | Should -BeLike '*type: Gather*'
    }

    It 'describes itself for the tree' {
        Get-HDTGatherStepDescription -Step (& $script:newStep $null) | Should -Not -BeNullOrEmpty
    }

    Context 'a fact the machine could not determine' {

        # THE DEFECT THIS CONTEXT EXISTS FOR, off a real deployment:
        # LT-7FJ45S2-run-20260829-190105 logged
        #
        #   HDTAssetTag: ASSET-7FJ45S2 ->
        #
        # an arrow pointing at nothing. HDTAssetTag had been set to
        # 'ASSET-7FJ45S2' by a rule script - Gather\provenance.json records it,
        # source RuleScript, from Scripts\Get-ComputerName.ps1 - and this step
        # then re-gathered, got the EMPTY string SMBIOS reports on that Dell, and
        # overwrote the good value with it.
        #
        # The step's own help says "IT IS NOT A RESET"; this is the case it did
        # not cover, because a gathered fact that is empty is still a gathered
        # fact and the code had no way to tell an answer from a non-answer.

        $script:blankTagCim = $null

        BeforeEach {
            $instance = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                $parsed = ConvertFrom-Json -InputObject $text
                $instance[$file.BaseName] = [object[]] @($parsed)
            }

            $enclosure = $instance['Win32_SystemEnclosure']
            $enclosure[0].SMBIOSAssetTag = ''

            $script:blankTagCim = New-HDTFakeCimProvider -Instance $instance `
                -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }
        }

        It 'does not erase a value something else resolved' {
            $context = & $script:newContext ([ordered] @{ HDTAssetTag = 'ASSET-7FJ45S2' }) $script:blankTagCim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            [string] $context.Variable['HDTAssetTag'] | Should -BeExactly 'ASSET-7FJ45S2'
        }

        It 'says in the log that it kept the resolved value, rather than doing it silently' {
            # A STEP THAT QUIETLY DECLINES TO DO SOMETHING is as hard to diagnose
            # as one that quietly does the wrong thing.
            $context = & $script:newContext ([ordered] @{ HDTAssetTag = 'ASSET-7FJ45S2' }) $script:blankTagCim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event var.resolve)

            @($record | Where-Object { $_.message -match 'HDTAssetTag' -and $_.message -match 'kept' }) |
                Should -Not -BeNullOrEmpty
        }

        It 'still sets a fact the machine could not determine when nothing had a value' {
            # THE RULE IS "DO NOT ERASE", NOT "DO NOT WRITE". A machine with no
            # asset tag and no rule setting one must still end up with the
            # variable defined, or every condition reading it throws instead of
            # being false.
            $context = & $script:newContext $null $script:blankTagCim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            $context.Variable.Contains('HDTAssetTag') | Should -BeTrue
        }

        It 'names every fact it could not determine, with the reason' {
            # THE MOST VALUABLE ADDITION. A fact that comes back empty is
            # invisible today: it is simply absent, and nothing distinguishes
            # "this machine has no TPM" from "the query failed" from "the
            # property was blank".
            $context = & $script:newContext $null $script:blankTagCim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event var.resolve)

            $said = @($record | Where-Object { $_.message -match 'HDTAssetTag' -and $_.message -match 'SMBIOSAssetTag' })
            $said | Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the step says about itself' {

        It 'states the mode rather than leaving it to the step name' {
            # "Gather local only" is the step's NAME. Whether a database was
            # consulted is a FACT, and people trip on MDT's local/database
            # distinction constantly.
            $context = & $script:newContext $null $script:cim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event message)

            @($record | Where-Object { $_.message -match 'database' }) | Should -Not -BeNullOrEmpty
        }

        It 'counts the sources it read, not only the facts' {
            $context = & $script:newContext $null $script:cim
            $step = & $script:newStep $null

            $result = Invoke-HDTGatherStep -Step $step -Context $context

            [int] $result.Data['sources'] | Should -BeGreaterThan 1
            [int] $result.Data['gathered'] | Should -BeGreaterThan 1
        }

        It 'reports how many facts it could not determine' {
            $context = & $script:newContext $null $script:cim
            $step = & $script:newStep $null

            $result = Invoke-HDTGatherStep -Step $step -Context $context

            $result.Data.Contains('undetermined') | Should -BeTrue
        }

        It 'says plainly that nothing changed rather than leaving a bare count' {
            # THE FACTS WERE ALREADY GATHERED DURING BOOTSTRAP - the same run
            # shows every GatheredFact resolved before this step started - so the
            # step re-gathers and compares. "20 machine facts gathered, 0
            # changed." leaves a reader unsure whether the step did anything.
            $context = & $script:newContext $null $script:cim
            $step = & $script:newStep $null

            # Gather twice: the second run has nothing to change.
            [void] (Invoke-HDTGatherStep -Step $step -Context $context)
            $result = Invoke-HDTGatherStep -Step $step -Context $context

            $result.Message | Should -Match 'none changed'
        }

        It 'groups the debug detail by the source it came from' {
            $context = & $script:newContext $null $script:cim
            $step = & $script:newStep $null

            [void] (Invoke-HDTGatherStep -Step $step -Context $context)

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event var.resolve)

            @($record | Where-Object { $_.message -match 'Win32_ComputerSystem' }) | Should -Not -BeNullOrEmpty
        }
    }
}

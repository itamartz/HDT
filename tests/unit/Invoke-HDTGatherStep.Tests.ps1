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
}

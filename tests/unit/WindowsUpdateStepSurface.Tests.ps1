# EVERY SURFACE THAT MUST KNOW ABOUT A STEP TYPE, ASSERTED AGAINST THE SET.
#
# CLAUDE.md rule 8: "a thing is not added until every surface that must know
# about it does - and it is proven with a test written against the SET, not
# against the one you just added. A test that names your new thing passes for it
# and fails nobody after it."
#
# Invoke-HDTWindowsUpdateStep landed in plan 08-01-03 and the registry
# discovered it immediately - and every authoring surface stayed silent. The
# type could be RUN by a sequence that already named it and could not be
# CREATED by anything: no template, so CanAdd was false and the Add menu left it
# out; no description, so the log and the progress display fell back to
# '<Type>: <name>'; no properties rows; and the step contract's hand-written
# list did not name it, which is the one surface that DID go red - one failing
# assertion out of 276 for a type that was invisible in five other places.
#
# So the first Describe in this file walks Get-HDTStepType and the files on disk
# and asks the question for EVERY type. It goes red for the next step type
# anybody adds, in whichever surface they forget.
#
# WHERE AN EXISTING TEST ALREADY WALKS THE SET, THIS FILE DOES NOT WALK IT
# AGAIN - a second copy of a set assertion is a second thing to keep in step:
#
#   tests/unit/ConsoleStepCatalog.Tests.ps1  'offers all of them and invents
#       none' compares the menu against Get-HDTStepType in both directions
#   tests/unit/StepPropertyDefinition.Tests.ps1  'lists every row in the order
#       its own template writes the keys' walks every templated type
#   tests/contract/StepTemplate.Contract.Tests.ps1  parses the YAML of every
#       registered template and checks the type it declares
#   tests/contract/StepContract.Tests.ps1  compares its expected list against
#       the step files on disk, both directions
#
# What is asserted here is what none of those cover.

# THE SAMPLE LIST LIVES AT FILE SCOPE, NOT IN A BeforeAll, AND THAT IS NOT A
# STYLE CHOICE. -ForEach is read while Pester is DISCOVERING; a BeforeAll runs
# later, so a list built there is $null at the moment the cases would be
# generated and Pester quietly generates NONE - and a Describe with no cases is
# reported as a pass. That is how six assertions in this file came back green by
# not existing, in a run that said 37 tests where 43 were written.
#
# DESIGN 10.1: "Placement: conventionally run twice - once before applications,
# once after - since app installs can pull in updatable components. The sample
# sequences do this." The Describe below is that sentence made checkable, and it
# walks BOTH samples rather than the one that was edited first.
# AND IT IS READ OFF THE DISK, NOT WRITTEN OUT. The STD-* samples are the two
# this repository offers as "how you would really write one" - DEMO-* are
# mechanism demonstrations for one feature each - so a third STD- sample added
# later is walked on the day it appears rather than quietly exempted. The guard
# below reads the same folder a second time and says how many it found, so an
# empty list fails loudly instead of generating no cases at all.
$script:HDTSample = @(Get-ChildItem -LiteralPath (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'samples/workspace/TaskSequences') -Directory |
        Where-Object { $_.Name -like 'STD-*' } |
        ForEach-Object { @{ Name = $_.Name; Path = (Join-Path -Path $_.FullName -ChildPath 'sequence.yaml') } })

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name powershell-yaml -ErrorAction Stop

    $script:stepFileRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps'

    # The type names this repository SHIPS, read off the files rather than off
    # the registry: deriving both sides of a comparison from the registry checks
    # the registry against itself.
    $script:shipped = @(Get-ChildItem -LiteralPath $script:stepFileRoot -Filter 'Invoke-HDT*Step.ps1' -File |
            ForEach-Object { $_.BaseName -replace '^Invoke-HDT', '' -replace 'Step$', '' } |
            Sort-Object)

    $script:registry = @(Get-HDTStepType | Where-Object { $_.Source -eq 'Hephaestus' })

    # A sequence document that loads, so a template's lines can be spliced into
    # something Import-HDTSequenceDocument will read.
    $script:newDocument = {
        param([string[]] $Line)

        $indented = @($Line | ForEach-Object { '  ' + $_ })

        return [string[]] @(
            'schemaVersion: 1'
            'id: SURFACE'
            'name: Surface probe'
            'steps:'
        ) + $indented
    }
}

Describe 'Every step type reaches every surface it has to' {

    It 'ships an Invoke command for more than fifteen types' {
        # A guard on the guards below: if the file walk ever answers nothing,
        # every set assertion here passes vacuously.
        @($script:shipped).Count | Should -BeGreaterThan 15
    }

    It 'has a template for every type it ships' {
        $missing = @($script:shipped | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path -Path $script:stepFileRoot -ChildPath ('Get-HDT{0}StepTemplate.ps1' -f $_)))
            })

        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a type with no template cannot be created by anything - not the console, not Add-HDTStep - so it is a type that runs and cannot be authored'
    }

    It 'has a description for every type it ships' {
        $missing = @($script:shipped | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path -Path $script:stepFileRoot -ChildPath ('Get-HDT{0}StepDescription.ps1' -f $_)))
            })

        $missing -join ', ' | Should -BeNullOrEmpty -Because 'without one the master log and the progress display name the step "<Type>: <name>" and say nothing about what it will do'
    }

    It 'exports every step command it ships from the manifest' {
        # THE REGISTRY FINDS COMMANDS, NOT FILES. Get-HDTStepType walks
        # Get-Command over the loaded modules, so a step command left out of
        # FunctionsToExport does not exist as far as the engine is concerned -
        # and the failure is silent: the type simply reports CanAdd false.
        $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1')
        $exported = @($manifest.FunctionsToExport)

        $onDisk = @(Get-ChildItem -LiteralPath $script:stepFileRoot -Filter '*.ps1' -File | ForEach-Object { $_.BaseName })

        $missing = @($onDisk | Where-Object { $exported -notcontains $_ })

        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a public command missing from FunctionsToExport does not exist'
    }

    It 'gives every creatable type a shelf of its own rather than leaving it under Custom' {
        # Custom is for a third-party type out of Modules\ (CLAUDE.md rule 3):
        # being absent from the catalog's curated table is not a reason to be
        # unbuildable. But a type THIS repository ships and does not name in
        # that table is an oversight, and it looks exactly like a working menu.
        #
        # The existing ConsoleStepCatalog test asserts the menu offers every
        # registered type and invents none; it does not care which shelf.
        $catalog = @(InModuleScope Hephaestus { Get-HDTConsoleStepCatalog })

        $custom = @($catalog | Where-Object { $_.Category -eq 'Custom' } |
                ForEach-Object { $_.Item } | ForEach-Object { [string] $_.Type })

        $custom -join ', ' | Should -BeNullOrEmpty -Because 'a type Hephaestus ships and Get-HDTConsoleStepCatalog''s $known table does not name is offered under Custom, named by its type rather than by the words an administrator is looking for'
    }

    It 'gives every creatable type either properties rows or a page of its own' {
        # THE FIVE TYPES THAT OWN A PAGE. Each has its own tab in
        # New-HDTConsoleEditorView, and the generic sheet is collapsed for them
        # entirely - a key listed in both places is a key that can disagree with
        # itself while both boxes look right (Get-HDTStepPropertyDefinition
        # says so in its own help).
        $page = @('ApplyImage', 'CommandLine', 'DiskPartition', 'InstallApplications', 'Validate')

        # The list cannot rot into naming a type that no longer exists.
        @($page | Where-Object { $script:shipped -notcontains $_ }) |
            Should -BeNullOrEmpty -Because 'the dedicated-page list above names a type this repository no longer ships'

        $bare = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in @($script:registry | Where-Object { $_.CanAdd })) {
            $type = [string] $current.Type

            if ($page -contains $type) { continue }

            # A TEMPLATE THAT WRITES NO KEYS HAS NOTHING TO OFFER. Gather is the
            # real case: its template is name and type, the step takes no
            # settings, and an empty sheet is the correct answer rather than a
            # missing one. So the question is only asked of a type whose own
            # template writes at least one key of its own.
            $key = @(@(& $current.TemplateCommand.Name) |
                    ForEach-Object { if ($_ -match '^\s{2}([A-Za-z][A-Za-z0-9]*):') { [string] $Matches[1] } } |
                    Where-Object { $_ -notin @('type', 'runIn', 'continueOnError', 'timeoutMinutes', 'condition', 'disabled', 'retry', 'resumable', 'log') })

            if (@($key).Count -eq 0) { continue }

            $row = @(InModuleScope Hephaestus -Parameters @{ T = $type } {
                    Get-HDTStepPropertyDefinition -Type $T
                })

            if (@($row).Count -eq 0) { [void] $bare.Add($type) }
        }

        ($bare -join ', ') | Should -BeNullOrEmpty -Because 'a type whose template writes settings and whose Properties sheet offers no row can only be edited by opening the YAML somewhere else'
    }

    It 'names every type it ships in the step contract''s expected list' {
        # tests/contract/StepContract.Tests.ps1 already compares its list
        # against the files on disk. This asserts the one direction that matters
        # from here: the new type is on it, so every per-type assertion in that
        # file runs for it too.
        $contract = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/contract/StepContract.Tests.ps1') -Raw

        $missing = @($script:shipped | Where-Object { $contract -notmatch ("'{0}'" -f [regex]::Escape($_)) })

        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a type absent from $script:HDTExpectedStepType is a type nothing in the step contract is watching'
    }
}

Describe 'Get-HDTWindowsUpdateStepTemplate' {

    BeforeAll {
        $script:line = @(Get-HDTWindowsUpdateStepTemplate)
        $script:yaml = ConvertFrom-Yaml -Yaml ($script:line -join "`n") -Ordered
    }

    It 'is exported by the module' {
        @(Get-Command -Name 'Get-HDTWindowsUpdateStepTemplate' -Module 'Hephaestus' -ErrorAction SilentlyContinue).Count |
            Should -Be 1
    }

    It 'makes the type creatable' {
        $type = @(Get-HDTStepType -Name 'WindowsUpdate')

        @($type).Count | Should -Be 1
        $type[0].CanAdd | Should -BeTrue
    }

    It 'writes a step whose type is WindowsUpdate' {
        [string] $script:yaml[0]['type'] | Should -BeExactly 'WindowsUpdate'
    }

    It 'writes runIn FullOS, because the agent does not exist in WinPE' {
        [string] $script:yaml[0]['runIn'] | Should -BeExactly 'FullOS'
    }

    It 'reads the server from the HDTWSUSServer variable' {
        [string] $script:yaml[0]['server'] | Should -BeExactly '%HDTWSUSServer%'
    }

    It 'writes continueOnError true, the recommended default' {
        $script:yaml[0]['continueOnError'] | Should -BeTrue
    }

    It 'writes maxPasses 3, so an author can see that the step loops' {
        [int] $script:yaml[0]['maxPasses'] | Should -Be 3
    }

    It 'writes a categories list' {
        $category = @($script:yaml[0]['categories'])

        $category.Count | Should -BeGreaterThan 0
        $category | Should -Contain 'SecurityUpdates'
        $category | Should -Contain 'CriticalUpdates'
    }

    It 'quotes the variable token so the document loads' {
        # StepTemplate.Contract.Tests.ps1 exists because ApplyDrivers shipped a
        # DOUBLE-quoted scalar with a backslash in it and no parser would open
        # the result. Single quotes are literal.
        @($script:line | Where-Object { $_ -match '^\s*server:' }) |
            Should -Be @("  server: '%HDTWSUSServer%'")
    }

    It 'produces YAML that Import-HDTSequenceDocument accepts' {
        $path = Join-Path -Path $TestDrive -ChildPath 'sequence.yaml'
        Set-Content -LiteralPath $path -Value (& $script:newDocument $script:line) -Encoding UTF8

        { Import-HDTSequenceDocument -Path $path } | Should -Not -Throw
    }

    It 'takes a name and uses it' {
        $named = @(Get-HDTWindowsUpdateStepTemplate -Name 'Patch the thing')

        $named[0] | Should -BeExactly '- name: Patch the thing'
    }

    It 'defaults to the name the console offers it under' {
        $script:line[0] | Should -BeExactly '- name: Windows Update'
    }

    It 'writes a server key the step will refuse until the variable is set' {
        # THE TEMPLATE AND THE STEP HAVE TO AGREE ABOUT THIS, and for a while
        # the help above said they did not: it claimed an unset HDTWSUSServer
        # "means Windows Update", which is what an ABSENT server key does.
        # An UNSET VARIABLE leaves the token literal and the step refuses it,
        # deliberately - writing '%HDTWSUSServer%' into the WUServer policy
        # takes a machine off Windows Update without putting it onto anything.
        #
        # This pins the pair so the prose cannot drift from the code again: the
        # template writes the token, the step names the token in its refusal,
        # and the refusal says the two ways out.
        $refusal = (Get-Command -Name 'Invoke-HDTWindowsUpdateStep').ScriptBlock.ToString()

        $refusal | Should -Match 'variable token nothing resolved'
        $refusal | Should -Match 'remove the server key'

        @($script:line | Where-Object { $_ -match '^\s*server:' }).Count | Should -Be 1
    }
}

Describe 'Get-HDTWindowsUpdateStepDescription' {

    BeforeAll {
        $script:newStep = {
            param([hashtable] $Property)

            return [pscustomobject] @{ Name = 'Windows Update'; Type = 'WindowsUpdate'; Property = $Property }
        }
    }

    It 'reports the variable rather than guessing at what it will hold' {
        Get-HDTWindowsUpdateStepDescription -Step (& $script:newStep @{ 'server' = '%HDTWSUSServer%' }) |
            Should -BeExactly 'WindowsUpdate: %HDTWSUSServer%, up to 3 passes'
    }

    It 'names the server the step will use' {
        Get-HDTWindowsUpdateStepDescription -Step (& $script:newStep @{ 'server' = 'http://wsus:8530' }) |
            Should -BeExactly 'WindowsUpdate: http://wsus:8530, up to 3 passes'
    }

    It 'says Windows Update when the step names no server' {
        Get-HDTWindowsUpdateStepDescription -Step (& $script:newStep @{}) |
            Should -BeExactly 'WindowsUpdate: Windows Update, up to 3 passes'
    }

    It 'says Windows Update when the server is set to nothing' {
        Get-HDTWindowsUpdateStepDescription -Step (& $script:newStep @{ 'server' = '' }) |
            Should -BeExactly 'WindowsUpdate: Windows Update, up to 3 passes'
    }

    It 'mentions the pass limit the step was authored with' {
        Get-HDTWindowsUpdateStepDescription -Step (& $script:newStep @{ 'maxPasses' = 5 }) |
            Should -BeExactly 'WindowsUpdate: Windows Update, up to 5 passes'
    }

    It 'is the line the dispatcher hands the log' {
        $step = & $script:newStep @{ 'server' = '%HDTWSUSServer%' }

        Get-HDTStepDescription -Step $step |
            Should -BeExactly 'WindowsUpdate: %HDTWSUSServer%, up to 3 passes'
    }
}

Describe 'The properties sheet offers what DESIGN 10.1 documents' {

    BeforeAll {
        $script:row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'WindowsUpdate' })
    }

    It 'offers server, categories, exclude and maxPasses' {
        @($script:row | ForEach-Object { [string] $_.Key }) |
            Should -Be @('server', 'categories', 'exclude', 'maxPasses')
    }

    It 'offers categories as the closed set the step accepts' {
        $category = @($script:row | Where-Object { $_.Key -eq 'categories' })[0]

        $category.Kind | Should -BeExactly 'List'
        $category.Choice | Should -Contain 'SecurityUpdates'
        $category.Choice | Should -Contain 'DefinitionUpdates'
    }

    It 'reads that closed set from Get-HDTStepPropertyChoice rather than spelling it again' {
        @(InModuleScope Hephaestus { Get-HDTStepPropertyChoice -Type 'WindowsUpdate' -Key 'categories' }).Count |
            Should -BeGreaterThan 5
    }

    It 'tells an author that one pass leaves a machine half-patched' {
        $pass = @($script:row | Where-Object { $_.Key -eq 'maxPasses' })[0]

        $pass.Default | Should -BeExactly '3'
        $pass.Hint | Should -Not -BeNullOrEmpty
    }

    It 'keeps every hint to one or two lines' {
        # CLAUDE.md has written this rule down twice: four lines of explanation
        # under one control is a screen explaining itself at the cost of the
        # controls around it. The reasoning goes in the comment above the row.
        $long = @($script:row | Where-Object { ([string] $_.Hint).Length -gt 200 } | ForEach-Object { [string] $_.Key })

        $long -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'The document surfaces accept every key DESIGN 10.1 documents' {

    BeforeAll {
        $script:full = [string[]] @(
            '- name: Windows Update'
            '  type: WindowsUpdate'
            "  server: '%HDTWSUSServer%'"
            '  categories: [SecurityUpdates, CriticalUpdates, UpdateRollups]'
            '  exclude: [KB5001234, ''*Preview*'']'
            '  maxPasses: 3'
            '  continueOnError: true'
            '  runIn: FullOS'
        )
    }

    It 'accepts a WindowsUpdate step with every key DESIGN 10.1 documents' {
        # CLAUDE.md names the validator as a surface precisely because a new key
        # is invisible until it is listed there. This proves the answer by test
        # rather than by reading: the step node's own extra keys pass through.
        $path = Join-Path -Path $TestDrive -ChildPath 'full.yaml'
        Set-Content -LiteralPath $path -Value (& $script:newDocument $script:full) -Encoding UTF8

        { Import-HDTSequenceDocument -Path $path } | Should -Not -Throw
    }

    It 'carries the keys through to the step''s Property bag' {
        $path = Join-Path -Path $TestDrive -ChildPath 'full.yaml'
        Set-Content -LiteralPath $path -Value (& $script:newDocument $script:full) -Encoding UTF8

        $step = @((Import-HDTSequenceDocument -Path $path).Step | Where-Object { $_.Type -eq 'WindowsUpdate' })[0]

        [string] $step.Property['server'] | Should -BeExactly '%HDTWSUSServer%'
        @($step.Property['categories']).Count | Should -Be 3
        @($step.Property['exclude']).Count | Should -Be 2
        [int] $step.Property['maxPasses'] | Should -Be 3
    }

    # THE JSON SCHEMA IS NOT CHECKED HERE, AND THAT IS DELIBERATE. Test-Json
    # does not exist on Windows PowerShell 5.1, which is the gate and the only
    # shell this suite runs under, so an assertion using it would report a pass
    # it never made. tests/contract/SequenceSchema.Contract.Tests.ps1 skips
    # itself on that same predicate and is where the schema is judged.
    #
    # What is asserted instead is the validator that actually runs in WinPE:
    # Assert-HDTSequenceDocument, reached through Import-HDTSequenceDocument
    # above. The schema's own coverage of this step comes from the fixture
    # tests/fixtures/sequences/valid-windows-update.yaml, which that contract
    # picks up by wildcard the moment it runs on a shell that has Test-Json.
    It 'ships a schema fixture carrying the step, for the leg that can judge it' {
        $fixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences/valid-windows-update.yaml'

        Test-Path -LiteralPath $fixture | Should -BeTrue

        { Import-HDTSequenceDocument -Path $fixture } | Should -Not -Throw
    }
}


Describe 'The sample sequences show the convention' {

    It 'generated a case for each sample this repository ships' {
        # THE GUARD ON THE -ForEach BELOW, AND IT READS THE FOLDER AGAIN RATHER
        # THAN THE LIST. An empty -ForEach makes Pester generate no cases at
        # all, and a Describe with no cases is reported as a pass - which is
        # exactly what happened while that list was built in a BeforeAll: six
        # assertions came back green by not existing, in a run that said 37
        # tests where 43 were written.
        #
        # It cannot be asserted against $script:HDTSample itself: a variable set
        # at file scope is in hand while Pester DISCOVERS and is $null in a test
        # BODY, and @($null).Count is 1 - so the obvious version of this guard
        # passes for the wrong reason on an empty list and fails for the wrong
        # reason on a full one.
        $sequence = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences') -Directory |
                Where-Object { $_.Name -like 'STD-*' })

        @($sequence).Count | Should -Be 2 -Because 'the cases below are generated from this same folder, so a count that moved means either a new sample nobody walked or a list that came back empty'

        foreach ($one in $sequence) {
            Test-Path -LiteralPath (Join-Path -Path $one.FullName -ChildPath 'sequence.yaml') |
                Should -BeTrue -Because ('{0} is a sample folder with no sequence.yaml in it' -f $one.Name)
        }
    }

    It 'imports <Name> without error' -ForEach $script:HDTSample {
        { Import-HDTSequenceDocument -Path $Path } | Should -Not -Throw
    }

    It 'runs Windows Update twice in <Name>' -ForEach $script:HDTSample {
        $step = @((Import-HDTSequenceDocument -Path $Path).Step | Where-Object { $_.Type -eq 'WindowsUpdate' })

        @($step).Count | Should -Be 2
    }

    It 'brackets the applications step with them in <Name>' -ForEach $script:HDTSample {
        # THE ORDER IS THE POINT, not the count. The first pass patches the base
        # image so an installer meets a current machine; the second catches the
        # updatable components an install pulled in - .NET, the VC runtimes, a
        # driver an application shipped. Two passes both AFTER the applications
        # would be two of the second one.
        $step = @((Import-HDTSequenceDocument -Path $Path).Step)

        $update = @($step | Where-Object { $_.Type -eq 'WindowsUpdate' } | ForEach-Object { [int] $_.Index })
        $application = @($step | Where-Object { $_.Type -eq 'InstallApplications' } | ForEach-Object { [int] $_.Index })

        @($application).Count | Should -Be 1
        @($update | Where-Object { $_ -lt $application[0] }).Count | Should -Be 1
        @($update | Where-Object { $_ -gt $application[0] }).Count | Should -Be 1
    }

    It 'runs every instance in the full OS in <Name>' -ForEach $script:HDTSample {
        # WUA does not exist in WinPE. Import-HDTSequenceDocument refuses the
        # type in a WinPE group, so a sample that got this wrong would fail the
        # import assertion above - this says which of the two things broke.
        $step = @((Import-HDTSequenceDocument -Path $Path).Step | Where-Object { $_.Type -eq 'WindowsUpdate' })

        @($step | ForEach-Object { [string] $_.RunIn } | Sort-Object -Unique) | Should -Be @('FullOS')
    }

    It 'names them as MDT names its own two instances, in <Name>' -ForEach $script:HDTSample {
        # An administrator arriving from Workbench is looking for these words.
        # Read from MDT's own Templates\Client.xml on this host rather than
        # remembered: <step name="Windows Update (Pre-Application Installation)"
        # disable="true" continueOnError="true">, and the same for the Post one.
        $name = @((Import-HDTSequenceDocument -Path $Path).Step |
                Where-Object { $_.Type -eq 'WindowsUpdate' } | ForEach-Object { [string] $_.Name })

        $name | Should -Be @('Windows Update (Pre-Application Installation)', 'Windows Update (Post-Application Installation)')
    }

    It 'leaves no commented-out WindowsUpdate step behind in <Name>' -ForEach $script:HDTSample {
        # STD-CLIENT carried the step commented out with a note saying it was
        # v2. A comment that is now wrong is worse than no comment: it is the
        # file telling an administrator the feature does not exist.
        $commented = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^\s*#.*type:\s*WindowsUpdate' })

        $commented -join ' | ' | Should -BeNullOrEmpty
    }
}

Describe 'The shipped client template, which is the file every new workspace is seeded from' {

    BeforeAll {
        # CLAUDE.md's own table, first row: "client.yaml authored partitions
        # with no drive letter and could not partition a disk. Templates were
        # parsed and schema-checked; nothing ever PLANNED one." The samples are
        # not a substitute for it - a technician who runs New-HDTWorkspace gets
        # client.yaml, not STD-CLIENT.
        $script:templatePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/client.yaml'
        $script:template = Import-HDTSequenceDocument -Path $script:templatePath
    }

    It 'still imports' {
        { Import-HDTSequenceDocument -Path $script:templatePath } | Should -Not -Throw
    }

    It 'ships both Windows Update steps' {
        @($script:template.Step | Where-Object { $_.Type -eq 'WindowsUpdate' }).Count | Should -Be 2
    }

    It 'ships them disabled, as MDT''s Client.xml does' {
        # CHECKED RATHER THAN REMEMBERED: MDT's own Templates\Client.xml on this
        # host ships both with disable="true". MEMORY, "HDT is a homage to MDT":
        # when MDT and a fresh idea disagree about behaviour, build MDT's.
        #
        # And the reason stands on its own. A template that patched by default
        # would send every new workspace's first deployment to Windows Update
        # over the internet, unasked, on a bench where somebody was expecting
        # the image's own patch level.
        $step = @($script:template.Step | Where-Object { $_.Type -eq 'WindowsUpdate' })

        @($step | ForEach-Object { [bool] $_.Disabled }) | Should -Be @($true, $true)
    }

    It 'brackets Install Applications with them' {
        $step = @($script:template.Step)

        $update = @($step | Where-Object { $_.Type -eq 'WindowsUpdate' } | ForEach-Object { [int] $_.Index })
        $application = @($step | Where-Object { $_.Type -eq 'InstallApplications' } | ForEach-Object { [int] $_.Index })

        @($application).Count | Should -Be 1
        @($update | Where-Object { $_ -lt $application[0] }).Count | Should -Be 1
        @($update | Where-Object { $_ -gt $application[0] }).Count | Should -Be 1
    }

    It 'points them at the HDTWSUSServer variable rather than at a server' {
        $step = @($script:template.Step | Where-Object { $_.Type -eq 'WindowsUpdate' })

        @($step | ForEach-Object { [string] $_.Property['server'] } | Sort-Object -Unique) |
            Should -Be @('%HDTWSUSServer%')
    }
}

Describe 'No document still calls the step deferred' {

    # THE DEFERRAL HISTORY IS KEPT, NOT DELETED - a line saying it was deferred
    # on one date and BUILT on another is the record this repository wants. What
    # must not survive is a line still telling a reader, in the present tense,
    # that the step does not exist.
    It 'says nothing in <Name> about WindowsUpdate being deferred or unbuilt' -ForEach @(
        @{ Name = 'docs/DESIGN.md' }
        @{ Name = 'docs/ROADMAP.md' }
        @{ Name = 'samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml' }
        @{ Name = 'samples/workspace/TaskSequences/STD-SERVER/sequence.yaml' }
        @{ Name = 'src/Hephaestus/Templates/client.yaml' }
    ) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $line = @(Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath $Name))

        # BOTH SPELLINGS OF THE NAME. The type is 'WindowsUpdate' and the
        # section heading is '10.1 Windows Update', and the heading is where the
        # DEFERRED TO v2 marker lived - so a filter on the type name alone would
        # have read straight past it.
        # THE HISTORY MAY STAY, AND ON THE SAME LINE IT MUST SAY SO. A sentence
        # recording that the step was deferred on one date and BUILT on another
        # is the record this repository wants - the deferral is why the section
        # reads the way it does. What must not survive is a line that stops at
        # the deferral, because a reader who lands on that line alone is being
        # told, in the present tense, that the feature does not exist.
        $stale = @($line | Where-Object {
                $_ -match '(?i)(WindowsUpdate|10\.1 Windows Update)' -and
                $_ -match '(?i)(deferred to v2|is v2\b|scheduled out|not built|does not exist|when the step type ships|no .WindowsUpdate. step)' -and
                $_ -notmatch '(?i)(built on|built in|came back|~~)'
            })

        $stale -join ' | ' | Should -BeNullOrEmpty -Because 'the step is built, and a document saying otherwise is the repository telling an administrator a feature is missing'
    }
}

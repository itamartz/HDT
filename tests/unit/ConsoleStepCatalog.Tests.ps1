# The Add menu, and the Options tab.
#
# THE ADD BUTTON IS A MENU, WHICH IS DEPLOYMENT WORKBENCH'S SHAPE. MDT and
# ConfigMgr both put a drop-down on Add that lists the step types by category -
# General, Disks, Images - and an administrator picks the step they want rather
# than typing a type name. CLAUDE.md asks for a console close enough that muscle
# memory transfers, so the menu is built here and asserted here; the window only
# hangs the items off a button.
#
# THE LIST COMES FROM Get-HDTStepType, NOT FROM A LITERAL. That cmdlet is the
# engine's registry and it discovers third-party step types dropped into
# Modules\ (DESIGN 5.4). A hard-coded menu would offer nine of them and quietly
# omit the tenth that somebody had just installed - which is the failure that is
# hardest to notice, because the menu still looks complete.
#
# A TYPE THE CATALOG HAS NO ENTRY FOR IS STILL OFFERED. It lands under Custom,
# named by its own type. Being absent from a curated list is not a reason to be
# unbuildable.
#
# THE OPTIONS TAB IS THE SECOND HALF. MDT puts "Disable this step", "Continue on
# error" and the condition list on a tab beside Properties;
# Get-HDTConsoleStepOption decides every row of it, so the checkbox states and
# the cmdlet each one shows can be asserted without a window.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'Get-HDTConsoleStepCatalog' {

    BeforeAll {
        $script:catalog = @(Get-HDTConsoleStepCatalog)
        $script:item = @($script:catalog | ForEach-Object { $_.Item })
    }

    Context 'the shape of the menu' {

        It 'returns categories, each holding items' {
            $script:catalog.Count | Should -BeGreaterThan 1

            foreach ($category in $script:catalog) {
                $category.Category | Should -Not -BeNullOrEmpty
                @($category.Item).Count | Should -BeGreaterThan 0
            }
        }

        It 'opens with New Group, the way Workbench does' {
            $script:catalog[0].Item[0].Text | Should -BeExactly 'New Group'
            $script:catalog[0].Item[0].Kind | Should -BeExactly 'Group'
        }

        It 'gives every item the YAML it would insert, so the window branches on nothing' {
            # The handler behind the menu calls Add-HDTStep -Block for
            # every item, group and step alike. If the item carried only a type,
            # the window would have to choose a parameter set - which is a
            # decision, and decisions do not go in an adapter (CLAUDE.md rule 1).
            foreach ($entry in $script:item) {
                @($entry.Block).Count | Should -BeGreaterThan 1
                $entry.Block[0] | Should -BeLike '- *'
            }
        }

        It 'writes a step block the engine reads back as that step' {
            $entry = @($script:item | Where-Object { $_.Type -eq 'CommandLine' })[0]

            $entry.Block[0] | Should -BeExactly '- name: Run Command Line'
            $entry.Block[1] | Should -BeExactly '  type: CommandLine'
        }

        It 'writes a group block with somewhere to put steps' {
            $entry = $script:catalog[0].Item[0]

            $entry.Block[0] | Should -BeExactly '- group: New Group'
            $entry.Block[1] | Should -BeExactly '  steps: []'
        }

        It 'adds a group and nothing else' {
            # NEW GROUP MEANS A NEW GROUP. It used to arrive carrying a NoOp step
            # because the engine refused an empty group, so the button an
            # administrator pressed to make a shelf made a shelf and a thing on
            # it that they then had to delete. The engine accepts an empty group
            # now, and the passenger went with the refusal.
            $entry = $script:catalog[0].Item[0]

            @($entry.Block).Count | Should -Be 2
            @($entry.Block) | Should -Not -Contain '    - name: New Step'
            @($entry.Block -match 'type:') | Should -BeNullOrEmpty
        }

        It 'produces a document the engine still reads after the group is added' {
            # The benchmark for every item in this menu: press it and the editor
            # can still draw a tree.
            $line = [string[]] @(
                'schemaVersion: 1'
                'id: DEMO'
                'name: Demo'
                'steps:'
                '  - name: Apply OS'
                '    type: ApplyImage'
            )

            foreach ($entry in $script:item) {
                $edited = @(Add-HDTStep -Line $line -After 'Apply OS' -Block $entry.Block)
                $state = Get-HDTConsoleEditorState -Line $edited -Path 'C:\ws\TaskSequences\DEMO\sequence.yaml'

                $state.Status | Should -BeExactly 'Ok' -Because ("adding '{0}' must leave a readable document, and it said: {1}" -f $entry.Text, $state.Message)
            }
        }

        It 'gives every step item a type, a display name and the cmdlet that adds it' {
            foreach ($entry in @($script:item | Where-Object { $_.Kind -eq 'Step' })) {
                $entry.Type | Should -Not -BeNullOrEmpty
                $entry.Text | Should -Not -BeNullOrEmpty
                $entry.Command | Should -BeLike 'Add-HDTStep *'
                $entry.Command | Should -BeLike ('*-Type {0}*' -f $entry.Type)
            }
        }
    }

    Context 'every type the engine has' {

        It 'offers all of them and invents none' {
            $known = @(Get-HDTStepType | ForEach-Object { $_.Type } | Sort-Object)

            # NOT A VACUOUS COMPARISON. Get-HDTStepType discovers step types by
            # walking Get-Module, so in a session where the engine is not listed
            # it returns nothing - and an empty list matches an empty list,
            # which is how the first version of this test passed while the Add
            # menu on screen offered New Group and nothing else. The floor is
            # the ten types the engine ships.
            @($known).Count | Should -BeGreaterOrEqual 10

            # DISTINCT, BECAUSE A TYPE MAY BE OFFERED MORE THAN ONCE. MDT's own
            # sequence carries two Format and Partition Disk steps - one per
            # firmware - so the menu does too. What must not happen is a type on
            # the menu that the engine does not have, or one it has that the
            # menu does not offer; both are still asserted.
            $offered = @($script:item | Where-Object { $_.Kind -eq 'Step' } |
                    ForEach-Object { $_.Type } | Sort-Object -Unique)

            $offered | Should -Be $known
        }

        It 'offers the firmware pair MDT ships, and both write a real layout' {
            $disk = @($script:item | Where-Object { $_.Type -eq 'DiskPartition' })

            @($disk).Count | Should -Be 2
            @($disk | ForEach-Object { $_.Text }) |
                Should -Be @('Format and Partition Disk (UEFI)', 'Format and Partition Disk (BIOS)')

            # THE UEFI ONE IS FIRST. The list is read top to bottom by somebody
            # choosing, and a machine bought this decade is UEFI.
            foreach ($one in $disk) {
                $layout = @($one.Block | Where-Object { $_ -match '^\s*layout:' })
                @($layout).Count | Should -Be 1

                { Get-HDTDiskLayout -Name ([string] ($layout[0] -replace '^\s*layout:\s*', '')) } |
                    Should -Not -Throw
            }
        }

        It 'offers them to a session that ran nothing but the one import' {
            # THE REGRESSION, AND WHY THE MODULES ARE ONE. An administrator runs
            # Start-HDTConsole.ps1, which imports a manifest and nothing else.
            # Get-HDTStepType walks Get-Module, and a NESTED import is not listed
            # there - so when the console was a second module importing the
            # engine for its own use, the menu came up empty on the one path that
            # matters and full under every test, which import the engine
            # themselves. A fresh process, so nothing this session loaded can
            # stand in for the import under test.
            $manifest = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'

            # Asked from inside the module, because that is where the catalog
            # is now: it builds the Add menu and nobody types it. The regression
            # it guards is unchanged - a bare import has to leave Get-HDTStepType
            # able to see the step types.
            $count = & powershell.exe -NoProfile -Command (
                "Import-Module '$manifest' -Force; " +
                '& (Get-Module Hephaestus) { @(Get-HDTConsoleStepCatalog).Count }')

            [int] $count | Should -BeGreaterThan 1
        }

        It 'gives the common ones the name an MDT administrator already knows' {
            $byType = @{}
            foreach ($entry in $script:item) { if ($entry.Kind -eq 'Step') { $byType[$entry.Type] = $entry } }

            $byType['ApplyImage'].Text | Should -BeExactly 'Apply Operating System'

            # DiskPartition is offered twice, so the assertion is on the words
            # both entries share rather than on one exact string.
            $byType['DiskPartition'].Text | Should -BeLike 'Format and Partition Disk*'
            $byType['CommandLine'].Text | Should -BeExactly 'Run Command Line'
            $byType['PowerShell'].Text | Should -BeExactly 'Run PowerShell Script'
            $byType['SetVariable'].Text | Should -BeExactly 'Set Task Sequence Variable'
            $byType['Restart'].Text | Should -BeExactly 'Restart Computer'
        }

        It 'gives the 07 step types the names MDT uses for the same jobs' {
            # An administrator arriving from Workbench looks for the words they
            # already use: 'Install Roles and Features', not 'InstallRoles'.
            $byType = @{}
            foreach ($entry in $script:item) { if ($entry.Kind -eq 'Step') { $byType[$entry.Type] = $entry } }

            $byType['InstallApplications'].Text | Should -BeExactly 'Install Applications'
            $byType['InstallRoles'].Text | Should -BeExactly 'Install Roles and Features'
            $byType['EnableBitLocker'].Text | Should -BeExactly 'Enable BitLocker'
        }

        It 'files them under the categories those names live in' {
            $categoryOf = @{}
            foreach ($category in $script:catalog) {
                foreach ($entry in @($category.Item)) { $categoryOf[[string] $entry.Type] = $category.Category }
            }

            $categoryOf['DiskPartition'] | Should -BeExactly 'Disks'
            $categoryOf['ApplyImage'] | Should -BeExactly 'Images'
            $categoryOf['CommandLine'] | Should -BeExactly 'General'
        }

        It 'files the 07 step types where Workbench files them' {
            # BitLocker is a Disks job in Workbench, not a Settings one, and Roles
            # is its own shelf - a server sequence is mostly that one menu.
            $categoryOf = @{}
            foreach ($category in $script:catalog) {
                foreach ($entry in @($category.Item)) { $categoryOf[[string] $entry.Type] = $category.Category }
            }

            $categoryOf['InstallApplications'] | Should -BeExactly 'General'
            $categoryOf['EnableBitLocker'] | Should -BeExactly 'Disks'
            $categoryOf['InstallRoles'] | Should -BeExactly 'Roles'
        }

        It 'offers none of them under Custom' {
            # Custom is the shelf for a type this file has never heard of. A step
            # type HDT ships and forgot to name would land there and look like a
            # third-party one.
            $custom = @($script:catalog | Where-Object { $_.Category -eq 'Custom' })

            $offered = @()
            if ($custom.Count -gt 0) { $offered = @($custom[0].Item | ForEach-Object { [string] $_.Type }) }

            foreach ($type in @('InstallApplications', 'InstallRoles', 'EnableBitLocker')) {
                $offered | Should -Not -Contain $type
            }
        }

        It 'offers a type it has never heard of, under Custom' {
            # Being absent from this file's curated name table is not a reason to
            # be unofferable. Being unauthorable is - so the vendor row carries
            # the template command that makes it so, which is what a real
            # Get-HDTStepType row would have.
            $registry = @(
                [pscustomobject] @{ Type = 'CommandLine'; Source = 'Hephaestus'
                    TemplateCommand      = (Get-Command -Name 'Get-HDTCommandLineStepTemplate')
                }
                [pscustomobject] @{ Type = 'ContosoBitLocker'; Source = 'Contoso.Steps'
                    TemplateCommand      = (Get-Command -Name 'Get-HDTNoOpStepTemplate')
                }
            )

            $result = @(Get-HDTConsoleStepCatalog -StepType $registry)

            $custom = @($result | Where-Object { $_.Category -eq 'Custom' })
            @($custom).Count | Should -Be 1
            $custom[0].Item[0].Type | Should -BeExactly 'ContosoBitLocker'
            $custom[0].Item[0].Text | Should -BeExactly 'ContosoBitLocker'
            $custom[0].Item[0].Source | Should -BeExactly 'Contoso.Steps'
        }

        It 'leaves out a type the engine cannot author, however real it is' {
            # THE RULE THIS MENU EXISTS TO OBEY. The console is a wrapper around
            # the HDT command line: a menu item can only exist where a command
            # exists behind it. A vendor who shipped Invoke-HDT<Type>Step alone
            # has a type that RUNS - a sequence naming it executes unchanged -
            # and cannot be created from here, because nothing knows what to
            # write. The alternative is this window guessing the file format on
            # the engine's behalf, which is what it used to do.
            $registry = @(
                [pscustomobject] @{ Type = 'CommandLine'; Source = 'Hephaestus'
                    TemplateCommand      = (Get-Command -Name 'Get-HDTCommandLineStepTemplate')
                }
                [pscustomobject] @{ Type = 'ContosoOpaque'; Source = 'Contoso.Steps'; TemplateCommand = $null }
            )

            # NOT (...).Item - on an array that is the indexer, not the members.
            $offered = @(Get-HDTConsoleStepCatalog -StepType $registry |
                    ForEach-Object { $_.Item } |
                    Where-Object { $_.Kind -eq 'Step' } | ForEach-Object { $_.Type })

            $offered | Should -Not -Contain 'ContosoOpaque'
            $offered | Should -Contain 'CommandLine'
        }

        It 'takes each block from the step type rather than writing one' {
            # The proof that the YAML is not this file's: point the catalog at a
            # row whose template is another type's and the block follows the
            # template, not the row's Type.
            $registry = @(
                [pscustomobject] @{ Type = 'ContosoBitLocker'; Source = 'Contoso.Steps'
                    TemplateCommand      = (Get-Command -Name 'Get-HDTRestartStepTemplate')
                }
            )

            $entry = @(Get-HDTConsoleStepCatalog -StepType $registry |
                    ForEach-Object { $_.Item } | Where-Object { $_.Kind -eq 'Step' })[0]

            $entry.Block | Should -Contain '  type: Restart'
            $entry.Block | Should -Contain '  delaySeconds: 10'
        }

        It 'drops a category that has nothing in it rather than showing it empty' {
            $registry = @([pscustomobject] @{ Type = 'CommandLine'; Source = 'Hephaestus' })

            $result = @(Get-HDTConsoleStepCatalog -StepType $registry)

            @($result | Where-Object { $_.Category -eq 'Disks' }).Count | Should -Be 0
            @($result | Where-Object { $_.Category -eq 'Images' }).Count | Should -Be 0
        }
    }
}

Describe 'Get-HDTConsoleStepOption' {

    BeforeAll {
        $script:step = [pscustomobject] @{
            Index           = 3
            Name            = 'Apply OS'
            Type            = 'ApplyImage'
            GroupPath       = @('Install')
            Condition       = '$Model -like ''Virtual*'''
            ContinueOnError = $false
            Disabled        = $true
            RunIn           = 'WinPE'
            Property        = @{ index = 1 }
        }

        $script:group = [pscustomobject] @{
            Path      = @('Install')
            Condition = ''
            RunIn     = 'WinPE'
            Disabled  = $false
        }
    }

    Context 'a step' {

        BeforeAll { $script:option = Get-HDTConsoleStepOption -Step $script:step }

        It 'names the step and calls it a step' {
            $script:option.Name | Should -BeExactly 'Apply OS'
            $script:option.Kind | Should -BeExactly 'Step'
        }

        It 'carries both checkboxes, in Workbench''s wording and order' {
            @($script:option.Flag).Count | Should -Be 2
            $script:option.Flag[0].Label | Should -BeExactly 'Disable this step'
            $script:option.Flag[1].Label | Should -BeExactly 'Continue on error'
        }

        It 'has the disable box ticked, because this step is off' {
            $script:option.Flag[0].Checked | Should -BeTrue
            $script:option.Flag[1].Checked | Should -BeFalse
        }

        It 'shows the cmdlet each box would run, naming the step and the flag' {
            $script:option.Flag[0].Command | Should -BeLike '*Set-HDTStepFlag*'
            $script:option.Flag[0].Command | Should -BeLike "*-Name 'Apply OS'*"
            $script:option.Flag[0].Command | Should -BeLike '*-Flag Disabled*'
            $script:option.Flag[1].Command | Should -BeLike '*-Flag ContinueOnError*'
        }

        It 'unticking is what the command says, so pressing it twice is not the same press' {
            $script:option.Flag[0].Command | Should -BeLike '*-Value $false*'
            $script:option.Flag[1].Command | Should -BeLike '*-Value $true*'
        }
    }

    Context 'the condition, which is the filter that decides whether it runs' {

        It 'shows the expression the step actually carries' {
            $option = Get-HDTConsoleStepOption -Step $script:step

            $option.Condition | Should -BeExactly '$Model -like ''Virtual*'''
            $option.ConditionText | Should -BeExactly '$Model -like ''Virtual*'''
            $option.HasCondition | Should -BeTrue
        }

        It 'says so plainly when there is none, rather than showing an empty box' {
            $bare = [pscustomobject] @{
                Name = 'Prepare Boot'; Type = 'ConfigureBoot'; Condition = ''
                ContinueOnError = $false; Disabled = $false; RunIn = ''; GroupPath = @()
            }

            $option = Get-HDTConsoleStepOption -Step $bare

            $option.HasCondition | Should -BeFalse
            $option.ConditionText | Should -BeExactly '(none - this step always runs)'
        }

        It 'shows the cmdlet that would set it' {
            $option = Get-HDTConsoleStepOption -Step $script:step

            $option.ConditionCommand | Should -BeLike '*Set-HDTStepCondition*'
            $option.ConditionCommand | Should -BeLike "*-Name 'Apply OS'*"
        }

        It 'reports the phase the step is restricted to, because that filters it too' {
            $option = Get-HDTConsoleStepOption -Step $script:step

            $option.RunIn | Should -BeExactly 'WinPE'
            $option.RunInText | Should -BeExactly 'WinPE'
        }

        It 'says any phase when the step names none' {
            $bare = [pscustomobject] @{
                Name = 'Prepare Boot'; Type = 'ConfigureBoot'; Condition = ''
                ContinueOnError = $false; Disabled = $false; RunIn = ''; GroupPath = @()
            }

            (Get-HDTConsoleStepOption -Step $bare).RunInText | Should -BeExactly 'any phase'
        }
    }

    Context 'a group, which has no continue-on-error to offer' {

        BeforeAll { $script:groupOption = Get-HDTConsoleStepOption -Step $script:group }

        It 'takes its name from the last leg of its path' {
            $script:groupOption.Name | Should -BeExactly 'Install'
            $script:groupOption.Kind | Should -BeExactly 'Group'
        }

        It 'offers the disable box and nothing else' {
            @($script:groupOption.Flag).Count | Should -Be 1
            $script:groupOption.Flag[0].Label | Should -BeExactly 'Disable this group'
        }

        It 'still offers a condition, because a group carries one' {
            $script:groupOption.ConditionCommand | Should -BeLike "*-Name 'Install'*"
        }
    }
}


}

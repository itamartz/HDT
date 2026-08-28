# A TECHNICIAN PICKED A TASK SEQUENCE AND THE WIZARD THREW IT AWAY.
#
# The deployment failed in WinPE with "HDTConfigurationError: no task sequence
# was named ... nothing in the rules resolved HDTTaskSequenceID for this
# machine" - on a machine whose technician had just chosen one from the list.
#
# THE CHAIN, AND EVERY LINK OF IT WAS DOING ITS JOB. Get-HDTWizardSequence
# opened the picker on the first row because a list has to highlight something.
# New-HDTWizardHost.Apply recorded whatever it wrote into a box as a SEED.
# Test-HDTWizardAnswerChanged drops an answer equal to its seed, because a rule
# shown back to a technician is not something they typed and collecting it would
# claim in the provenance report that they had. So accepting the row the list
# opened on was indistinguishable from answering nothing, and HDTTaskSequenceID
# never entered the value bag.
#
# THE SEED MECHANISM IS RIGHT. WHAT WAS WRONG IS WHAT WAS BEING SEEDED: a value
# the WIZARD invented for itself, which no rule supplied and which carries no
# provenance worth protecting. So this file holds two things - the regression
# (picking the first row is collected) and the GENERAL FORM, asserted over the
# whole set of pages the module ships rather than over the task sequence alone,
# so the next invented default fails here instead of on a bench in WinPE.
#
# IT DRIVES THE REAL HOST. Apply runs against a retained visual tree with no
# desktop - ShowDialog is the only part of WPF that needs a window station, and
# nothing here calls it - so the seeding is provable rather than reasoned about.
# That is the same thing WizardHostReveal.Tests.ps1 does, for the same reason.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    # THE SHARE A NEW WORKSPACE GETS, built by the command that builds one. The
    # pages are read back out of it rather than off the module's template folder
    # so the definition, the markup and the projection are the ones a deployment
    # would meet.
    $script:workspaceRoot = 'C:\ws'

    $script:newShare = {
        $fileSystem = New-HDTFakeFileSystem -File @{

            # Three sequences, deliberately not in alphabetical order on disk.
            'C:\ws\TaskSequences\WIN11-LAB\sequence.yaml' =
            "schemaVersion: 1`nid: WIN11-LAB`nname: Windows 11 lab build`nsteps:`n  - name: Nothing`n    type: NoOp`n"
            'C:\ws\TaskSequences\001\sequence.yaml'       =
            "schemaVersion: 1`nid: '001'`nname: TS - Win 11 24H2 LTSC`nsteps:`n  - name: Nothing`n    type: NoOp`n"
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'   =
            "schemaVersion: 1`nid: DEMO-M4`nname: Windows 11 bare metal`nsteps:`n  - name: Nothing`n    type: NoOp`n"
        }

        [void] (New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-SEED' -FileSystem $fileSystem -Confirm:$false)

        return $fileSystem
    }

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }

    # THE PAGES, AS THE PAYLOAD READS THEM: the definition on the share, through
    # the engine's own reader, so nothing here holds a second copy of what a
    # page collects.
    $script:readPage = {
        param([object] $FileSystem)

        $provider = New-HDTLocalContentProvider -Root $script:workspaceRoot -FileSystem $FileSystem
        return @((Import-HDTWizardDocument -Provider $provider).Page)
    }

    # ONE PAGE, LOADED AND APPLIED - the same two calls Show-HDTWizardShell
    # makes for every page it swaps in.
    $script:applyPage = {
        param([object] $FileSystem, [object] $Page, [object[]] $Field, [object] $WizardHost)

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList (
            [xml] ([string] $FileSystem.ReadAllText([string] $Page.XamlPath)))

        $root = [System.Windows.Markup.XamlReader]::Load($reader)
        $WizardHost.Apply($root, @($Field), @())

        return $root
    }

    $script:seedOf = {
        param([object] $WizardHost, [string] $Control)

        if (-not $WizardHost.Seed.ContainsKey($Control)) { return $null }
        return [string] $WizardHost.Seed[$Control]
    }
}

Describe 'the task sequence the technician picked' {

    Context 'the picker opens on nothing, the way MDT''s does' {

        It 'preselects no sequence when the rules resolved none' {
            $fileSystem = & $script:newShare

            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem

            @($sequence.Choice).Count | Should -Be 3
            [string] $sequence.Selected | Should -BeExactly ''
            [string] $sequence.Field.Text | Should -BeExactly ''
        }

        It 'preselects nothing when the rules named a sequence this share does not carry' {
            # Selecting something else quietly would deploy the wrong build to a
            # machine that is already open.
            $fileSystem = & $script:newShare

            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'NO-SUCH-TS' }))

            (@($sequence.Problem) -join ' ') | Should -BeLike '*NO-SUCH-TS*'
            [string] $sequence.Selected | Should -BeExactly ''
        }

        It 'leaves the list with nothing highlighted once the host has filled it' {
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            @($list.ItemsSource).Count | Should -Be 3
            $list.SelectedIndex | Should -Be -1
        }
    }

    Context 'picking the first row in the list' {

        It 'collects the FIRST sequence in the list when the technician picks it' {
            # THE REGRESSION. This is the field failure: the technician chose
            # the row the picker had already highlighted, the harvest saw an
            # answer equal to its own seed and dropped it, and the machine died
            # before its first step with "nothing in the rules resolved
            # HDTTaskSequenceID for this machine".
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            # The technician clicks the top row.
            $list.SelectedIndex = 0

            $answered = [string] $list.SelectedValue
            $answered | Should -BeExactly '001'

            $seeded = & $script:seedOf $wizardHost 'HDTTaskSequenceList'

            Test-HDTWizardAnswerChanged -Seeded $seeded -Answered $answered |
                Should -BeTrue -Because 'a sequence the technician chose is an answer, whichever row it was'
        }

        It 'collects any other row they pick just the same' {
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            $list.SelectedIndex = 2

            $answered = [string] $list.SelectedValue
            $answered | Should -BeExactly 'WIN11-LAB'

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTTaskSequenceList') -Answered $answered |
                Should -BeTrue
        }
    }

    Context 'the zero-touch path, which is the whole point of seeding' {

        It 'still prefills the picker from a rule-supplied HDTTaskSequenceID' {
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'WIN11-LAB' }))

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            [string] $list.SelectedValue | Should -BeExactly 'WIN11-LAB'
            $list.SelectedIndex | Should -Not -Be -1
        }

        It 'does not collect that value back as though somebody had typed it' {
            # A RULE SHOWN BACK IS NOT AN ANSWER. Every wizard value re-enters
            # the engine as the Wizard source - the highest precedence in DESIGN
            # 3.1 - so collecting this one would make the provenance report say a
            # sequence was chosen at the bench when rules.yaml chose it.
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'WIN11-LAB' }))

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            [string] (& $script:seedOf $wizardHost 'HDTTaskSequenceList') | Should -BeExactly 'WIN11-LAB'

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTTaskSequenceList') `
                -Answered ([string] $list.SelectedValue) |
                Should -BeFalse -Because 'the rule stands, and keeps its own provenance'
        }

        It 'still lets a technician change the rule''s choice, and records that as an answer' {
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'TaskSequence' })[0]
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem `
                -Variable (& $script:bag ([ordered] @{ HDTTaskSequenceID = 'WIN11-LAB' }))

            $root = & $script:applyPage $fileSystem $page @($sequence.Field) $wizardHost
            $list = $root.FindName('HDTTaskSequenceList')

            $list.SelectedIndex = 0

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTTaskSequenceList') `
                -Answered ([string] $list.SelectedValue) | Should -BeTrue
        }

        It 'is still skipped by HDTSkipTaskSequence, so a zero-touch share never shows it' {
            $fileSystem = & $script:newShare
            $page = & $script:readPage $fileSystem

            $ask = Get-HDTWizardPage -Page $page -Variable (& $script:bag ([ordered] @{
                        HDTTaskSequenceID   = 'WIN11-LAB'
                        HDTSkipTaskSequence = 'YES'
                    }))

            @($ask.Page | Where-Object { $_.Id -eq 'TaskSequence' }) | Should -BeNullOrEmpty
            @($ask.Skipped | Where-Object { $_.Id -eq 'TaskSequence' }).Count | Should -Be 1
        }
    }
}

Describe 'no wizard page treats a value the wizard invented as a seed' {

    # THE GENERAL FORM, AND THE REASON IT IS WRITTEN AGAINST THE SET. A test
    # naming the task sequence picker would pass for the task sequence picker
    # and fail nobody after it. What actually has to hold is a property of the
    # WHOLE wizard: a seed is a value a RULE supplied, and nothing else. If the
    # rules resolved nothing at all, then anything the wizard puts in a box it
    # chose for itself - and recording that as a seed makes accepting it
    # indistinguishable from answering nothing.
    #
    # THE FIELDS ARE BUILT THE WAY THE PAYLOAD BUILDS THEM, in the same order,
    # because the last write to a control is the one the seed remembers.

    # EVERY WAY THE WIZARD CAN INVENT A VALUE, not just the one that was found.
    # The task sequence picker was the case a real deployment failed on; the
    # computer name box has two more of its own, and they reach a box the same
    # way - Get-HDTWizardComputerName offers a name built out of the serial, or
    # the name the machine already answers to, when the rules named neither.
    # Nothing resolved HDTComputerName in any of these, so nothing here is a
    # seed however plausible it looks in the box.
    It 'records no seed on any control the pages collect when the rules answered nothing (<Case>)' -ForEach @(
        @{ Case = 'nothing resolved at all'; Fact = ([ordered] @{}); MachineName = 'MINWINPC' }

        # THE LIVE HOLE, AND IT IS ONE PAGE OVER FROM THE ONE THAT FAILED. A
        # share whose rules do not set HDTComputerName offers a serial-derived
        # name; the technician accepts it, the harvest sees its own seed and
        # drops it, and the machine deploys under whatever the unattend falls
        # back to.
        @{ Case = 'a serial the wizard can build a name out of'; Fact = ([ordered] @{ HDTSerialNumber = '5CG1234ABC' }); MachineName = 'MINWINPC' }

        # INERT IN WinPE, WHICH ANSWERS TO MINWINPC AND IS REFUSED - but this is
        # the same defect and is held to the same rule on principle.
        @{ Case = 'a machine that already answers to a name'; Fact = ([ordered] @{}); MachineName = 'OSDTEST01' }
    ) {
        $fileSystem = & $script:newShare
        $page = & $script:readPage $fileSystem
        $empty = & $script:bag $Fact

        # MINWINPC IS WHAT WinPE ANSWERS TO, and Get-HDTWizardComputerName
        # refuses it deliberately - it says nothing about this hardware.
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ COMPUTERNAME = $MachineName }

        $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem -Variable $empty
        $computerName = Get-HDTWizardComputerName -Variable $empty -Environment $environment
        $application = Get-HDTWizardApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem -Variable $empty

        $field = @(Get-HDTWizardSeed -Page $page -Variable $empty) +
        @(Get-HDTWizardField -NetworkConfiguration $null -Bootstrap $null) +
        @($sequence.Field) + @($computerName.Field) + @($application.Field)

        # ONE HOST FOR EVERY PAGE, exactly as a running wizard has one.
        $wizardHost = New-HDTWizardHost

        foreach ($current in @($page)) {
            [void] (& $script:applyPage $fileSystem $current $field $wizardHost)
        }

        # EVERY CONTROL ANY PAGE COLLECTS FROM, gathered off the definition
        # rather than listed here - a list would not know about the page added
        # tomorrow.
        $collected = New-Object -TypeName System.Collections.ArrayList
        foreach ($current in @($page)) {
            if ($null -eq $current.PSObject.Properties['Collect']) { continue }
            foreach ($declaration in @($current.Collect)) {
                if ($null -eq $declaration) { continue }
                [void] $collected.Add([string] $declaration.Control)
            }
        }

        @($collected).Count | Should -BeGreaterThan 0

        $invented = New-Object -TypeName System.Collections.ArrayList
        foreach ($control in @($collected)) {
            if (-not $wizardHost.Seed.ContainsKey($control)) { continue }
            if ([string]::IsNullOrWhiteSpace([string] $wizardHost.Seed[$control])) { continue }

            [void] $invented.Add(('{0} = ''{1}''' -f $control, [string] $wizardHost.Seed[$control]))
        }

        (@($invented) -join '; ') | Should -BeExactly '' -Because 'nothing was resolved, so anything seeded was invented by the wizard and accepting it would be dropped'
    }

    It 'seeds a control only from a value the rules actually resolved' {
        # THE OTHER HALF, AND IT IS THE HALF THAT MUST NOT BE LOST. Seeding is
        # not being removed - a box a rule filled and nobody touched still has
        # to keep the rule's provenance, which is exactly what the seed is for.
        $fileSystem = & $script:newShare
        $page = & $script:readPage $fileSystem

        $resolved = & $script:bag ([ordered] @{
                HDTTaskSequenceID = 'DEMO-M4'
                HDTComputerName   = 'HDT-LAB-07'
                HDTJoinWorkgroup  = 'LAB'
            })

        $sequence = Get-HDTWizardSequence -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem -Variable $resolved
        $computerName = Get-HDTWizardComputerName -Variable $resolved -Environment $null

        $field = @(Get-HDTWizardSeed -Page $page -Variable $resolved) + @($sequence.Field) + @($computerName.Field)

        $wizardHost = New-HDTWizardHost
        foreach ($current in @($page)) {
            [void] (& $script:applyPage $fileSystem $current $field $wizardHost)
        }

        [string] (& $script:seedOf $wizardHost 'HDTTaskSequenceList') | Should -BeExactly 'DEMO-M4'
        [string] (& $script:seedOf $wizardHost 'HDTComputerNameBox') | Should -BeExactly 'HDT-LAB-07'
        [string] (& $script:seedOf $wizardHost 'HDTJoinWorkgroupBox') | Should -BeExactly 'LAB'
    }

    # THE MECHANISM, RATHER THAN ITS CONSEQUENCES. The two Its above assert what
    # the shipped producers happen to do; this asserts the rule the host obeys,
    # so a producer written tomorrow is covered before it exists.
    #
    # THE DEFAULT IS "NOT A SEED", AND THE DIRECTION IS THE WHOLE POINT. A value
    # collected redundantly is harmless - it deploys the same machine and the
    # provenance says Wizard. A value silently dropped is a failed deployment.
    # So a field that says nothing about itself is treated as something the
    # wizard chose, and only a field that claims a resolved source is believed.
    Context 'a field says for itself whether it is a real seed' {

        It 'remembers a field that declares itself a seed' {
            $fileSystem = & $script:newShare
            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $wizardHost = New-HDTWizardHost

            $field = @([pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = 'HDT-LAB-07'; Seed = $true })

            [void] (& $script:applyPage $fileSystem $page $field $wizardHost)

            [string] (& $script:seedOf $wizardHost 'HDTComputerNameBox') | Should -BeExactly 'HDT-LAB-07'
        }

        It 'writes the box but remembers nothing for a field that declares itself invented' {
            $fileSystem = & $script:newShare
            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $wizardHost = New-HDTWizardHost

            $field = @([pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = '5CG1234ABC'; Seed = $false })

            $root = & $script:applyPage $fileSystem $page $field $wizardHost

            # THE SUGGESTION IS STILL MADE. Not seeding is not the same as not
            # prefilling - the technician still gets the name to accept.
            [string] $root.FindName('HDTComputerNameBox').Text | Should -BeExactly '5CG1234ABC'

            & $script:seedOf $wizardHost 'HDTComputerNameBox' | Should -BeNullOrEmpty
        }

        It 'remembers nothing for a field that says nothing about itself' {
            $fileSystem = & $script:newShare
            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $wizardHost = New-HDTWizardHost

            $field = @([pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = 'SOMETHING' })

            [void] (& $script:applyPage $fileSystem $page $field $wizardHost)

            & $script:seedOf $wizardHost 'HDTComputerNameBox' | Should -BeNullOrEmpty
        }

        It 'forgets a seed when a later field overwrites the same box with something invented' {
            # FIELDS ARE APPLIED IN ORDER AND THE LAST WRITE IS WHAT THE
            # TECHNICIAN SEES, so the last write is what the seed has to
            # describe. A seed left behind by an earlier field would be compared
            # against a value that is no longer in the box.
            $fileSystem = & $script:newShare
            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $wizardHost = New-HDTWizardHost

            $field = @(
                [pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = 'HDT-LAB-07'; Seed = $true }
                [pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = '5CG1234ABC'; Seed = $false }
            )

            [void] (& $script:applyPage $fileSystem $page $field $wizardHost)

            & $script:seedOf $wizardHost 'HDTComputerNameBox' | Should -BeNullOrEmpty
        }
    }
}

Describe 'the computer name the wizard suggested' {

    # THE SAME FIELD FAILURE AS THE TASK SEQUENCE, ONE PAGE OVER.
    # Get-HDTWizardComputerName offers a name whichever way it can: from the
    # rules, then from the serial, then from the name the machine already
    # answers to. Only the first of those came from a resolved source. The other
    # two are the wizard's own suggestion - and the Field carried no way to say
    # so, so the host recorded all three as seeds and the harvest dropped
    # whichever one the technician accepted.

    Context 'a name the wizard built out of the serial' {

        It 'is offered in the box, and says on the field that it is not a seed' {
            $bag = & $script:bag ([ordered] @{ HDTSerialNumber = '5CG1234ABC' })

            $name = Get-HDTWizardComputerName -Variable $bag -Environment $null

            [string] $name.Source | Should -BeExactly 'Serial'
            [string] $name.Field.Text | Should -BeExactly '5CG1234ABC'
            [bool] $name.Field.Seed | Should -BeFalse
        }

        It 'is collected when the technician accepts it' {
            # THE FIELD FAILURE. A share whose rules do not set HDTComputerName
            # offers a serial-derived name; the technician reads it, agrees and
            # presses Next; the harvest sees a value equal to its own seed and
            # drops it - so the machine is deployed under no name the technician
            # ever chose.
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $bag = & $script:bag ([ordered] @{ HDTSerialNumber = '5CG1234ABC' })

            $name = Get-HDTWizardComputerName -Variable $bag -Environment $null

            $root = & $script:applyPage $fileSystem $page @($name.Field) $wizardHost
            $box = $root.FindName('HDTComputerNameBox')

            [string] $box.Text | Should -BeExactly '5CG1234ABC'

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTComputerNameBox') -Answered ([string] $box.Text) |
                Should -BeTrue -Because 'the wizard invented that name, so accepting it is the technician''s answer'
        }
    }

    Context 'a name the machine already answers to' {

        It 'is offered, and is not a seed either' {
            # INERT IN WinPE, WHICH CALLS ITSELF MINWINPC AND IS REFUSED - but
            # the same rule applies, and it is the rule that is being fixed.
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ COMPUTERNAME = 'OSDTEST01' }

            $name = Get-HDTWizardComputerName -Variable (& $script:bag $null) -Environment $environment

            [string] $name.Source | Should -BeExactly 'Machine'
            [bool] $name.Field.Seed | Should -BeFalse
        }
    }

    Context 'an empty box, because nothing could suggest anything' {

        It 'is not a seed, so the first thing typed into it is collected' {
            $name = Get-HDTWizardComputerName -Variable (& $script:bag $null) -Environment $null

            [string] $name.Source | Should -BeExactly 'None'
            [bool] $name.Field.Seed | Should -BeFalse
        }
    }

    Context 'the zero-touch path, which must not be lost' {

        It 'says a rules-supplied name IS a seed' {
            $bag = & $script:bag ([ordered] @{ HDTComputerName = 'HDT-LAB-07'; HDTSerialNumber = '5CG1234ABC' })

            $name = Get-HDTWizardComputerName -Variable $bag -Environment $null

            [string] $name.Source | Should -BeExactly 'Rules'
            [bool] $name.Field.Seed | Should -BeTrue
        }

        It 'still prefills the box from it and does not collect it back' {
            # A RULE SHOWN BACK IS NOT AN ANSWER. Collecting it would re-enter
            # the value as the Wizard source - the highest precedence in DESIGN
            # 3.1 - and the report would say a name was typed at a bench when
            # rules.yaml produced it.
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $bag = & $script:bag ([ordered] @{ HDTComputerName = 'HDT-LAB-07' })

            $name = Get-HDTWizardComputerName -Variable $bag -Environment $null

            $root = & $script:applyPage $fileSystem $page @($name.Field) $wizardHost
            $box = $root.FindName('HDTComputerNameBox')

            [string] $box.Text | Should -BeExactly 'HDT-LAB-07'
            [string] (& $script:seedOf $wizardHost 'HDTComputerNameBox') | Should -BeExactly 'HDT-LAB-07'

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTComputerNameBox') -Answered ([string] $box.Text) |
                Should -BeFalse -Because 'the rule stands, and keeps its own provenance'
        }

        It 'still records an edit to a rules-supplied name as the technician''s answer' {
            $fileSystem = & $script:newShare
            $wizardHost = New-HDTWizardHost

            $page = @(& $script:readPage $fileSystem | Where-Object { $_.Id -eq 'ComputerDetail' })[0]
            $bag = & $script:bag ([ordered] @{ HDTComputerName = 'HDT-LAB-07' })

            $name = Get-HDTWizardComputerName -Variable $bag -Environment $null

            $root = & $script:applyPage $fileSystem $page @($name.Field) $wizardHost
            $box = $root.FindName('HDTComputerNameBox')

            $box.Text = 'HDT-LAB-08'

            Test-HDTWizardAnswerChanged -Seeded (& $script:seedOf $wizardHost 'HDTComputerNameBox') -Answered ([string] $box.Text) |
                Should -BeTrue
        }

        It 'is still skipped by HDTSkipComputerName, so a zero-touch share never shows it' {
            $fileSystem = & $script:newShare
            $page = & $script:readPage $fileSystem

            # EVERY VALUE THE PAGE WOULD HAVE ASKED FOR, because a skipped page
            # whose value is still missing is an error rather than a prompt
            # (DESIGN 11.2) - so a zero-touch share supplies the workgroup too.
            $ask = Get-HDTWizardPage -Page $page -Variable (& $script:bag ([ordered] @{
                        HDTComputerName     = 'HDT-LAB-07'
                        HDTJoinWorkgroup    = 'WORKGROUP'
                        HDTSkipComputerName = 'YES'
                    }))

            @($ask.Page | Where-Object { $_.Id -eq 'ComputerDetail' }) | Should -BeNullOrEmpty
            @($ask.Skipped | Where-Object { $_.Id -eq 'ComputerDetail' }).Count | Should -Be 1
        }
    }
}

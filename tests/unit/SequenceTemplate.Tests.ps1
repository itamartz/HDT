# TASK SEQUENCE TEMPLATES - MDT'S Templates\Client.xml, IN THIS TOOLKIT.
#
# MDT's New Task Sequence wizard asks which template, then copies that file into
# the new sequence's Control folder. This is the same model: a template is a real
# sequence.yaml on disk, which means it can be opened, read, diffed and edited
# without running anything - and a shop that wants its own standard sequence
# writes one file rather than a plugin.
#
# THE TEMPLATES ARE VALIDATED LIKE ANY OTHER DOCUMENT. A template that does not
# import, or that names a step type the engine cannot run, is a defect that
# would otherwise surface on the first machine somebody deployed with it.

# THE MODULE IS IMPORTED AT DISCOVERY TOO. The -ForEach lists below are built by
# ASKING the toolkit which templates it ships - that is what makes a template
# added tomorrow validated by this suite without anybody editing it - and
# discovery runs before BeforeAll.
BeforeDiscovery {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:discovered = @(Get-HDTSequenceTemplate | ForEach-Object { @{ Id = $_.Id } })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:template = @(Get-HDTSequenceTemplate)
}

Describe 'Get-HDTSequenceTemplate' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTSequenceTemplate' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'offers at least the client one, which is what MDT leads with' {
        @($script:template).Count | Should -BeGreaterOrEqual 1
        @($script:template | ForEach-Object { $_.Id }) | Should -Contain 'client'
    }

    It 'describes each one, because the picker shows the description not the file' {
        foreach ($one in $script:template) {
            $one.Name | Should -Not -BeNullOrEmpty
            $one.Description | Should -Not -BeNullOrEmpty
            $one.Path | Should -Not -BeNullOrEmpty
        }
    }

    It 'reads one back as lines, which is what a new sequence is written from' {
        $line = @(Get-HDTSequenceTemplate -Id client -Line)

        @($line).Count | Should -BeGreaterThan 20
        ($line -join "`n") | Should -BeLike '*type: DiskPartition*'
    }

    It 'refuses a template it does not have, by name' {
        { Get-HDTSequenceTemplate -Id 'no-such-template' -Line } |
            Should -Throw -ExpectedMessage '*no-such-template*'
    }
}

Describe 'every template this toolkit ships' {

    It '<Id> imports as a sequence the engine can read' -ForEach $script:discovered {
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }

        { Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem } |
            Should -Not -Throw
    }

    It '<Id> names only step types the engine can run' -ForEach $script:discovered {
        # A TEMPLATE THAT NAMES A TYPE NOTHING IMPLEMENTS fails on the machine,
        # after the disk has been wiped - which is the worst possible place to
        # discover a typo in a file that ships with the product.
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }
        $document = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem

        $known = @(Get-HDTStepType | ForEach-Object { $_.Type })

        foreach ($step in @($document.Step)) {
            $known | Should -Contain ([string] $step.Type)
        }
    }

    It '<Id> names only disk layouts the engine has' -ForEach $script:discovered {
        # The same failure that shipped in the DiskPartition step template:
        # 'layout: UEFI' parses, looks finished, and refuses on the machine.
        $wanted = $Id

        foreach ($line in @(Get-HDTSequenceTemplate -Id $wanted -Line)) {
            if ($line -notmatch '^\s*layout:\s*(.+?)\s*$') { continue }

            $named = [string] $Matches[1]
            if ($named -match '^["'']?%') { continue }

            { Get-HDTDiskLayout -Name ($named -replace '^["'']|["'']$', '') } | Should -Not -Throw
        }
    }

    It '<Id> writes conditions the engine actually evaluates' -ForEach $script:discovered {
        # A CONDITION THAT CANNOT BE PARSED IS WORSE THAN NONE. It looks
        # deliberate, and the step it guards silently never runs.
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }
        $document = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem

        foreach ($step in @($document.Step)) {
            if ([string]::IsNullOrWhiteSpace([string] $step.Condition)) { continue }

            { Test-HDTStepCondition -Condition ([string] $step.Condition) `
                    -Variable @{ HDTIsUEFI = $true } } | Should -Not -Throw
        }
    }
}

Describe 'the client template in particular' {

    BeforeAll {
        $script:clientLine = @(Get-HDTSequenceTemplate -Id client -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($script:clientLine -join "`n") }
        $script:client = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem
    }

    It "carries MDT's phases, in MDT's order" {
        # A technician arriving from Workbench knows which half of a deployment
        # failed from the group it stopped inside.
        $group = @($script:client.Group | Where-Object { @($_.Path).Count -eq 1 } |
                ForEach-Object { $_.Path[0] })

        $group | Should -Be @('Initialization', 'Validation', 'Preinstall', 'Install', 'Postinstall', 'State Restore')
    }

    It 'carries both partition steps, one per firmware' {
        $disk = @($script:client.Step | Where-Object { $_.Type -eq 'DiskPartition' })

        @($disk).Count | Should -Be 2

        # AND EXACTLY ONE OF THEM RUNS on any given machine, which is the whole
        # reason a sequence carries two.
        foreach ($firmware in @($true, $false)) {
            $running = @($disk | Where-Object {
                    Test-HDTStepCondition -Condition ([string] $_.Condition) `
                        -Variable @{ HDTIsUEFI = $firmware }
                })

            @($running).Count | Should -Be 1
        }
    }

    It 'names a disk, as MDT does, so a one-disk machine needs no editing' {
        # MDT's Client.xml sets OSDDiskIndex 0 on both partition steps. A
        # template that named none would leave the commonest machine - one
        # disk - failing at the first destructive step with "which disk".
        $disk = @($script:client.Step | Where-Object { $_.Type -eq 'DiskPartition' })

        foreach ($one in $disk) {
            $one.Property.Contains('diskNumber') | Should -BeTrue
            [string] $one.Property['diskNumber'] | Should -BeExactly '0'
        }
    }

    It 'gathers before anything conditions on what was gathered' {
        # EVERY CONDITION IN THIS SEQUENCE READS A FACT: the firmware that picks
        # a partition step, the TPM the validation checks. A gather that ran
        # after them would be describing a machine whose decisions were already
        # made.
        $order = @($script:client.Step | ForEach-Object { $_.Type })

        [array]::IndexOf($order, 'Gather') | Should -Be 0
    }

    It 'restarts before anything expects Windows to be running' {
        $order = @($script:client.Step | ForEach-Object { $_.Type })

        $restart = [array]::IndexOf($order, 'Restart')
        $apps = [array]::IndexOf($order, 'InstallApplications')

        $restart | Should -BeGreaterThan -1
        $apps | Should -BeGreaterThan $restart
    }
}

Describe 'New-HDTTaskSequence' {

    BeforeEach {
        $script:ws = 'C:\ws'

        $script:fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab share`ndeployRoot: \host\share"
        }
    }

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTTaskSequence' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the sequence where the engine looks for it' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $script:fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeTrue
    }

    It 'gives it the id and name it was asked for, not the template''s' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        $document.Id | Should -BeExactly 'WIN11'
        $document.Name | Should -BeExactly 'Windows 11'
    }

    It "keeps the template's comments, which are what a new sequence is read for" {
        # A PARSE AND RE-EMIT WOULD HAND BACK A CORRECT DOCUMENT AND NONE OF THE
        # PROSE. Half the value of MDT's Client.xml is that somebody opening it
        # can see why the steps are in that order - and this file is the first
        # thing an author of a new sequence reads.
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\sequence.yaml')

        $text | Should -BeLike '*THE PAIR, AND ONLY ONE OF THEM RUNS*'
    }

    It 'carries the steps over, so a new sequence is not empty' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        @($document.Step).Count | Should -BeGreaterOrEqual 6
    }

    It 'refuses to write over one that already exists' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        # A SEQUENCE IS SOMEBODY'S WORK. Recreating one over the top of an
        # edited sequence is the single destructive thing this command could do,
        # and there is no reading of "new" that means "replace".
        { New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Again' `
                -FileSystem $script:fs -Confirm:$false } |
            Should -Throw -ExpectedMessage '*WIN11*'
    }

    It 'refuses a template it does not have' {
        { New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Template 'no-such-template' -FileSystem $script:fs -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no-such-template*'
    }

    It 'writes nothing under -WhatIf' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -WhatIf)

        $script:fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeFalse
    }
}

Describe 'New-HDTTaskSequence -Variable' {

    # MDT'S WIZARD ASKS FOR SETTINGS AND WRITES THEM INTO THE SEQUENCE it just
    # created - the OS, the full name, the organisation, the administrator
    # password. This is where those land: the document's own variables block,
    # which is what every step already substitutes from.

    BeforeEach {
        $script:ws = 'C:\ws'
        $script:fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab share`ndeployRoot: \host\share"
        }
    }

    It 'writes what it was given into the variables block' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Variable ([ordered] @{ HDTFullName = 'Lab Team'; HDTOrgName = 'Contoso' }) `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        [string] $document.Variable['HDTFullName'] | Should -BeExactly 'Lab Team'
        [string] $document.Variable['HDTOrgName'] | Should -BeExactly 'Contoso'
    }

    It "replaces a value the template already set rather than writing it twice" {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Variable ([ordered] @{ HDTOSImage = 'WS2025-Std' }) `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\sequence.yaml')

        # A DOCUMENT WITH THE KEY TWICE is one the reader takes the last of, and
        # an author reading the first is then wrong about their own file.
        @([regex]::Matches($text, '(?m)^\s+HDTOSImage:')).Count | Should -Be 1

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        [string] $document.Variable['HDTOSImage'] | Should -BeExactly 'WS2025-Std'
    }

    It "keeps the template's other variables and its prose" {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Variable ([ordered] @{ HDTFullName = 'Lab Team' }) `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\sequence.yaml')

        $text | Should -BeLike '*HDTOSImageIndex*'
        $text | Should -BeLike '*THE PAIR, AND ONLY ONE OF THEM RUNS*'
    }

    It 'writes nothing extra when given nothing' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        @($document.Variable.Keys) | Should -Be @('HDTOSImage', 'HDTOSImageIndex')
    }

    It 'quotes a value that needs it' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Variable ([ordered] @{ HDTAdminPassword = 'P@ssw0rd: with colon' }) `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        [string] $document.Variable['HDTAdminPassword'] | Should -BeExactly 'P@ssw0rd: with colon'
    }
}

Describe 'the answer file a new sequence gets' {

    # THE TEMPLATE'S Apply Windows Settings STEP NAMES unattend.xml, and nothing
    # put one there - so every sequence the wizard created referenced a file
    # that did not exist and would have failed at the machine. MDT copies its
    # Unattend_x64.xml into the new sequence's folder for exactly this reason.

    BeforeEach {
        $script:ws = 'C:\ws'
        $script:fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab share`ndeployRoot: \host\share"
        }
    }

    It 'is written beside the sequence' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $script:fs.TestPath('C:\ws\TaskSequences\WIN11\unattend.xml') | Should -BeTrue
    }

    It 'is the file the sequence actually names' {
        # THE STEP AND THE FILE HAVE TO AGREE. A template that named
        # answer.xml and shipped unattend.xml would fail on the machine with a
        # missing file, which is the failure this whole test exists to stop.
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        $step = @($document.Step | Where-Object { $_.Type -eq 'ApplyUnattend' })[0]
        $named = [string] $step.Property['template']

        $script:fs.TestPath(('C:\ws\TaskSequences\WIN11\{0}' -f $named)) | Should -BeTrue
    }

    It 'is valid XML' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\unattend.xml')

        { [xml] $text } | Should -Not -Throw
    }

    It 'carries the tokens the wizard writes' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\unattend.xml')

        foreach ($token in @('%HDTComputerName%', '%HDTAdminPassword%', '%HDTFullName%', '%HDTOrgName%')) {
            $text | Should -BeLike ('*{0}*' -f $token)
        }
    }

    Context 'the language and region block' {

        # HARD-CODED en-US IS A DECISION NOBODY MADE. Every machine this
        # template deployed came up with a US keyboard, a US system locale and
        # a US display language whatever the site was - and the only way to
        # change it was to hand-edit the XML of every task sequence.
        #
        # THEY ARE VARIABLES, NOT STEP PROPERTIES, and that is the same answer
        # MDT gave: UILanguage, UserLocale and KeyboardLocale are CustomSettings
        # entries there, so one rule can set them for a site, a model or a
        # subnet. A step property would be a fifth place to state them and a
        # fifth place for two answers to disagree.

        BeforeAll {
            $script:unattendText = [string] (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                        -ChildPath 'src/Hephaestus/Templates/unattend.xml') -Raw)
        }

        It 'asks a variable for <Element>' -ForEach @(
            @{ Element = 'InputLocale'; Token = '%HDTKeyboardLocale%' }
            @{ Element = 'SystemLocale'; Token = '%HDTSystemLocale%' }
            @{ Element = 'UILanguage'; Token = '%HDTUILanguage%' }
            @{ Element = 'UserLocale'; Token = '%HDTUserLocale%' }
        ) {
            $script:unattendText | Should -BeLike ('*<{0}>{1}</{0}>*' -f $Element, $Token)
        }

        It 'hard-codes none of them' {
            # en-US as a literal is what this replaces; a token that fell back to
            # one would be the same defect with an extra step.
            $script:unattendText | Should -Not -BeLike '*<SystemLocale>en-US</SystemLocale>*'
            $script:unattendText | Should -Not -BeLike '*<UILanguage>en-US</UILanguage>*'
        }

        It 'names InputLocale s variable the one MDT called KeyboardLocale' {
            # MDT's KeyboardLocale IS the unattend's InputLocale, and HDT already
            # carries HDTKeyboardLocale for it. A second HDTInputLocale would be
            # two names for one setting.
            @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTKeyboardLocale' })[0].MdtName |
                Should -BeExactly 'KeyboardLocale'
        }

        It 'carries the one variable that did not exist yet' {
            $entry = @(Get-HDTVariableMap | Where-Object { $_.HDTName -eq 'HDTSystemLocale' })

            $entry.Count | Should -Be 1
            $entry[0].MdtName | Should -BeExactly 'SystemLocale'
            $entry[0].Writable | Should -BeTrue
        }
    }

    It 'never names the password token in a comment' {
        # EXPANSION RUNS OVER THE WHOLE DOCUMENT, comments included. A comment
        # mentioning the token with its per cent signs would put the machine's
        # local Administrator password into a comment in the deployed file.
        $text = [string] (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Templates/unattend.xml') -Raw)

        @([regex]::Matches($text, [regex]::Escape('%HDTAdminPassword%'))).Count | Should -Be 2
    }

    It 'does not overwrite an answer file that is already there' {
        # New-HDTTaskSequence refuses an existing sequence outright, so this can
        # only happen with a folder holding an unattend and no sequence - and
        # somebody's answer file is not this command's to replace.
        $script:fs.WriteAllText('C:\ws\TaskSequences\WIN11\unattend.xml', '<unattend>mine</unattend>')

        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\unattend.xml') |
            Should -BeExactly '<unattend>mine</unattend>'
    }
}

Describe "the boot image's own answer file" {

    # WinPE READS A DIFFERENT DOCUMENT from the one a task sequence stages for
    # Windows Setup. wpeinit consumes this one, and the Windows PE page names
    # it; unattend.xml beside a sequence belongs to that sequence.

    BeforeAll {
        $script:winpePath = Join-Path -Path $script:repoRoot `
            -ChildPath 'src/Hephaestus/Templates/unattend-winpe.xml'

        $script:winpeText = [string] (Get-Content -LiteralPath $script:winpePath -Raw)
    }

    It 'is shipped' {
        Test-Path -LiteralPath $script:winpePath | Should -BeTrue
    }

    It 'is valid XML' {
        { [xml] $script:winpeText } | Should -Not -Throw
    }

    It 'is a windowsPE pass document' {
        $script:winpeText | Should -BeLike '*pass="windowsPE"*'
    }

    It 'launches nothing' {
        # MDT'S FILE LAUNCHES LiteTouch.wsf HERE. HDT starts itself from
        # startnet.cmd - M4's "no key is ever pressed" rests on it - so a
        # launcher in this document would start the engine a second time, in
        # parallel with the first, both mounting the same share.
        # THE DOCUMENT, NOT THE PROSE. The comment above it explains why
        # there is no launcher, and a text match found the explanation.
        $document = [xml] $script:winpeText

        @($document.SelectNodes('//*[local-name()="RunSynchronous"]')).Count | Should -Be 0
        @($document.SelectNodes('//*[local-name()="RunAsynchronous"]')).Count | Should -Be 0
    }

    It 'sets a resolution the wizard fits in' {
        # WinPE defaults to 800x600 where the hardware reports nothing better,
        # which is smaller than the deployment wizard was laid out for.
        $script:winpeText | Should -BeLike '*<HorizontalResolution>1024<*'
        $script:winpeText | Should -BeLike '*<VerticalResolution>768<*'
    }

    It 'is not copied into a task sequence' {
        # It belongs to the boot image - one per share - and a copy in every
        # sequence folder would be four files nobody edits and one somebody
        # eventually does.
        $fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \host\share"
        }

        [void] (New-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $fs -Confirm:$false)

        $fs.TestPath('C:\ws\TaskSequences\WIN11\unattend-winpe.xml') | Should -BeFalse
    }
}

Describe 'New-HDTBootImageUnattend' {

    # THE TEMPLATE, ONTO THE SHARE. Set-HDTBootImageUnattend names a file in
    # workspace.yaml and checks nothing; naming one that does not exist is a
    # build refused minutes later. This is the other half - a share that had no
    # answer file has one, and it is the document this module ships rather than
    # a blank file somebody has to fill in from Microsoft's schema.

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \host\share"
        }
    }

    It 'writes the shipped WinPE answer file onto the share' {
        [void] (New-HDTBootImageUnattend -Workspace 'C:\ws' -FileSystem $script:fs -Confirm:$false)

        $script:fs.TestPath('C:\ws\Unattend-PE.xml') | Should -BeTrue
    }

    It 'writes the template, not an empty file' {
        [void] (New-HDTBootImageUnattend -Workspace 'C:\ws' -FileSystem $script:fs -Confirm:$false)

        [string] $script:fs.ReadAllText('C:\ws\Unattend-PE.xml') | Should -BeLike '*pass="windowsPE"*'
    }

    It 'returns the path and the name the document would carry' {
        $made = New-HDTBootImageUnattend -Workspace 'C:\ws' -FileSystem $script:fs -Confirm:$false

        [string] $made.Path | Should -BeExactly 'C:\ws\Unattend-PE.xml'

        # RELATIVE IS WHAT GOES IN workspace.yaml. A rooted path there is legal
        # and wrong for a file that lives on the share: it names the build
        # host's drive letter in a document every build host reads.
        [string] $made.Relative | Should -BeExactly 'Unattend-PE.xml'
    }

    It 'takes another name' {
        $made = New-HDTBootImageUnattend -Workspace 'C:\ws' -Path 'Config\WinPE.xml' `
            -FileSystem $script:fs -Confirm:$false

        $script:fs.TestPath('C:\ws\Config\WinPE.xml') | Should -BeTrue
        [string] $made.Relative | Should -BeExactly 'Config\WinPE.xml'
    }

    It 'refuses to overwrite an answer file that is already there' {
        $script:fs.WriteAllText('C:\ws\Unattend-PE.xml', '<unattend>mine</unattend>')

        { New-HDTBootImageUnattend -Workspace 'C:\ws' -FileSystem $script:fs -Confirm:$false } |
            Should -Throw '*already*'
    }

    It 'overwrites it with -Force' {
        $script:fs.WriteAllText('C:\ws\Unattend-PE.xml', '<unattend>mine</unattend>')

        [void] (New-HDTBootImageUnattend -Workspace 'C:\ws' -Force -FileSystem $script:fs -Confirm:$false)

        [string] $script:fs.ReadAllText('C:\ws\Unattend-PE.xml') | Should -BeLike '*pass="windowsPE"*'
    }

    It 'writes nothing under -WhatIf' {
        [void] (New-HDTBootImageUnattend -Workspace 'C:\ws' -FileSystem $script:fs -WhatIf)

        $script:fs.TestPath('C:\ws\Unattend-PE.xml') | Should -BeFalse
    }

    It 'refuses a rooted name' {
        # THE FILE GOES ON THE SHARE, which is what makes Relative meaningful.
        # A rooted path here would write outside the workspace and hand back a
        # Relative that names nothing.
        { New-HDTBootImageUnattend -Workspace 'C:\ws' -Path 'C:\elsewhere\PE.xml' `
                -FileSystem $script:fs -Confirm:$false } | Should -Throw '*share*'
    }
}

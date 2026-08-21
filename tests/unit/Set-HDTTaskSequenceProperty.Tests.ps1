# THE TWO LINES AT THE TOP OF A SEQUENCE, which nothing could edit.
#
# Set-HDTWorkspaceProperty does this for the share and Set-HDTApplication for an
# application; a task sequence's own name and description had no command, so the
# editor showed them and could not change them - which is the console rule
# working correctly and producing a hole.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:documentText = @'
# A sequence somebody wrote and commented, which is the point of splicing.
schemaVersion: 1
id: DEMO-05
name: Windows 11 bare metal
description: The standard client build.

variables:
  HDTDiskLayout: uefi-standard

steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
'@

    $script:line = [string[]] @($script:documentText -split "`r?`n")

    # A document with no description, which is legal - unlike a document with
    # no name, which Assert-HDTSequenceDocument refuses outright: "the name is
    # what a technician chooses this sequence by".
    $script:bareText = @'
schemaVersion: 1
id: DEMO-06
name: Windows 11, undescribed

steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
'@

    $script:bare = [string[]] @($script:bareText -split "`r?`n")

    $script:readBack = {
        param([string[]] $Line)

        # New-HDTFileSystemFromText is private, so the fake stands in - it is
        # the same thing a test is allowed to reach.
        $reader = New-HDTFakeFileSystem -File @{
            'C:\ws\TaskSequences\X\sequence.yaml' = ($Line -join "`n")
        }

        return (Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\X\sequence.yaml' -FileSystem $reader)
    }
}

Describe 'Set-HDTTaskSequenceProperty' {

    It 'renames the sequence' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Name 'Windows 11 LTSC, bare metal' -Confirm:$false

        [string] (& $script:readBack $result).Name | Should -BeExactly 'Windows 11 LTSC, bare metal'
    }

    It 'rewrites the description' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Description 'Laptops only.' -Confirm:$false

        [string] (& $script:readBack $result).Description | Should -BeExactly 'Laptops only.'
    }

    # MDT'S TaskSequenceVersion. Deployment Workbench puts a Version box on a
    # task sequence's Properties, and Import-HDTSequenceDocument has always read
    # the key - it was the only one of the three the console could neither show
    # nor write, so a sequence's version could only be changed by editing the
    # YAML by hand.
    It 'writes the version' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Version '2.1' -Confirm:$false

        [string] (& $script:readBack $result).Version | Should -BeExactly '2.1'
    }

    # IT IS TEXT, WHATEVER THE AUTHOR MEANT - the importer says so, and '1.0.0',
    # '2026-08-21' and 'rc2' are all versions somebody has used.
    It 'keeps a version that is not a number' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Version '2026-08-21-rc2' -Confirm:$false

        [string] (& $script:readBack $result).Version | Should -BeExactly '2026-08-21-rc2'
    }

    It 'puts a new version under the name, where the schema orders it' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Version '3' -Confirm:$false

        $index = @($result | ForEach-Object { $_ })
        $name = [array]::FindIndex($index, [Predicate[string]] { param($l) $l -match '^name:' })
        $version = [array]::FindIndex($index, [Predicate[string]] { param($l) $l -match '^version:' })

        $version | Should -BeGreaterThan $name
    }

    It 'changes both at once' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Name 'Both' -Description 'At once.' -Confirm:$false

        $document = & $script:readBack $result

        [string] $document.Name | Should -BeExactly 'Both'
        [string] $document.Description | Should -BeExactly 'At once.'
    }

    It 'leaves the id, the variables, the steps and the comments alone' {
        # THE WHOLE REASON THIS SPLICES. A parse-and-re-emit would take the
        # comment at the top with it, and DEMO-M4 is half commentary.
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Name 'Renamed' -Confirm:$false

        ($result -join "`n") | Should -BeLike '*# A sequence somebody wrote and commented*'
        ($result -join "`n") | Should -BeLike '*HDTDiskLayout: uefi-standard*'

        $document = & $script:readBack $result
        [string] $document.Id | Should -BeExactly 'DEMO-05'
        @($document.Step).Count | Should -Be 1
    }

    It 'writes a key the document did not have' {
        $result = Set-HDTTaskSequenceProperty -Line $script:bare -Description 'And described.' -Confirm:$false

        [string] (& $script:readBack $result).Description | Should -BeExactly 'And described.'
    }

    It 'puts a new description under the name, where a reader looks for it' {
        $result = Set-HDTTaskSequenceProperty -Line $script:bare -Description 'And described.' -Confirm:$false

        $at = [array]::IndexOf([string[]] $result, 'description: And described.')
        [string] $result[$at - 1] | Should -BeExactly 'name: Windows 11, undescribed'
    }

    It 'clears the description when asked, and only then' {
        # AN OMITTED PARAMETER IS "leave it alone" and an empty string is
        # "take it away". Without that distinction one box left blank on a
        # window would wipe a description nobody touched.
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Description '' -Confirm:$false

        ($result -join "`n") | Should -Not -BeLike '*description:*'
        [string] (& $script:readBack $result).Name | Should -BeExactly 'Windows 11 bare metal'
    }

    It 'refuses to clear the name' {
        # The tree, the wizard and the editor all show it, and a sequence with
        # no name shows as a blank row.
        { Set-HDTTaskSequenceProperty -Line $script:line -Name '' -Confirm:$false } | Should -Throw '*name*'
    }

    It 'refuses a call that changes nothing' {
        { Set-HDTTaskSequenceProperty -Line $script:line -Confirm:$false } | Should -Throw '*-Name*'
    }

    It 'quotes a value that needs it' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Name 'Windows 11: the sequel' -Confirm:$false

        [string] (& $script:readBack $result).Name | Should -BeExactly 'Windows 11: the sequel'
    }

    It 'changes nothing under -WhatIf' {
        $result = Set-HDTTaskSequenceProperty -Line $script:line -Name 'Not this' -WhatIf

        ($result -join "`n") | Should -BeLike '*name: Windows 11 bare metal*'
    }

    It 'refuses a document that will not parse' {
        { Set-HDTTaskSequenceProperty -Line ([string[]] @('steps:', '  - : :')) -Name 'X' -Confirm:$false } |
            Should -Throw
    }
}

Describe 'a description written as a folded block' {

    # THE ONE THE TEMPLATE ITSELF WRITES, and the shape every sequence created
    # from it carries:
    #
    #     description: >
    #       Deploys Windows to a bare machine: validate it, lay out the disk
    #       for its firmware, apply the image ...
    #
    # THE SPLICE REPLACED ONE LINE AND LEFT THE REST. The continuation lines
    # stayed behind with nothing to belong to, so the next key parsed as part of
    # a scalar and the document came back
    #
    #     sequence.yaml(35): ... While scanning a plain scalar value, found
    #     invalid mapping.
    #
    # Reported from the console's detail pane, where the description looked as
    # though it kept resetting - it did: the write was refused and the pane
    # refilled from the file.

    BeforeAll {
        $script:foldedLine = [string[]] @(
            'schemaVersion: 1'
            'id: DEMO'
            'name: Demo'
            'description: >'
            '  Deploys Windows to a bare machine: validate it, lay out the disk for its'
            '  firmware, apply the image, stage the answer file, and make it boot.'
            ''
            'variables:'
            '  HDTOSImage: Win11-LTSC-2024'
            ''
            'steps:'
            '  - name: Gather'
            '    type: Gather'
        )
    }

    It 'replaces the whole block, not only the key line' {
        $after = Set-HDTTaskSequenceProperty -Line $script:foldedLine -Description 'Shorter' -Confirm:$false

        @($after | Where-Object { $_ -like '*lay out the disk*' }) | Should -BeNullOrEmpty
        @($after | Where-Object { $_ -like '*stage the answer file*' }) | Should -BeNullOrEmpty
    }

    It 'leaves a document the engine can still read' {
        $after = Set-HDTTaskSequenceProperty -Line $script:foldedLine -Description 'Shorter' -Confirm:$false

        $document = InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $after } {
            param($Body)
            ConvertFrom-HDTSequenceLine -Line ([string[]] $Body)
        }

        $document.Description | Should -BeExactly 'Shorter'
        @($document.Step).Count | Should -Be 1
    }

    It 'keeps the keys that follow it' {
        $after = Set-HDTTaskSequenceProperty -Line $script:foldedLine -Description 'Shorter' -Confirm:$false

        $after | Should -Contain 'variables:'
        $after | Should -Contain '  HDTOSImage: Win11-LTSC-2024'
        $after | Should -Contain 'steps:'
    }

    It 'removes the whole block when the description is cleared' {
        $after = Set-HDTTaskSequenceProperty -Line $script:foldedLine -Description '' -Confirm:$false

        @($after | Where-Object { $_ -like 'description*' }) | Should -BeNullOrEmpty
        @($after | Where-Object { $_ -like '*lay out the disk*' }) | Should -BeNullOrEmpty

        $document = InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $after } {
            param($Body)
            ConvertFrom-HDTSequenceLine -Line ([string[]] $Body)
        }

        @($document.Step).Count | Should -Be 1
    }

    It 'leaves a single-line description alone, which is the ordinary case' {
        $plain = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'; 'description: One line'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $after = Set-HDTTaskSequenceProperty -Line $plain -Description 'Another line' -Confirm:$false

        $after | Should -Contain 'description: Another line'
        $after | Should -Contain 'steps:'
    }
}

Describe 'a value that arrived with a newline in it' {

    # WHERE IT COMES FROM. A folded block parses to a string ENDING IN A
    # NEWLINE - that is what YAML's > means - so the console reads the
    # description of a template-made sequence, hands it straight back, and the
    # writer quotes it:
    #
    #     description: 'Deploys Windows to a bare machine: ... make it boot.
    #     folder: Clients\Bare metal
    #     '
    #
    # The scalar now spans three lines, and the next key spliced after the
    # 'description:' LINE landed inside it. The folder disappeared from the tree
    # because it was part of the description.
    #
    # A HEADER KEY IS ONE LINE. Nothing in a document header is meant to carry a
    # paragraph, so the value is collapsed to a single line rather than quoted
    # across several.

    It 'writes it on one line' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $after = Set-HDTTaskSequenceProperty -Line $line `
            -Description ("Deploys Windows to a bare machine.`r`n") -Confirm:$false

        @($after | Where-Object { $_ -like 'description:*' }).Count | Should -Be 1
        @($after | Where-Object { $_ -eq "'" }) | Should -BeNullOrEmpty
    }

    It 'keeps the document readable, and the next key outside the value' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $after = Set-HDTTaskSequenceProperty -Line $line `
            -Description ("One line.`r`nAnd another.") -Confirm:$false
        $after = Set-HDTTaskSequenceProperty -Line $after -Folder 'Clients' -Confirm:$false

        $document = InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $after } {
            param($Body)
            ConvertFrom-HDTSequenceLine -Line ([string[]] $Body)
        }

        $document.Folder | Should -BeExactly 'Clients'
        $document.Description | Should -Not -BeLike '*folder*'
        @($document.Step).Count | Should -Be 1
    }
}

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

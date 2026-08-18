# RENAMING AN OPERATING SYSTEM FROM THE CONSOLE, and giving it a description.
#
# MDT's Deployment Workbench edits both on the Properties sheet of an imported
# OS, and until now HDT could only write them at import time - a typo in the
# name meant importing the media again, which is minutes and 4 GB.
#
# THE SPLICE IS THE SAME ONE THE TASK SEQUENCE USES. os.yaml's header is flat
# and so is sequence.yaml's; what differs is the key order and which line ends
# the header - `images:` here, `steps:` there - so the helper takes both rather
# than existing twice.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:osYaml = @'
# A catalog entry, as Import-HDTOperatingSystem writes one.
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
description: Staged from the volume licence media
type: wim
architecture: x64
sourcePath: sources\install.wim
importedUtc: '2026-08-13T09:14:22.0000000Z'
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    version: 10.0.26100.1
'@

    $script:line = { [string[]] @($script:osYaml -split "`r?`n") }
}

Describe 'Set-HDTOperatingSystemProperty' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Set-HDTOperatingSystemProperty' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'replaces the name and leaves every other line alone' {
        $before = & $script:line
        $after = @(Set-HDTOperatingSystemProperty -Line $before -Name 'Windows 11 LTSC, renamed' -Confirm:$false)

        ($after | Where-Object { $_ -like 'name:*' }) | Should -BeExactly 'name: Windows 11 LTSC, renamed'
        @($after).Count | Should -Be @($before).Count

        # THE COMMENT AT THE TOP IS THE POINT. A UI that reformats the file
        # breaks git review, so the splice is line-for-line.
        [string] $after[0] | Should -BeExactly ([string] $before[0])
        ($after | Where-Object { $_ -like 'sourcePath:*' }) | Should -BeExactly 'sourcePath: sources\install.wim'
    }

    It 'renames the OPERATING SYSTEM, not the first image in the list' {
        # images: opens a block, and every image inside it has a name. A splice
        # that matched the word alone would rename index 1 instead.
        $after = @(Set-HDTOperatingSystemProperty -Line (& $script:line) -Name 'renamed' -Confirm:$false)

        ($after | Where-Object { $_ -match '^\s+name: Windows 11 Enterprise LTSC$' }) | Should -Not -BeNullOrEmpty
    }

    It 'writes a description where a reader looks for it' {
        $bare = [string[]] @(& $script:line | Where-Object { $_ -notlike 'description:*' })
        $after = @(Set-HDTOperatingSystemProperty -Line $bare -Description 'Volume licence media' -Confirm:$false)

        $at = [array]::IndexOf($after, 'description: Volume licence media')
        $at | Should -BeGreaterThan 0
        [string] $after[$at - 1] | Should -BeLike 'name:*'
    }

    It 'takes the description away when it is emptied' {
        $after = @(Set-HDTOperatingSystemProperty -Line (& $script:line) -Description '' -Confirm:$false)

        @($after | Where-Object { $_ -like 'description:*' }) | Should -BeNullOrEmpty
    }

    It 'refuses to clear the name, which the tree and the wizard both show' {
        { Set-HDTOperatingSystemProperty -Line (& $script:line) -Name '' -Confirm:$false } | Should -Throw
    }

    It 'refuses to be asked for nothing' {
        { Set-HDTOperatingSystemProperty -Line (& $script:line) -Confirm:$false } | Should -Throw
    }

    It 'refuses a document it cannot read, before it edits anything' {
        { Set-HDTOperatingSystemProperty -Line ([string[]] @('id: [broken')) -Name 'x' -Confirm:$false } | Should -Throw
    }
}

Describe 'Save-HDTOperatingSystemDocument' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Save-HDTOperatingSystemDocument' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the lines it was given' {
        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\OperatingSystems\Win11\os.yaml' = $script:osYaml }
        $line = @(Set-HDTOperatingSystemProperty -Line (& $script:line) -Name 'Renamed' -Confirm:$false)

        [void] (Save-HDTOperatingSystemDocument -Path 'C:\ws\OperatingSystems\Win11\os.yaml' -Line $line `
                -FileSystem $fileSystem -Confirm:$false)

        [string] $fileSystem.ReadAllText('C:\ws\OperatingSystems\Win11\os.yaml') | Should -BeLike '*name: Renamed*'
    }

    It 'refuses to write a document that is not a valid catalog entry' {
        # THE SAME GUARD Save-HDTSequenceDocument CARRIES. A window that wrote an
        # unreadable os.yaml would take the share's Operating Systems branch down
        # with it, and the next thing anybody sees is '(unreadable)'.
        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\OperatingSystems\Win11\os.yaml' = $script:osYaml }

        { Save-HDTOperatingSystemDocument -Path 'C:\ws\OperatingSystems\Win11\os.yaml' `
                -Line ([string[]] @('schemaVersion: 1', 'id: Win11')) -FileSystem $fileSystem -Confirm:$false } |
            Should -Throw

        [string] $fileSystem.ReadAllText('C:\ws\OperatingSystems\Win11\os.yaml') | Should -BeLike '*Windows 11 Enterprise LTSC 2024*'
    }
}

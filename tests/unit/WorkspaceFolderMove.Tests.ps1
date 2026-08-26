# THE ORDER THE CONSOLE TREE DRAWS FOLDERS IN, CHANGED.
#
# A folder in this toolkit is a LABEL IN AN ORDERED YAML LIST, not a directory -
# C:\HDTLab\Share\OperatingSystems holds Win11-LTSC-2024 and WS2025-Std and no
# 'Windows' folder at all; that name is one entry in workspace.yaml's
# folders.operatingSystems. So the order already exists, and moving a folder is
# moving an entry in a list somebody wrote - the same shape as
# Move-HDTStepPartition, spliced the same way, with no new stored field
# anywhere.
#
# SIBLINGS ONLY. 'Clients' and 'Servers' are both top level and swap with each
# other; 'Clients\Laptops' moves among the other folders inside Clients. A move
# that could reparent a folder would be a different operation with a different
# name.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:doc = [string[]] @(@'
schemaVersion: 1
id: LAB
name: the lab share
deployRoot: \\host\share
folders:
  taskSequences:
    # the ones a technician builds most
    - Clients
    - Clients\Laptops
    - Clients\Desktops
    - Servers
'@ -split "`r?`n")

    function Get-HDTTestFolderList {
        [CmdletBinding()]
        [OutputType([string[]])]
        param([string[]] $Line)

        return [string[]] @($Line |
                Where-Object { $_ -match '^\s+- ' } |
                ForEach-Object { ($_ -replace '^\s+- ', '').Trim() })
    }
}

Describe 'Move-HDTWorkspaceFolder' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Move-HDTWorkspaceFolder' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'moving among siblings' {

        It 'moves a top-level folder down past the next top-level one' {
            $moved = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Clients' -Direction Down -Confirm:$false

            # Clients takes its two children with it, because they are written
            # directly beneath it and a document nobody can read is not a fix.
            Get-HDTTestFolderList -Line $moved |
                Should -Be @('Servers', 'Clients', 'Clients\Laptops', 'Clients\Desktops')
        }

        It 'moves it back up again' {
            $down = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Clients' -Direction Down -Confirm:$false

            $up = Move-HDTWorkspaceFolder -Line $down -Category TaskSequence `
                -Folder 'Clients' -Direction Up -Confirm:$false

            ($up -join "`n") | Should -BeExactly ($script:doc -join "`n")
        }

        It 'moves a child among the other children of its own parent' {
            $moved = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Clients\Desktops' -Direction Up -Confirm:$false

            Get-HDTTestFolderList -Line $moved |
                Should -Be @('Clients', 'Clients\Desktops', 'Clients\Laptops', 'Servers')
        }

        It 'leaves the document alone at the top of its own level' {
            # NOT AN ERROR. The button is pressed at the end of a list by anybody
            # finding out where the end is, and a refusal there would be a
            # message about nothing.
            $same = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Clients' -Direction Up -Confirm:$false

            ($same -join "`n") | Should -BeExactly ($script:doc -join "`n")
        }

        It 'leaves the document alone at the bottom of its own level' {
            $same = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Servers' -Direction Down -Confirm:$false

            ($same -join "`n") | Should -BeExactly ($script:doc -join "`n")
        }

        It 'keeps the comment somebody wrote above the list' {
            # Comments die at parse time, which is why this splices.
            $moved = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Servers' -Direction Up -Confirm:$false

            ($moved -join "`n") | Should -BeLike '*# the ones a technician builds most*'
        }

        It 'still reads back as a workspace document' {
            $moved = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                -Folder 'Servers' -Direction Up -Confirm:$false

            $reader = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = ($moved -join [System.Environment]::NewLine)
            }

            (Import-HDTWorkspaceDocument -Path 'C:\ws\workspace.yaml' -FileSystem $reader).Id |
                Should -BeExactly 'LAB'
        }
    }

    Context 'what it refuses' {

        It 'refuses a folder this share has not declared' {
            { Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
                    -Folder 'Kiosks' -Direction Up -Confirm:$false } |
                Should -Throw '*Kiosks*'
        }

        It 'refuses a category with no folders at all, by saying so' {
            { Move-HDTWorkspaceFolder -Line $script:doc -Category Application `
                    -Folder 'Anything' -Direction Up -Confirm:$false } |
                Should -Throw '*Anything*'
        }
    }

    It 'writes nothing under -WhatIf' {
        $same = Move-HDTWorkspaceFolder -Line $script:doc -Category TaskSequence `
            -Folder 'Servers' -Direction Up -WhatIf

        ($same -join "`n") | Should -BeExactly ($script:doc -join "`n")
    }
}

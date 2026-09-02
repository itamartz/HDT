# The other half of the update catalog. Import-HDTWindowsUpdate registers an
# entry and refuses to replace one; this changes the two things about an entry
# that are an administrator's own words rather than the package's.
#
# NAME AND DESCRIPTION ONLY, AND THAT IS SAFE BY CONSTRUCTION. The ApplyUpdates
# step selects by RELEASE - never by id and never by name - so nothing in a
# deployment matches on either of these. The id is left alone because it is the
# folder name under WindowsUpdates\ as well as a key in the file, so changing it
# is a move rather than an edit.
#
# IT SPLICES, IT NEVER RE-SERIALISES, the rule every other HDT setter follows:
# a parse-then-write round trip drops every comment in the file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\Share\WindowsUpdates\KB5094126-x64\update.yaml'

    # The shape Import-HDTWindowsUpdate writes, with a comment header the way a
    # hand-edited one carries. No description: the box was left blank at import,
    # which is the case that sent somebody looking for a way to add one.
    $script:original = @(
        '# Imported from the Update Catalogue on 2026-09-01.'
        '#'
        '# The .msu sits beside this file.'
        'schemaVersion: 1'
        'id: KB5094126-x64'
        'kb: KB5094126'
        'name: KB5094126 for Windows 11 24H2'
        'release: Win11-24H2'
        'kind: CumulativeUpdate'
        'architecture: x64'
        'fileName: windows11.0-kb5094126-x64.msu'
        'sizeBytes: 5111500010'
        'baselineVersion: 10.0.26100.1742'
        'targetVersion: 10.0.26100.8655'
        'build: 26100'
        'revision: 8655'
        'enabled: true'
    ) -join [System.Environment]::NewLine

    # The same document, already carrying a description, for the replace and
    # remove cases.
    $script:described = @(
        '# Imported from the Update Catalogue on 2026-09-01.'
        '#'
        '# The .msu sits beside this file.'
        'schemaVersion: 1'
        'id: KB5094126-x64'
        'kb: KB5094126'
        'name: KB5094126 for Windows 11 24H2'
        'description: The old note.'
        'release: Win11-24H2'
        'kind: CumulativeUpdate'
        'architecture: x64'
        'fileName: windows11.0-kb5094126-x64.msu'
        'enabled: true'
    ) -join [System.Environment]::NewLine
}

Describe 'Set-HDTWindowsUpdate' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:catalogPath = $script:original
        }
    }

    Context 'splicing' {

        It 'changes the name it was asked to change' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name '2026-06 cumulative, Windows 11 24H2' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.ReadAllText($script:catalogPath) |
                Should -BeLike '*name: 2026-06 cumulative, Windows 11 24H2*'
        }

        It 'leaves every comment in the file' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -FileSystem $script:fileSystem -Confirm:$false

            $text = $script:fileSystem.ReadAllText($script:catalogPath)

            $text | Should -BeLike '*# Imported from the Update Catalogue on 2026-09-01.*'
            $text | Should -BeLike '*# The .msu sits beside this file.*'
        }

        It 'leaves every line it was not asked about byte-identical' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -FileSystem $script:fileSystem -Confirm:$false

            $before = @($script:original -split "`r?`n")
            $after = @($script:fileSystem.ReadAllText($script:catalogPath) -split "`r?`n")

            $after.Count | Should -Be $before.Count

            for ($i = 0; $i -lt $before.Count; $i++) {
                if ($before[$i] -like 'name:*') { continue }
                $after[$i] | Should -BeExactly $before[$i]
            }
        }

        It 'adds a description under the name when the document has none' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Description 'Held back until the June servicing window.' -FileSystem $script:fileSystem -Confirm:$false

            $line = @($script:fileSystem.ReadAllText($script:catalogPath) -split "`r?`n")

            $nameAt = -1
            $descriptionAt = -1

            for ($i = 0; $i -lt $line.Count; $i++) {
                if ($line[$i] -like 'name:*') { $nameAt = $i }
                if ($line[$i] -like 'description:*') { $descriptionAt = $i }
            }

            $descriptionAt | Should -Be ($nameAt + 1)
        }

        It 'replaces a description the document already carries' {
            $script:fileSystem.WriteAllText($script:catalogPath, $script:described)

            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Description 'The new note.' -FileSystem $script:fileSystem -Confirm:$false

            $text = $script:fileSystem.ReadAllText($script:catalogPath)

            $text | Should -BeLike '*description: The new note.*'
            $text | Should -Not -BeLike '*The old note.*'
        }

        It 'takes the description away when it is emptied' {
            $script:fileSystem.WriteAllText($script:catalogPath, $script:described)

            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Description '' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*description:*'
        }

        It 'writes both when both are asked for' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -Description 'A note.' -FileSystem $script:fileSystem -Confirm:$false

            $text = $script:fileSystem.ReadAllText($script:catalogPath)

            $text | Should -BeLike '*name: Renamed*'
            $text | Should -BeLike '*description: A note.*'
        }

        It 'leaves the id alone, because it is the folder name' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeLike '*id: KB5094126-x64*'
        }

        It 'offers no parameter that would change the id' {
            $parameter = @((Get-Command -Name 'Set-HDTWindowsUpdate').Parameters.Keys)

            $parameter | Should -Not -Contain 'NewId'
            $parameter | Should -Not -Contain 'Kb'
            $parameter | Should -Not -Contain 'Release'
        }
    }

    Context 'refusals' {

        It 'refuses when nothing was asked of it' {
            { Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                    -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*nothing was asked*'
        }

        It 'refuses to clear the name' {
            { Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                    -Name '' -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*cannot be cleared*'
        }

        It 'names the update when there is no such entry' {
            { Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB0000000-x64' `
                    -Name 'Renamed' -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*KB0000000-x64*'
        }

        It 'leaves the file exactly as it was when the edit is refused' {
            try {
                Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                    -Name '' -FileSystem $script:fileSystem -Confirm:$false
            } catch {
                # THE THROW IS THE POINT, AND THE FILE IS THE ASSERTION. Which
                # message it carries is the test above; what this one is for is
                # that a refused edit leaves the catalogue byte-identical, so the
                # error is caught and named rather than swallowed - an empty
                # catch here is also the one the analyzer refuses.
                Write-Verbose ("the edit was refused, which is the case under test: {0}" -f [string] $_.Exception.Message)
            }

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeExactly $script:original
        }
    }

    Context 'what it gives back' {

        It 'returns the update as Get-HDTWindowsUpdate reads it' {
            $changed = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -Description 'A note.' -FileSystem $script:fileSystem -Confirm:$false

            $changed.Id | Should -BeExactly 'KB5094126-x64'
            $changed.Name | Should -BeExactly 'Renamed'
            $changed.Description | Should -BeExactly 'A note.'
            $changed.Kb | Should -BeExactly 'KB5094126'
        }

        It 'writes nothing under -WhatIf' {
            $null = Set-HDTWindowsUpdate -WorkspaceRoot $script:workspaceRoot -Id 'KB5094126-x64' `
                -Name 'Renamed' -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeExactly $script:original
        }
    }
}

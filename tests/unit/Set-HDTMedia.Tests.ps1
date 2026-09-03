# Set-HDTMedia edits one key of Media\<id>\media.yaml by SPLICING it.
#
# THE BYTE-IDENTICAL ASSERTION IS THE POINT OF THIS FILE. media.yaml is a
# document an administrator hand-edits and comments, and comments die at parse
# time - a round trip through the YAML writer would take every one of them out.
# "Comments survive" is not provable by counting lines, so the test reads the
# text before and after and compares every line index except the one that
# changed.
#
# Nothing here touches a disk: X:\ is a drive this session has not mounted.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'X:\Share'
    $script:documentPath = 'X:\Share\Media\M1\media.yaml'

    # A hand-edited document: two header comments, a blank line, and a comment
    # sitting directly above the key the tests change.
    $script:commentedYaml = @(
        '# HDT standalone media definition - the media item MDT keeps under Advanced Configuration.'
        '# Update-HDTMediaContent projects the share through the selection profile below.'
        ''
        'schemaVersion: 1'
        'id: M1'
        '# what the technicians call this disc'
        'name: Media one'
        'selectionProfile: everything'
        'output: Media\M1\HDT_M1.iso'
        'enabled: true'
    ) -join "`r`n"

    $script:profileYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: field-kit'
        '    name: Field kit'
        '    include:'
        '      - Applications\7Zip-24.09'
    ) -join "`r`n"
}

Describe 'Set-HDTMedia' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            'X:\Share\Media\M1\media.yaml'             = $script:commentedYaml
            'X:\Share\Control\selection-profiles.yaml' = $script:profileYaml
        }
    }

    Context 'it splices' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Set-HDTMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'changes name and leaves every other line byte-identical' {
            $before = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            @($after).Count | Should -Be @($before).Count

            for ($i = 0; $i -lt @($before).Count; $i++) {
                if ($before[$i] -match '^name\s*:') { continue }
                $after[$i] | Should -BeExactly $before[$i] -Because "line $i was not asked about"
            }

            $after[6] | Should -BeExactly 'name: Media renamed'
        }

        It 'keeps every comment in the document, including the ones above the key it changed' {
            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem

            $after = $script:fileSystem.ReadAllText($script:documentPath)

            $after | Should -BeLike '*# HDT standalone media definition*'
            $after | Should -BeLike '*# Update-HDTMediaContent projects*'
            $after | Should -BeLike '*# what the technicians call this disc*'
        }

        It 'changes <Key>, on its own' -ForEach @(
            @{ Key = 'SelectionProfile'; Value = 'field-kit';           Line = 'selectionProfile: field-kit' }
            @{ Key = 'Output';           Value = 'D:\Builds\field.iso'; Line = 'output: D:\Builds\field.iso' }
        ) {
            $splat = @{
                WorkspaceRoot = $script:root
                Id            = 'M1'
                FileSystem    = $script:fileSystem
                $Key          = $Value
            }

            $null = Set-HDTMedia @splat

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")
            $after | Should -Contain $Line
        }

        It 'changes enabled to false, written as the bare lowercase YAML boolean' {
            $media = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Enabled $false `
                -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")
            $after | Should -Contain 'enabled: false'
            $media.Enabled | Should -BeFalse
        }

        It 'changes two keys in one call without disturbing the lines between them' {
            $before = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -Enabled $false -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            @($after).Count | Should -Be @($before).Count

            for ($i = 0; $i -lt @($before).Count; $i++) {
                if ($i -eq 6 -or $i -eq 9) { continue }
                $after[$i] | Should -BeExactly $before[$i] -Because "line $i sits between the two edits"
            }
        }

        It 'inserts a description that was not there, in the document''s own key order' {
            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Description 'Engineers laptop build' `
                -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            $nameAt = [array]::FindIndex([string[]] $after, [Predicate[string]] { param($l) $l -match '^name\s*:' })
            $descriptionAt = [array]::FindIndex([string[]] $after, [Predicate[string]] { param($l) $l -match '^description\s*:' })
            $profileAt = [array]::FindIndex([string[]] $after, [Predicate[string]] { param($l) $l -match '^selectionProfile\s*:' })

            $descriptionAt | Should -BeGreaterThan $nameAt
            $descriptionAt | Should -BeLessThan $profileAt
        }

        It 'removes the description when passed an empty string' {
            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Description 'Engineers laptop build' `
                -FileSystem $script:fileSystem

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Description '' `
                -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            @($after | Where-Object { $_ -match '^description\s*:' }) | Should -BeNullOrEmpty
        }

        It 'never rewrites a key it was not asked about' {
            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem

            $after = @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n")

            $after | Should -Contain 'selectionProfile: everything'
            $after | Should -Contain 'output: Media\M1\HDT_M1.iso'
            $after | Should -Contain 'enabled: true'
            $after | Should -Contain 'id: M1'
        }

        It 'splices past a value carrying the word steps, because media.yaml has no nested block' {
            # -Block is passed explicitly for this case. Left at the sequence/os
            # default of 'steps|variables' the scan can end the header early, and
            # every key below it is inserted rather than replaced.
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (@(
                        'schemaVersion: 1'
                        'id: M1'
                        'name: Media one'
                        'selectionProfile: everything'
                        'output: Media\M1\steps.iso'
                        'enabled: true'
                    ) -join "`r`n")
            }

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Enabled $false -FileSystem $fs

            $after = @($fs.ReadAllText('X:\Share\Media\M1\media.yaml') -split "`r?`n")

            @($after | Where-Object { $_ -match '^enabled\s*:' }).Count | Should -Be 1
            $after | Should -Contain 'enabled: false'
            $after | Should -Contain 'output: Media\M1\steps.iso'
        }
    }

    Context 'it refuses' {

        It 'refuses a selectionProfile the share does not have' {
            { Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -SelectionProfile 'no-such-profile' `
                    -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*field-kit*'
        }

        It 'reads the selection profiles through the injected filesystem, never the real one' {
            # field-kit is only on the fake. A call that dropped -FileSystem on
            # Get-HDTSelectionProfile would read the real disk and refuse it.
            { Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -SelectionProfile 'field-kit' `
                    -FileSystem $script:fileSystem } |
                Should -Not -Throw
        }

        It 'refuses an output that is not an .iso' {
            { Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Output 'Media\M1\field.wim' `
                    -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*.iso*'
        }

        It 'refuses a media id the share does not have' {
            { Set-HDTMedia -WorkspaceRoot $script:root -Id 'M9' -Name 'x' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*media.yaml*'
        }

        It 'refuses to change the id, because the id is the folder name' {
            # There is no parameter that renames one, deliberately: the id names
            # the folder Remove-HDTMedia deletes, so a rename is a folder move
            # and not a document edit.
            $parameter = @((Get-Command -Name 'Set-HDTMedia').Parameters.Keys)

            $parameter | Should -Not -Contain 'NewId'
            $parameter | Should -Not -Contain 'Rename'

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem

            @($script:fileSystem.ReadAllText($script:documentPath) -split "`r?`n") | Should -Contain 'id: M1'
        }

        It 'refuses a call that asks for nothing' {
            { Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*nothing*'
        }

        It 'writes nothing when -WhatIf is passed' {
            $before = $script:fileSystem.ReadAllText($script:documentPath)

            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.ReadAllText($script:documentPath) | Should -BeExactly $before
        }
    }

    Context 'what it leaves behind' {

        It 'writes a document Assert-HDTMediaDocument still accepts' {
            $null = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -Description 'Engineers laptop build' -Enabled $false -FileSystem $script:fileSystem

            $text = $script:fileSystem.ReadAllText($script:documentPath)

            InModuleScope Hephaestus -Parameters @{ Yaml = $text; Path = $script:documentPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path -Id 'M1' } | Should -Not -Throw
            }
        }

        It 'returns the media object as Get-HDTMedia would read it back' {
            $returned = Set-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -Name 'Media renamed' `
                -FileSystem $script:fileSystem

            $read = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem

            $returned.Name | Should -BeExactly $read.Name
            $returned.OutputPath | Should -BeExactly $read.OutputPath
            $returned.WorkspaceRoot | Should -BeExactly $script:root
        }
    }
}

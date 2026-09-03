# Assert-HDTMediaDocument is the gate that actually runs in WinPE, where
# Test-Json does not exist. schemas/media.schema.json is the gate the console, an
# editor and CI use; this file is where the MESSAGE an administrator reads is
# held in place.
#
# It is private, so every assertion runs inside InModuleScope.
#
# TWO OF THESE TESTS ARE NOT THEATRE. `output` becomes a path this toolkit
# writes a multi-gigabyte ISO to, and `id` becomes the folder Remove-HDTMedia
# deletes. Both are closed here, at the point the value is typed, rather than at
# the point it is used.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:mediaPath = 'C:\HDTLab\does-not-exist\Share\Media\WIN11-FIELD\media.yaml'

    # THE CANONICAL DOCUMENT, and the only place this file writes the key set
    # down. Every test below derives from it, so a key added to the model is
    # added here once and the set-driven tests pick it up.
    $script:canonicalKey = [ordered] @{
        schemaVersion    = '1'
        id               = 'WIN11-FIELD'
        name             = 'Windows 11 field media'
        description      = "Engineers' laptop build, no network"
        selectionProfile = 'everything'
        output           = 'Media\WIN11-FIELD\HDT_WIN11-FIELD.iso'
        enabled          = 'true'
    }

    # The keys a media document may leave out. Everything else in the canonical
    # document is required, and the set-driven test below proves it by removing
    # each one in turn.
    $script:optionalKey = @('description', 'enabled')

    # Composes a media.yaml text from the canonical document, with keys changed
    # or dropped. A scriptblock rather than a function so nothing in a test file
    # declares a command name.
    $script:newMediaYaml = {
        param(
            [System.Collections.IDictionary] $Set = @{},
            [string[]] $Drop = @(),
            [string[]] $Comment = @()
        )

        $line = New-Object -TypeName System.Collections.ArrayList
        [void] $line.Add('# HDT standalone media definition.')

        foreach ($extra in @($Comment)) { [void] $line.Add($extra) }

        foreach ($key in @($script:canonicalKey.Keys)) {
            if (@($Drop) -contains $key) { continue }

            $value = $script:canonicalKey[$key]
            if ($Set.Contains($key)) { $value = $Set[$key] }

            [void] $line.Add(('{0}: {1}' -f $key, $value))
        }

        foreach ($key in @($Set.Keys)) {
            if (@($script:canonicalKey.Keys) -contains $key) { continue }
            [void] $line.Add(('{0}: {1}' -f $key, $Set[$key]))
        }

        return (@($line) -join "`r`n")
    }
}

Describe 'Assert-HDTMediaDocument' {

    Context 'the document itself' {

        It 'refuses a null document, reporting an empty file rather than crashing' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:mediaPath } {
                param($Path)

                { Assert-HDTMediaDocument -Document $null -Path $Path } |
                    Should -Throw -ExpectedMessage '*empty*'
            }
        }

        It 'refuses a document that is not a mapping, naming what it is instead' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:mediaPath } {
                param($Path)

                { Assert-HDTMediaDocument -Document 'not a mapping' -Path $Path } |
                    Should -Throw -ExpectedMessage '*String*'
            }
        }

        It 'refuses a key a media document does not declare, and lists the ones it may' {
            $yaml = & $script:newMediaYaml -Set @{ mediaPath = 'D:\somewhere' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage "*'mediaPath'*selectionProfile*"
            }
        }

        It 'refuses a missing schemaVersion' {
            $yaml = & $script:newMediaYaml -Drop 'schemaVersion'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*schemaVersion is missing*'
            }
        }

        It 'refuses a schemaVersion that is not an integer' {
            $yaml = & $script:newMediaYaml -Set @{ schemaVersion = "'one'" }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*schemaVersion must be an integer*'
            }
        }

        It 'refuses a schemaVersion newer than this engine understands' {
            $yaml = & $script:newMediaYaml -Set @{ schemaVersion = '2' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*newer than this engine understands*'
            }
        }

        It 'accepts the seven keys and nothing else, read off one canonical document' {
            # WRITTEN AGAINST THE SET, not against one key. Each key is removed in
            # turn: an optional one must still validate, a required one must fail
            # with a message naming it. A test that names one new key passes for
            # it and fails nobody after it.
            @($script:canonicalKey.Keys).Count | Should -Be 7 -Because 'the media document declares exactly seven keys'

            $whole = & $script:newMediaYaml

            InModuleScope Hephaestus -Parameters @{ Yaml = $whole; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                { Assert-HDTMediaDocument -Document $document -Path $Path } | Should -Not -Throw
            }

            foreach ($key in @($script:canonicalKey.Keys)) {
                $partial = & $script:newMediaYaml -Drop $key
                $optional = (@($script:optionalKey) -contains $key)

                InModuleScope Hephaestus -Parameters @{
                    Yaml     = $partial
                    Path     = $script:mediaPath
                    Key      = $key
                    Optional = $optional
                } {
                    param($Yaml, $Path, $Key, $Optional)

                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                    if ($Optional) {
                        { Assert-HDTMediaDocument -Document $document -Path $Path } |
                            Should -Not -Throw -Because "$Key is optional"
                    } else {
                        { Assert-HDTMediaDocument -Document $document -Path $Path } |
                            Should -Throw -ExpectedMessage ('*{0}*' -f $Key) -Because "$Key is required and the message must name it"
                    }
                }
            }
        }
    }

    Context 'identity' {

        It 'refuses a missing id' {
            $yaml = & $script:newMediaYaml -Drop 'id'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*id is missing*'
            }
        }

        It 'refuses an id that is not a legal folder name - <_>' -ForEach @(
            "'a media'"
            "'..\..\Windows'"
            "'Media/Win11'"
            "'*'"
            "'.'"
            "'..'"
        ) {
            $yaml = & $script:newMediaYaml -Set @{ id = $_ }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*not a legal media id*'
            }
        }

        It 'refuses an id that does not match the folder it was read from' {
            $yaml = & $script:newMediaYaml

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path -Id 'WIN11-DESK' } |
                    Should -Throw -ExpectedMessage '*WIN11-DESK*'
            }
        }

        It 'accepts an id that matches the folder it was read from' {
            $yaml = & $script:newMediaYaml

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path -Id 'WIN11-FIELD' } |
                    Should -Not -Throw
            }
        }

        It 'refuses a missing or blank name' -ForEach @(
            @{ Drop = @('name'); Set = @{} }
            @{ Drop = @();       Set = @{ name = "''" } }
        ) {
            $yaml = & $script:newMediaYaml -Set $Set -Drop $Drop

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*name is missing*'
            }
        }
    }

    Context 'the projection settings' {

        It 'refuses a missing selectionProfile - the whole projection is that one value' {
            $yaml = & $script:newMediaYaml -Drop 'selectionProfile'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*selectionProfile is missing*'
            }
        }

        It 'refuses a blank selectionProfile' {
            $yaml = & $script:newMediaYaml -Set @{ selectionProfile = "''" }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*selectionProfile is missing*'
            }
        }

        It 'refuses a selectionProfile that is not a legal profile id' {
            $yaml = & $script:newMediaYaml -Set @{ selectionProfile = "'..\\everything'" }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*not a legal selection profile id*'
            }
        }

        It 'refuses a missing or blank output' -ForEach @(
            @{ Drop = @('output'); Set = @{} }
            @{ Drop = @();         Set = @{ output = "''" } }
        ) {
            $yaml = & $script:newMediaYaml -Set $Set -Drop $Drop

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*output is missing*'
            }
        }

        It 'refuses an output that is not an .iso, because HDT emits one artifact and it is an ISO' {
            $yaml = & $script:newMediaYaml -Set @{ output = 'Media\WIN11-FIELD\HDT_WIN11-FIELD.wim' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*.iso*'
            }
        }

        It 'refuses an output whose relative form escapes the share with a .. segment' {
            $yaml = & $script:newMediaYaml -Set @{ output = 'Media\..\..\Windows\hdt.iso' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage "*'..'*"
            }
        }

        It 'refuses an enabled that is not a boolean' {
            $yaml = & $script:newMediaYaml -Set @{ enabled = "'yes please'" }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*enabled must be true or false*'
            }
        }
    }

    Context 'what it accepts' {

        It 'accepts a document with no description, which is the ordinary case' {
            $yaml = & $script:newMediaYaml -Drop 'description'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'accepts an output that is rooted, because media is routinely written to another disk' {
            $yaml = & $script:newMediaYaml -Set @{ output = 'D:\Builds\HDT_WIN11-FIELD.iso' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'accepts a UNC output, which is the other share a build lands on' {
            $yaml = & $script:newMediaYaml -Set @{ output = '\\fileserver\builds\HDT_WIN11-FIELD.iso' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'accepts enabled false, which is a media item somebody turned off' {
            $yaml = & $script:newMediaYaml -Set @{ enabled = 'false' }

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMediaDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'returns nothing at all for a valid document' {
            $yaml = & $script:newMediaYaml

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $result = Assert-HDTMediaDocument -Document $document -Path $Path
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'every failure is the same shape as the rest of the family' {

        It 'throws a terminating error carrying the file as its TargetObject' {
            $yaml = & $script:newMediaYaml -Drop 'output'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try {
                    Assert-HDTMediaDocument -Document $document -Path $Path
                } catch {
                    $record = $_
                }

                $record | Should -Not -BeNullOrEmpty
                $record.TargetObject | Should -BeExactly $Path
            }
        }

        It 'reports HDTConfigurationError, as every other Assert-HDT*Document does' {
            $yaml = & $script:newMediaYaml -Drop 'output'

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:mediaPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try {
                    Assert-HDTMediaDocument -Document $document -Path $Path
                } catch {
                    $record = $_
                }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }
    }
}

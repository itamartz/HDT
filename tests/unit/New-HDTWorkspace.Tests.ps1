# DESIGN 2.1 fixes the workspace layout, and until now nothing in HDT could
# produce one. The engine could READ a deployment share - Get-HDTWorkspacePath
# knew the folder names, Import-HDTWorkspaceDocument and Import-HDTRuleDocument
# read the two root documents, Get-HDTConsoleWorkspace reported on the whole
# thing - but every one of those needed a share somebody else had made by hand.
# That is the opposite of the Deployment Workbench, whose FIRST action is "New
# Deployment Share".
#
# The two assertions that matter most here:
#
#   1. THE LAYOUT IS READ OUT OF Get-HDTWorkspacePath, not restated. This file
#      pulls the ValidateSet off that command's -Kind parameter and demands a
#      folder for every value in it, so a folder added to the layout and
#      forgotten here turns this red rather than silently going uncreated.
#
#   2. WHAT IT WRITES IS WHAT THE ENGINE READS. The round trip goes back through
#      Import-HDTWorkspaceDocument and Import-HDTRuleDocument, not through a
#      second opinion about YAML.
#
# Nothing here touches a real disk: every call takes the hand-written fake
# filesystem, and one test proves the workspace root was never created for real.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\NewShare'
    $script:workspacePath = 'C:\HDTLab\does-not-exist\NewShare\workspace.yaml'
    $script:rulePath = 'C:\HDTLab\does-not-exist\NewShare\rules.yaml'

    # The layout, taken from the one place it is written down in code.
    $script:layoutKind = @(
        (Get-Command -Name Get-HDTWorkspacePath -ErrorAction Stop).Parameters['Kind'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
}

Describe 'New-HDTWorkspace' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
    }

    Context 'the share tree' {

        It 'creates the workspace root' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($script:workspaceRoot) | Should -BeTrue
        }

        It 'knows the layout has folders to create' {
            # A test that scans nothing passes for the wrong reason.
            @($script:layoutKind).Count | Should -BeGreaterThan 5
            $script:layoutKind | Should -Contain 'Control'
            $script:layoutKind | Should -Contain 'Logs'
            $script:layoutKind | Should -Contain 'Boot'
        }

        It 'creates a folder for every kind the workspace layout defines' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            foreach ($kind in $script:layoutKind) {
                $expected = Get-HDTWorkspacePath -Root $script:workspaceRoot -Kind $kind
                $script:fileSystem.TestPath($expected) | Should -BeTrue -Because ("the layout defines {0}\" -f $kind)
            }
        }

        It 'creates a Media folder on a new share' {
            # Standalone media is a document family like any other, so a new
            # share has the folder that holds it. Nothing in New-HDTWorkspace
            # names Media: it is in Get-HDTWorkspacePath's -Kind set and the
            # loop above reads that set, which is what the set-driven test
            # immediately above this one proves.
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $media = Get-HDTWorkspacePath -Root $script:workspaceRoot -Kind Media
            $script:fileSystem.TestPath($media) | Should -BeTrue
        }

        It 'creates Control\machines, where a per-machine override lands' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $machine = Get-HDTWorkspacePath -Root $script:workspaceRoot -Kind Control -ChildPath 'machines'
            $script:fileSystem.TestPath($machine) | Should -BeTrue
        }

        It 'creates every folder through the injected filesystem' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $script:fileSystem.GetOperationName() | Should -Contain 'CreateDirectory'
        }

        It 'creates nothing on the real disk' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            Test-Path -LiteralPath $script:workspaceRoot | Should -BeFalse
        }
    }

    Context 'the documents it writes' {

        It 'writes workspace.yaml at the root of the share' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($script:workspacePath) | Should -BeTrue
        }

        It 'writes rules.yaml at the root of the share' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($script:rulePath) | Should -BeTrue
        }

        It 'writes a workspace document the engine reads back' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' `
                -Name 'HDT lab deployment share' -DeployRoot '\\HDT-HOST\HdtShare' `
                -FileSystem $script:fileSystem

            $document = Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $script:fileSystem

            $document.SchemaVersion | Should -Be 1
            $document.Id | Should -BeExactly 'HDT-LAB'
            $document.Name | Should -BeExactly 'HDT lab deployment share'
            $document.DeployRoot | Should -BeExactly '\\HDT-HOST\HdtShare'
        }

        It 'names the share after its id when no name is given' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $script:fileSystem).Name |
                Should -BeExactly 'HDT-LAB'
        }

        It 'leaves deployRoot unstated when the share does not know its own address yet' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $script:fileSystem).DeployRoot |
                Should -BeExactly ''
        }

        It 'says nothing about the boot image, so the importer defaults stay the only answer' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $document = Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $script:fileSystem

            $document.BootImage.Architecture | Should -BeExactly 'amd64'
            $document.BootImage.OptionalComponent | Should -Contain 'WinPE-SecureStartup'
        }

        It 'writes a rules document the engine reads back' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $document = Import-HDTRuleDocument -Path $script:rulePath -FileSystem $script:fileSystem

            $document.SchemaVersion | Should -Be 1
            @($document.Rule).Count | Should -BeGreaterThan 0
        }

        Context 'the language and region a new share starts with' {

            # VISIBLE IN THE SHARE'S OWN DOCUMENT, NOT ONLY IN THE ENGINE.
            # unattend.xml asks for these four as tokens, and the engine seeds
            # US English when nothing else answers - but a default nobody can
            # see is a default nobody changes. MDT shipped CustomSettings.ini
            # with KeyboardLocale, UILanguage and UserLocale written out for
            # exactly this reason: the line you edit has to already be there.

            BeforeEach {
                $localeFileSystem = New-HDTFakeFileSystem
                $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $localeFileSystem

                $script:localeDocument = Import-HDTRuleDocument -Path $script:rulePath -FileSystem $localeFileSystem
                $script:localeText = [string] $localeFileSystem.ReadAllText($script:rulePath)
            }

            It 'states <Variable>, which the answer file asks for by name' -ForEach @(
                @{ Variable = 'HDTKeyboardLocale'; Value = '0409:00000409' }
                @{ Variable = 'HDTSystemLocale'; Value = 'en-US' }
                @{ Variable = 'HDTUILanguage'; Value = 'en-US' }
                @{ Variable = 'HDTUserLocale'; Value = 'en-US' }
            ) {
                $set = @($script:localeDocument.Rule | Where-Object { $null -ne $_.Set } |
                        Where-Object { @($_.Set.Keys) -contains $Variable })

                $set.Count | Should -BeGreaterThan 0 -Because "$Variable is what unattend.xml asks for"
                [string] $set[0].Set[$Variable] | Should -BeExactly $Value
            }

            It 'puts them where they can be changed without touching the fallback' {
                # A rule of their own, named for what it does: an administrator
                # changing the keyboard should not be reading a rule about
                # computer names.
                @($script:localeDocument.Rule | ForEach-Object { [string] $_.Name }) |
                    Should -Contain 'Language and region'
            }

            It 'leaves them overridable, because a rule above wins' {
                # No when:, so it always applies - but first match wins per
                # variable, so a site rule ABOVE it still decides.
                $rule = @($script:localeDocument.Rule | Where-Object { [string] $_.Name -eq 'Language and region' })[0]

                @($rule.When.Keys).Count | Should -Be 0
            }

            It 'still writes a document the engine accepts' {
                $script:localeDocument.SchemaVersion | Should -Be 1
            }
        }

        Context 'the catalogue of variables it writes into rules.yaml' {

            # WHAT CustomSettings.ini NEVER HAD. An MDT administrator learns the
            # variable names from a wiki, a blog and somebody else's file, and
            # gets them subtly wrong - OSDComputername, SkipWizard, JoinDomain -
            # with no error, because an .ini has no vocabulary. A rules.yaml that
            # ships the list cannot be wrong about it.
            #
            # GENERATED FROM Get-HDTVariableMap, NEVER TYPED. A hand-copied list
            # is a list that goes stale the first time a variable is added, and
            # a stale catalogue is worse than none: it is wrong with authority.

            BeforeEach {
                # ITS OWN FILE SYSTEM. The Describe's BeforeEach hands out a
                # fresh fake per It, and New-HDTWorkspace refuses a directory
                # that already holds a share - so a BeforeAll here would be
                # writing into whatever the last It left behind.
                $catalogueFileSystem = New-HDTFakeFileSystem
                $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $catalogueFileSystem

                $script:catalogueFileSystem = $catalogueFileSystem
                $script:ruleText = [string] $catalogueFileSystem.ReadAllText($script:rulePath)
                $script:ruleLine = [string[]] @($script:ruleText -split "`r?`n")
                $script:map = @(Get-HDTVariableMap)
            }

            It 'names every variable a rule may set' {
                $missing = @($script:map | Where-Object { $_.Writable } |
                        Where-Object { $script:ruleText -notlike ('*{0}*' -f $_.HDTName) } |
                        ForEach-Object { [string] $_.HDTName })

                $missing | Should -BeNullOrEmpty -Because ('these are settable and unlisted: {0}' -f ($missing -join ', '))
            }

            It 'does not offer the engine-owned ones, which a rule may not assign' {
                # They start with _ and Assert-HDTRuleDocument refuses them, so
                # listing them would be teaching a mistake.
                $offered = @($script:map | Where-Object { -not $_.Writable } |
                        Where-Object { $script:ruleText -like ('*{0}*' -f $_.HDTName) } |
                        ForEach-Object { [string] $_.HDTName })

                $offered | Should -BeNullOrEmpty
            }

            It 'says what each one was called in MDT' {
                # The reason somebody is reading this file at all.
                $script:ruleText | Should -BeLike '*OSDComputerName*'
                $script:ruleText | Should -BeLike '*SkipWizard*'
            }

            It 'says where the value comes from when no rule sets one' {
                $script:ruleText | Should -BeLike '*Win32_ComputerSystem.Model*'
            }

            It 'writes the catalogue as comments, so a new share resolves exactly as before' {
                # A set: for fifty variables would override every machine fact
                # the gather produced, on every machine, for ever.
                $start = [array]::IndexOf($script:ruleLine, '# EVERY VARIABLE A RULE MAY SET.')
                $start | Should -BeGreaterThan 0

                $section = @($script:ruleLine[$start..($script:ruleLine.Count - 1)])

                $section.Count | Should -BeGreaterThan 20
                @($section | Where-Object { $_.Trim() -ne '' -and $_.TrimStart() -notlike '#*' }) |
                    Should -BeNullOrEmpty
            }

            It 'still writes a document the engine accepts' {
                $document = Import-HDTRuleDocument -Path $script:rulePath -FileSystem $script:catalogueFileSystem

                $document.SchemaVersion | Should -Be 1
                @($document.Rule).Count | Should -BeGreaterThan 0
            }
        }

        It 'starts the administrator off with a fallback rule, not an empty stub' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $document = Import-HDTRuleDocument -Path $script:rulePath -FileSystem $script:fileSystem
            $fallback = @($document.Rule)[-1]

            # A rule with no when: always applies, which is what makes it the
            # fallback (DESIGN 3.3).
            @($fallback.When.Keys).Count | Should -Be 0
            @($fallback.Set.Keys) | Should -Contain 'HDTComputerName'
        }

        It 'resolves a computer name from the rule it wrote' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $document = Import-HDTRuleDocument -Path $script:rulePath -FileSystem $script:fileSystem
            $resolved = Resolve-HDTVariable -RuleDocument $document -Fact @{ HDTSerialNumber = 'ABC123' }

            $resolved.Variable['HDTComputerName'] | Should -BeExactly 'PC-ABC123'
        }

        It 'writes both documents through the injected filesystem' {
            # NAMED RATHER THAN COUNTED. A share is created with its technician
            # wizard as well now - MDT's New Deployment Share populates Scripts            # the same way - so a count here would be a number that changes
            # every time a sample page is added, asserting nothing.
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $written = @($script:fileSystem.Operations |
                    Where-Object { $_.Operation -eq 'WriteAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] })

            $written | Should -Contain $script:workspacePath
            $written | Should -Contain $script:rulePath
        }

        It 'reports the paths it wrote' {
            $result = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem

            $result.Root | Should -BeExactly $script:workspaceRoot
            $result.Path | Should -BeExactly $script:workspacePath
            $result.RulePath | Should -BeExactly $script:rulePath
            $result.Id | Should -BeExactly 'HDT-LAB'
        }
    }

    Context 'refusing to overwrite' {

        It 'refuses a directory that already holds a workspace, naming the file it found' {
            $existing = New-HDTFakeFileSystem -File @{ $script:workspacePath = 'schemaVersion: 1' }

            $record = $null
            try { New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $existing } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.TargetObject | Should -BeExactly $script:workspacePath
            $record.Exception.Message | Should -BeLike '*workspace.yaml*'
        }

        It 'refuses a directory that already holds a rules file, naming it' {
            $existing = New-HDTFakeFileSystem -File @{ $script:rulePath = 'schemaVersion: 1' }

            $record = $null
            try { New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $existing } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.TargetObject | Should -BeExactly $script:rulePath
        }

        It 'writes nothing when it refuses' {
            $existing = New-HDTFakeFileSystem -File @{ $script:workspacePath = 'schemaVersion: 1' }

            try { New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $existing } catch { $null = $_ }

            $existing.GetOperationName() | Should -Not -Contain 'WriteAllText'
            $existing.GetOperationName() | Should -Not -Contain 'CreateDirectory'
            $existing.ReadAllText($script:workspacePath) | Should -BeExactly 'schemaVersion: 1'
        }

        It 'deletes nothing, ever' {
            $existing = New-HDTFakeFileSystem -File @{ $script:workspacePath = 'schemaVersion: 1' }

            try { New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $existing } catch { $null = $_ }

            $existing.GetOperationName() | Should -Not -Contain 'RemoveItem'
        }

        It 'adds a workspace to a directory that merely exists' {
            $seeded = New-HDTFakeFileSystem
            $seeded.SeedDirectory($script:workspaceRoot)

            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $seeded

            $seeded.TestPath($script:workspacePath) | Should -BeTrue
        }
    }

    Context 'the id' {

        It 'refuses an id that is not a legal workspace id: <_>' -ForEach @('HDT LAB', 'HDT/LAB', '..', '') {
            $id = $_

            $record = $null
            try {
                New-HDTWorkspace -Path $script:workspaceRoot -Id $id -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
        }

        It 'names the offending id rather than a file' {
            $record = $null
            try {
                New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT LAB' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.TargetObject | Should -BeExactly 'HDT LAB'
        }
    }

    Context '-WhatIf' {

        It 'writes nothing' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.TestPath($script:workspacePath) | Should -BeFalse
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
        }

        It 'creates no folder' {
            $null = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'CreateDirectory'
        }

        It 'returns nothing' {
            $result = New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $script:fileSystem -WhatIf

            $result | Should -BeNullOrEmpty
        }

        It 'still refuses an existing workspace' {
            $existing = New-HDTFakeFileSystem -File @{ $script:workspacePath = 'schemaVersion: 1' }

            { New-HDTWorkspace -Path $script:workspaceRoot -Id 'HDT-LAB' -FileSystem $existing -WhatIf } |
                Should -Throw -ExpectedMessage '*workspace.yaml*'
        }
    }

    Context 'the command surface' {

        It 'is exported by the module' {
            (Get-Module -Name Hephaestus).ExportedFunctions.Keys | Should -Contain 'New-HDTWorkspace'
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name New-HDTWorkspace -ErrorAction Stop).Parameters.Keys | Should -Contain 'WhatIf'
        }

        # An administrator types this command; the engine's hot path does not
        # call it. So -FileSystem defaults to the real adapter and
        # 'New-HDTWorkspace -Path ... -Id ...' is a complete call. The default is
        # read off the AST rather than invoked: running it would build a real
        # filesystem service, and a test that creates a share on a real disk is
        # the one thing this file must never do.
        It 'does not make -FileSystem mandatory' {
            $parameter = (Get-Command -Name New-HDTWorkspace -ErrorAction Stop).Parameters['FileSystem']

            @($parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
        }

        It 'defaults -FileSystem to the real adapter' {
            $default = (Get-Command -Name New-HDTWorkspace -ErrorAction Stop).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'FileSystem' }

            $default.DefaultValue.Extent.Text | Should -BeLike '*New-HDTFileSystem*'
        }

        It 'has comment-based help with a synopsis and an example' {
            $help = Get-Help -Name New-HDTWorkspace -ErrorAction Stop

            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -BeLike '*New-HDTWorkspace*[[]*'
            @($help.Examples.Example).Count | Should -BeGreaterThan 0
        }

        It 'cites no internal document an administrator does not have' {
            $help = Get-Help -Name New-HDTWorkspace -ErrorAction Stop
            $text = ($help | Out-String)

            $text | Should -Not -Match 'DESIGN \d'
            $text | Should -Not -Match 'SPIKES'
            $text | Should -Not -Match 'ROADMAP'
            $text | Should -Not -Match 'CLAUDE\.md'
        }
    }
}

# The schema is the gate the console, an editor and CI use; the engine's own
# Assert-* validators are what run in WinPE. What this command writes has to pass
# both, or an administrator gets a share their editor rejects. Test-Json does not
# exist under Windows PowerShell 5.1, so this skips there rather than silently
# passing - the same arrangement the schema contracts use.
$script:HDTNewWorkspaceSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

Describe 'New-HDTWorkspace writes documents that validate against the schemas' -Skip:$script:HDTNewWorkspaceSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaRoot = Join-Path -Path $script:repoRoot -ChildPath 'schemas'
        $script:root = 'C:\HDTLab\does-not-exist\NewShare'

        $script:schemaFileSystem = New-HDTFakeFileSystem
        $null = New-HDTWorkspace -Path $script:root -Id 'HDT-LAB' -Name 'HDT lab deployment share' `
            -DeployRoot '\\HDT-HOST\HdtShare' -FileSystem $script:schemaFileSystem
    }

    It 'validates workspace.yaml against schemas/workspace.schema.json' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $script:schemaRoot -ChildPath 'workspace.schema.json') -Raw
        $yaml = $script:schemaFileSystem.ReadAllText((Join-Path -Path $script:root -ChildPath 'workspace.yaml'))
        $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

        Test-Json -Json $json -Schema $schema | Should -BeTrue
    }

    It 'validates rules.yaml against schemas/rules.schema.json' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $script:schemaRoot -ChildPath 'rules.schema.json') -Raw
        $yaml = $script:schemaFileSystem.ReadAllText((Join-Path -Path $script:root -ChildPath 'rules.yaml'))
        $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

        Test-Json -Json $json -Schema $schema | Should -BeTrue
    }
}

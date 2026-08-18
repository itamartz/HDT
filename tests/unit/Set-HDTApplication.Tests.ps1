# The other half of the application catalog: Import-HDTApplication registers an
# entry and refuses to replace one, and this changes an entry that exists.
#
# IT SPLICES, IT NEVER RE-SERIALISES. app.yaml is hand-edited from the day it is
# written - the samples are half commentary - and a parse-then-write round trip
# drops every comment in the file. So only the lines named are rewritten and
# everything else comes back byte-identical, which is the same rule
# Set-HDTWorkspaceProperty and Set-HDTStepProperty follow.
#
# THE ID IS NOT SETTABLE. It is the folder name, the key a sequence selects and
# the name a dependency refers to; changing it in the file alone would leave an
# entry whose id and folder disagree, and Get-HDTApplication enumerates by folder.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\app.yaml'

    # A real one: a comment header, a comment beside a key, a detection block and
    # a flow-style list. Everything this command must not damage.
    $script:original = @(
        '# 7-Zip, staged from the volume licence media on 2026-08-16.'
        '#'
        '# The payload lives in source\ next to this file.'
        'schemaVersion: 1'
        'id: 7Zip-24.09'
        'name: 7-Zip 24.09 x64'
        'install: msiexec.exe /i "7z2409-x64.msi" /qn /norestart'
        'successCodes: [0, 3010]'
        'rebootCodes: [3010]'
        'detect:'
        '  # Run the sequence twice and it installs once.'
        '  type: msiProduct'
        '  productCode: ''{23170F69-40C1-2702-2409-000001000000}'''
        'runIn: FullOS'
    ) -join [System.Environment]::NewLine
}

Describe 'Set-HDTApplication' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:catalogPath = $script:original
        }
    }

    Context 'splicing' {

        It 'changes the line it was asked to change' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name '7-Zip 24.09 (x64)' -FileSystem $script:fileSystem

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeLike '*name: 7-Zip 24.09 (x64)*'
        }

        It 'leaves every comment in the file' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name '7-Zip 24.09 (x64)' -FileSystem $script:fileSystem

            $text = $script:fileSystem.ReadAllText($script:catalogPath)

            $text | Should -BeLike '*# 7-Zip, staged from the volume licence media*'
            $text | Should -BeLike '*# The payload lives in source\ next to this file.*'
            $text | Should -BeLike '*# Run the sequence twice and it installs once.*'
        }

        It 'leaves every line it was not asked about byte-identical' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name '7-Zip 24.09 (x64)' -FileSystem $script:fileSystem

            $before = @($script:original -split "`r?`n")
            $after = @($script:fileSystem.ReadAllText($script:catalogPath) -split "`r?`n")

            $after.Count | Should -Be $before.Count

            for ($i = 0; $i -lt $before.Count; $i++) {
                if ($before[$i] -like 'name:*') { continue }
                $after[$i] | Should -BeExactly $before[$i]
            }
        }

        It 'changes the install command line' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart /log install.log' -FileSystem $script:fileSystem

            $catalog.Install | Should -BeExactly 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart /log install.log'
        }

        It 'changes more than one key in one call' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name 'Renamed' -RunIn Any -FileSystem $script:fileSystem

            $catalog.Name | Should -BeExactly 'Renamed'
            $catalog.RunIn | Should -BeExactly 'Any'
        }

        It 'adds a key the file does not carry yet' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Description 'Open-source file archiver' -FileSystem $script:fileSystem

            $catalog.Description | Should -BeExactly 'Open-source file archiver'
            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeLike '*description: Open-source file archiver*'
        }

        It 'removes a key when the value is empty' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -RunIn '' -FileSystem $script:fileSystem

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*runIn:*'
        }

        It 'writes the exit codes as a flow list' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -SuccessCode 0, 1641, 3010 -FileSystem $script:fileSystem

            # -Contain over the lines, not -BeLike over the text: '[' and ']' are
            # wildcard characters, and a flow list written into a -BeLike pattern
            # matches nothing.
            @($script:fileSystem.ReadAllText($script:catalogPath) -split "`r?`n") |
                Should -Contain 'successCodes: [0, 1641, 3010]'
            $catalog.SuccessCodes | Should -Be @(0, 1641, 3010)
        }

        It 'writes the dependencies as a flow list' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Dependency 'Corp-Root-Certificates', 'VCRedist-2015' -FileSystem $script:fileSystem

            @($script:fileSystem.ReadAllText($script:catalogPath) -split "`r?`n") |
                Should -Contain 'dependencies: [Corp-Root-Certificates, VCRedist-2015]'
            $catalog.Dependencies | Should -Be @('Corp-Root-Certificates', 'VCRedist-2015')
        }

        It 'removes a list when it is given none' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -SuccessCode @() -FileSystem $script:fileSystem

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*successCodes:*'
        }
    }

    Context 'who makes it and which version' {

        # THE TWO WORKBENCH ASKS FOR. Changing either changes what the row SAYS
        # and never what the entry is CALLED - the id is the folder name and
        # what every task sequence names, which is why there is no -Id here.

        It 'adds them to a document that never had them' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Publisher 'Igor Pavlov' -Version '24.09' -FileSystem $script:fileSystem

            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            [string] $read.Publisher | Should -BeExactly 'Igor Pavlov'
            [string] $read.Version | Should -BeExactly '24.09'
        }

        It 'leaves the comments where they were' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Publisher 'Igor Pavlov' -FileSystem $script:fileSystem

            $script:fileSystem.ReadAllText($script:catalogPath) |
                Should -BeLike '*# Run the sequence twice and it installs once.*'
        }

        It 'does not touch the id' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Publisher 'Somebody Else' -Version '99' -FileSystem $script:fileSystem

            (Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem).Id |
                Should -BeExactly '7Zip-24.09'
        }
    }

    Context 'the detection rule' {

        It 'replaces the whole block, not one key of it' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Detect @{ type = 'file'; path = '%ProgramFiles%\7-Zip\7z.exe'; version = '24.09' } `
                -FileSystem $script:fileSystem

            $catalog.Detect.Type | Should -BeExactly 'file'
            $catalog.Detect.Path | Should -BeExactly '%ProgramFiles%\7-Zip\7z.exe'
            $catalog.Detect.Version | Should -BeExactly '24.09'

            # The msiProduct key it used to carry is gone, not left orphaned under
            # a file rule the projector would ignore and the validator refuse.
            $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*productCode*'
        }

        It 'removes the block when given an empty rule, which is install every time' {
            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Detect @{ } -FileSystem $script:fileSystem

            $catalog.Detect | Should -BeNullOrEmpty
            $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*detect:*'
        }

        It 'adds a block to a file that has none' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:catalogPath = @(
                    'schemaVersion: 1'
                    'id: 7Zip-24.09'
                    'name: 7-Zip'
                    'install: setup.exe /S'
                ) -join [System.Environment]::NewLine
            }

            $catalog = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Detect @{ type = 'registry'; key = 'HKLM:\SOFTWARE\7-Zip'; value = 'Path' } `
                -FileSystem $fileSystem

            $catalog.Detect.Type | Should -BeExactly 'registry'
            $catalog.Detect.Key | Should -BeExactly 'HKLM:\SOFTWARE\7-Zip'
            $catalog.Detect.Value | Should -BeExactly 'Path'
        }
    }

    Context 'refusing' {

        It 'throws when the application is not in the workspace' {
            $record = $null
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Absent-App' `
                    -Name 'Whatever' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Absent-App*'
        }

        It 'offers no way to change the id' {
            @((Get-Command -Name Set-HDTApplication -ErrorAction Stop).Parameters.Keys) |
                Should -Not -Contain 'NewId'
        }

        It 'refuses a call that changes nothing' {
            $record = $null
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'refuses to clear the install command, which would leave an entry with no purpose' {
            $record = $null
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install '' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'refuses a phase that is not one HDT runs a step in' {
            $record = $null
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -RunIn 'Sometime' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Sometime*'
        }

        It 'holds the spliced document to the validator before writing' {
            $record = $null
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Detect @{ type = 'vibes' } -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'leaves the file exactly as it was when the document is refused' {
            try {
                Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Detect @{ type = 'vibes' } -FileSystem $script:fileSystem
            } catch { $null = $_ }

            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeExactly $script:original
        }
    }

    Context 'the shape of the command' {

        It 'returns the catalog in the shape Get-HDTApplication returns' {
            $written = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name 'Renamed' -FileSystem $script:fileSystem

            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $written.Name | Should -BeExactly $read.Name
            $written.Install | Should -BeExactly $read.Install
            $written.SourcePath | Should -BeExactly $read.SourcePath
            $written.Detect.ProductCode | Should -BeExactly $read.Detect.ProductCode
        }

        It 'writes through the injected filesystem' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name 'Renamed' -FileSystem $script:fileSystem

            $script:fileSystem.GetOperationName() | Should -Contain 'WriteAllText'
        }

        It 'builds its path with Get-HDTWorkspacePath' {
            $unc = '\\contoso\HdtShare'
            $expected = Get-HDTWorkspacePath -Root $unc -Kind Applications -ChildPath '7Zip-24.09', 'app.yaml'
            $fileSystem = New-HDTFakeFileSystem -File @{ $expected = $script:original }

            $null = Set-HDTApplication -WorkspaceRoot $unc -Id '7Zip-24.09' -Name 'Renamed' -FileSystem $fileSystem

            $fileSystem.ReadAllText($expected) | Should -BeLike '*name: Renamed*'
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name Set-HDTApplication -ErrorAction Stop).Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'supports -WhatIf and writes nothing' {
            $null = Set-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Name 'Renamed' -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
            $script:fileSystem.ReadAllText($script:catalogPath) | Should -BeExactly $script:original
        }

        It 'defaults -FileSystem to the real adapter' {
            $default = (Get-Command -Name Set-HDTApplication -ErrorAction Stop).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'FileSystem' }

            $default.DefaultValue.Extent.Text | Should -BeLike '*New-HDTFileSystem*'
        }
    }
}

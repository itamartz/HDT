# DESIGN 8: an application is a folder under Applications\ holding app.yaml and a
# source\ payload. DESIGN 2.1 fixes where it lands. Import-HDTApplication is the
# only writer of that document, and it is the twin of Import-HDTOperatingSystem -
# same verb, same injected filesystem, same "validate before you write" order.
#
# THE PAYLOAD IS MANDATORY, WHICH IS WHERE THIS PARTS COMPANY WITH THE OS
# IMPORTER. An operating system is registered where it stands because copying 4 GB
# is a real operation; an application is a folder of installer files, and a
# catalog entry whose source\ is empty is an entry the InstallApplications step
# cannot run. So -SourcePath is required and the contents of that folder land in
# Applications\<id>\source - an entry that exists is an entry that can install.
#
# THE DEFAULTS ARE NOT WRITTEN INTO THE FILE. successCodes, rebootCodes, runIn,
# detect and dependencies all have defaults, and they live in exactly one place -
# ConvertTo-HDTApplicationCatalog. An importer that stamped 0/3010 into every
# app.yaml would make the file disagree with the projector the day either
# changes, so the keys the caller did not ask for do not appear on disk at all.
#
# Every path is built with Get-HDTWorkspacePath, for the reason that command
# exists: a literal 'Applications' concatenated by hand is a bug nothing in the
# unit suite would catch until a deployment read the wrong folder.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\app.yaml'
    $script:install = 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart'
    $script:payload = 'C:\payload\7Zip'
}

Describe 'Import-HDTApplication' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            'C:\payload\7Zip\7z2409-x64.msi'      = 'MSI'
            'C:\payload\7Zip\install.cmd'         = 'CMD'
            'C:\payload\7Zip\lang\en-us.mst'      = 'MST'
        }
    }

    Context 'writing the catalog' {

        # The name carries no angle brackets: Pester expands <name> in an It title
        # as a data variable, which is how 'Applications\<id>' once failed with
        # "the variable $id has not been set".
        It 'writes app.yaml under the Applications folder for the id' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeTrue
        }

        It 'builds that path with Get-HDTWorkspacePath' {
            # A UNC root, so a literal 'Applications' concatenated by hand would
            # produce a visibly different path.
            $unc = '\\contoso\HdtShare'
            $expected = Get-HDTWorkspacePath -Root $unc -Kind Applications -ChildPath '7Zip-24.09', 'app.yaml'

            $null = Import-HDTApplication -WorkspaceRoot $unc -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:fileSystem.TestPath($expected) | Should -BeTrue
        }

        It 'writes through the injected filesystem' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:fileSystem.GetOperationName() | Should -Contain 'WriteAllText'
            Test-Path -LiteralPath $script:catalogPath | Should -BeFalse
        }

        It 'records the schema version' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $catalog.SchemaVersion | Should -Be 1
        }

        It 'defaults the name to the id' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $catalog.Name | Should -BeExactly '7Zip-24.09'
        }

        It 'keeps an explicit name and description' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Name '7-Zip 24.09 x64' -Description 'Open-source file archiver'

            $catalog.Name | Should -BeExactly '7-Zip 24.09 x64'
            $catalog.Description | Should -BeExactly 'Open-source file archiver'
        }

        It 'records the install command line' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $catalog.Install | Should -BeExactly $script:install
        }

        It 'refuses an id that is not a legal folder name' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '../escape' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'writes a document Assert-HDTApplicationDocument accepts' {
            # The round trip that keeps the writer and the validator honest.
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Uninstall 'msiexec.exe /x "{23170F69}" /qn' -SuccessCode 0, 1641, 3010 `
                -RebootCode 1641, 3010 -RunIn FullOS -Dependency 'Corp-Root-Certificates' `
                -Detect @{ type = 'msiProduct'; productCode = '{23170F69}' }

            $yaml = $script:fileSystem.ReadAllText($script:catalogPath)

            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTApplicationDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'writes a document Get-HDTApplication reads back' {
            $written = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -Name '7-Zip 24.09 x64'

            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $read.Id | Should -BeExactly $written.Id
            $read.Name | Should -BeExactly $written.Name
            $read.Install | Should -BeExactly $written.Install
            $read.RunIn | Should -BeExactly $written.RunIn
            $read.SourcePath | Should -BeExactly $written.SourcePath
        }
    }

    Context 'the keys nobody asked for' {

        BeforeEach {
            $script:catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:yaml = $script:fileSystem.ReadAllText($script:catalogPath)
        }

        It 'omits every optional key from the file' {
            foreach ($key in @('uninstall', 'successCodes', 'rebootCodes', 'detect', 'dependencies', 'description')) {
                $script:yaml | Should -Not -BeLike ("*{0}:*" -f $key)
            }
        }

        It 'leaves the exit code defaults to the projector' {
            $script:catalog.SuccessCodes | Should -Be @(0, 3010)
            $script:catalog.RebootCodes | Should -Be @(3010)
        }

        It 'leaves runIn to the projector' {
            $script:catalog.RunIn | Should -BeExactly 'FullOS'
        }

        It 'projects no detection rule, which is install every time' {
            $script:catalog.Detect | Should -BeNullOrEmpty
        }

        It 'projects no dependencies' {
            $script:catalog.Dependencies.Count | Should -Be 0
        }
    }

    Context 'the keys somebody did ask for' {

        It 'writes the exit codes as integers' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -SuccessCode 0, 1641, 3010 -RebootCode 1641, 3010

            $catalog.SuccessCodes | Should -Be @(0, 1641, 3010)
            $catalog.RebootCodes | Should -Be @(1641, 3010)
        }

        It 'writes the uninstall command line' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Uninstall 'msiexec.exe /x "{23170F69}" /qn'

            $catalog.Uninstall | Should -BeExactly 'msiexec.exe /x "{23170F69}" /qn'
        }

        It 'writes the phase' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -RunIn Any

            $catalog.RunIn | Should -BeExactly 'Any'
        }

        It 'refuses a phase that is not one HDT runs a step in' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -RunIn 'Sometime'
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Sometime*'
        }

        It 'writes the dependencies in the order given' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' `
                -Install 'powershell.exe -File "Apply-Baseline.ps1"' -SourcePath $script:payload `
                -FileSystem $script:fileSystem -Dependency '7Zip-24.09', 'Corp-Root-Certificates'

            $catalog.Dependencies | Should -Be @('7Zip-24.09', 'Corp-Root-Certificates')
        }

        It 'writes an msiProduct detection rule' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Detect @{ type = 'msiProduct'; productCode = '{23170F69-40C1-2702-2409-000001000000}' }

            $catalog.Detect.Type | Should -BeExactly 'msiProduct'
            $catalog.Detect.ProductCode | Should -BeExactly '{23170F69-40C1-2702-2409-000001000000}'
        }

        It 'writes a registry detection rule with its optional keys' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Detect @{ type = 'registry'; key = 'HKLM:\SOFTWARE\7-Zip'; value = 'Path'; data = 'C:\Program Files\7-Zip' }

            $catalog.Detect.Type | Should -BeExactly 'registry'
            $catalog.Detect.Key | Should -BeExactly 'HKLM:\SOFTWARE\7-Zip'
            $catalog.Detect.Value | Should -BeExactly 'Path'
            $catalog.Detect.Data | Should -BeExactly 'C:\Program Files\7-Zip'
        }

        It 'refuses a detection rule the validator does not recognise, naming the file' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                    -Detect @{ type = 'vibes' }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*app.yaml*'
        }

        It 'refuses a detection rule with no type' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                    -Detect @{ productCode = '{23170F69}' }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'writes nothing when the document is refused' {
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                    -Detect @{ type = 'vibes' }
            } catch { $null = $_ }

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeFalse
        }

        It 'copies nothing when the document is refused' {
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                    -Detect @{ type = 'vibes' }
            } catch { $null = $_ }

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'CopyItem'
        }
    }

    Context 'the shape of the command' {

        # An administrator types this command; the engine's hot path does not
        # call it. New-HDTWorkspace states the convention this follows - the
        # authoring commands default their filesystem so that a working call is a
        # short one, and only the hot path takes it mandatory. The default is
        # read off the AST rather than invoked: running it would build a real
        # filesystem service, and a test that writes a catalog onto a real disk
        # is the one thing this file must never do.
        It 'does not make -FileSystem mandatory' {
            $parameter = (Get-Command -Name Import-HDTApplication -ErrorAction Stop).Parameters['FileSystem']

            @($parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
        }

        It 'defaults -FileSystem to the real adapter' {
            $default = (Get-Command -Name Import-HDTApplication -ErrorAction Stop).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'FileSystem' }

            $default.DefaultValue.Extent.Text | Should -BeLike '*New-HDTFileSystem*'
        }

        # The payload is not an optional extra. A catalog entry whose source\ is
        # empty is one the InstallApplications step cannot run, and it fails at
        # deployment time rather than at authoring time - which is the worst place
        # to find out.
        It 'makes -SourcePath mandatory' {
            $parameter = (Get-Command -Name Import-HDTApplication -ErrorAction Stop).Parameters['SourcePath']

            @($parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object { $_.Mandatory }) | Should -Contain $true
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name Import-HDTApplication -ErrorAction Stop).Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'the payload' {

        It 'copies the source tree into the application source folder' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\source\7z2409-x64.msi') | Should -BeTrue
            $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\source\lang\en-us.mst') | Should -BeTrue
        }

        # The folder name under the share comes from the id, never from the leaf
        # of the source path, and it is the CONTENTS that are copied - a payload
        # nested one folder deeper would break every relative install command.
        It 'does not reproduce the source folder name under source' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\source\7Zip') | Should -BeFalse
        }

        It 'throws when the source tree does not exist' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath 'C:\payload\absent' -FileSystem $script:fileSystem
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*absent*'
        }

        It 'writes no catalog when the source tree does not exist' {
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath 'C:\payload\absent' -FileSystem $script:fileSystem
            } catch { $null = $_ }

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeFalse
        }

        It 'reports the payload folder as the convention, whatever was copied in' {
            $catalog = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $catalog.SourcePath | Should -BeExactly 'C:\HDTLab\does-not-exist\Share\Applications\7Zip-24.09\source'
        }
    }

    # IMPORT REGISTERS; IT DOES NOT REPLACE. There is no -Force, on the same
    # reasoning Add-HDTStep and Set-HDTStepProperty split the sequence editor in
    # two: an importer that overwrote on a flag is one keystroke away from
    # replacing a working catalog entry - and its payload - with a typo. Changing
    # one is the setter's job.
    Context 'importing over an existing entry' {

        BeforeEach {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -Name 'First'
        }

        It 'refuses, naming the id' {
            $record = $null
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -Name 'Second'
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*7Zip-24.09*'
        }

        It 'offers no -Force to override the refusal' {
            (Get-Command -Name Import-HDTApplication -ErrorAction Stop).Parameters.Keys | Should -Not -Contain 'Force'
        }

        It 'leaves the existing entry exactly as it was' {
            try {
                Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                    -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -Name 'Second'
            } catch { $null = $_ }

            (Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem).Name |
                Should -BeExactly 'First'
        }
    }

    Context 'who makes it and which version' {

        # WORKBENCH ASKS FOR BOTH, and they are what tell two entries called
        # Reader apart. Neither is required - a package with no version stated
        # is still a package - and neither changes the id, which is the folder
        # name and what every task sequence names.

        It 'writes them when they are given' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem `
                -Publisher 'Igor Pavlov' -Version '24.09'

            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            [string] $read.Publisher | Should -BeExactly 'Igor Pavlov'
            [string] $read.Version | Should -BeExactly '24.09'
        }

        It 'leaves the keys out entirely when they are not' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem

            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            [string] $read.Publisher | Should -BeExactly ''
            [string] $script:fileSystem.ReadAllText($script:catalogPath) | Should -Not -BeLike '*publisher*'
        }
    }

    Context 'not writing at all' {

        It 'supports -WhatIf and writes nothing' {
            $null = Import-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -Install $script:install -SourcePath $script:payload -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.TestPath($script:catalogPath) | Should -BeFalse
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'CopyItem'
        }
    }
}

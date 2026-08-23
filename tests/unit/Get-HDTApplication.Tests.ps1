# Get-HDTApplication reads the application catalog out of the workspace.
#
# THE CATALOG IS THE DIRECTORY. DESIGN 2.1 gives every application a folder under
# Applications\ holding its app.yaml and its source\ payload, so there is no
# single catalog file to parse and no single file two administrators collide in.
# Reading one application is a read of one app.yaml; reading the catalog is an
# enumeration of that folder.
#
# EVERY DEFAULT LIVES HERE, NOT IN THE FILE. successCodes, rebootCodes and runIn
# are optional in app.yaml (DESIGN 8), so valid-no-detect.yaml declares none of
# them and this file is what pins down what an author gets when they leave them
# out. A default that drifts silently turns 3010 from "installed, reboot needed"
# into a failed deployment.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:appFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/apps'
    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:appRoot = 'C:\HDTLab\does-not-exist\Share\Applications'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:appFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    $script:sevenZipPath = Join-Path -Path $script:appRoot -ChildPath '7Zip-24.09\app.yaml'
    $script:baselinePath = Join-Path -Path $script:appRoot -ChildPath 'Corp-Baseline\app.yaml'
}

Describe 'Get-HDTApplication' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:sevenZipPath = $script:fixture['valid-7zip.yaml']
            $script:baselinePath = $script:fixture['valid-no-detect.yaml']
        }
    }

    Context 'reading one application' {

        It 'returns the catalog entry for an id' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $app.Id | Should -BeExactly '7Zip-24.09'
            $app.Name | Should -BeExactly '7-Zip 24.09 x64'
            $app.Install | Should -BeExactly 'msiexec.exe /i "7z2409-x64.msi" /qn'
            $app.Uninstall | Should -BeExactly 'msiexec.exe /x "{23170F69-40C1-2702-2409-000001000000}" /qn'
        }

        It 'reads through the injected filesystem' {
            $null = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $script:fileSystem.GetOperationName() | Should -Contain 'ReadAllText'
            Test-Path -LiteralPath $script:sevenZipPath | Should -BeFalse
        }

        It 'projects the declared exit codes' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            @($app.SuccessCodes) | Should -Be @(0, 3010)
            @($app.RebootCodes) | Should -Be @(3010)
        }

        It 'projects the detection rule' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $app.Detect.Type | Should -BeExactly 'msiProduct'
            $app.Detect.ProductCode | Should -BeExactly '{23170F69-40C1-2702-2409-000001000000}'
        }

        It 'projects the dependencies' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            @($app.Dependencies) | Should -Be @('VCRedist-2015-2022')
        }
    }

    Context 'the defaults, for an application that declares none of them' {

        It 'defaults successCodes to 0 and 3010' {
            # 3010 is "installed, reboot required". An engine that treated it as a
            # failure would scrap a build over a successful install.
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            @($app.SuccessCodes) | Should -Be @(0, 3010)
        }

        It 'defaults rebootCodes to 3010' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            @($app.RebootCodes) | Should -Be @(3010)
        }

        It 'defaults runIn to FullOS' {
            # DESIGN 8's own example says runIn: FullOS, and an application
            # installer that runs in WinPE is the unusual case, not the default.
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            $app.RunIn | Should -BeExactly 'FullOS'
        }

        It 'projects no detection rule as $null rather than inventing one' {
            # DESIGN 8: the engine never infers a rule for an app that declined to
            # declare one. $null is how the step learns "install unconditionally".
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            $app.Detect | Should -BeNullOrEmpty
        }

        It 'projects no dependencies as an empty list' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            @($app.Dependencies).Count | Should -Be 0
        }

        It 'projects an absent uninstall as an empty string' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Corp-Baseline' -FileSystem $script:fileSystem

            $app.Uninstall | Should -BeExactly ''
        }
    }

    Context 'the source folder' {

        It 'resolves SourcePath under the application folder with no provider' {
            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' -FileSystem $script:fileSystem

            $app.SourcePath | Should -BeExactly (Join-Path -Path $script:appRoot -ChildPath '7Zip-24.09\source')
        }

        It 'resolves SourcePath through the content provider when one is supplied' {
            # The same seam ApplyImage closed in 05-02: the caller hands over a
            # provider and the catalog stops building paths itself.
            $content = New-HDTFakeContentProvider -Root $script:workspaceRoot

            $app = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -FileSystem $script:fileSystem -Content $content

            @($content.GetOperationName()) | Should -Be @('ResolveContent')
            $app.SourcePath | Should -Not -BeNullOrEmpty
        }

        It 'resolves SourcePath onto the mapped drive over SMB' {
            # THIS IS THE PATH THE INSTALL STEP MAKES A WORKING DIRECTORY.
            # Invoke-HDTInstallApplicationsStep runs every install command
            # through %ComSpec% /c with SourcePath as the current directory, and
            # CMD.EXE REFUSES A UNC ONE - it prints "UNC paths are not
            # supported", moves itself to %SystemRoot% and the vendor's own
            # 'msiexec /i setup.msi' then runs in C:\Windows. A share connected
            # without a letter cannot be a working directory at all, which is
            # why the Smb provider maps one the way MDT did.
            $unc = '\\hdtserver\HdtShare'

            $fileSystem = New-HDTFakeFileSystem -File @{
                ('{0}\Applications\7Zip-24.09\app.yaml' -f $unc) = $script:fixture['valid-7zip.yaml']
            }

            $smb = New-HDTFakeSmbService -Connection @([pscustomobject] @{
                    ServerName = 'hdtserver'; ShareName = 'HdtShare'
                    UserName = 'CONTOSO\svc-hdt-deploy'; Dialect = '3.1.1'
                    Encrypted = $true; Signed = $true
                })

            $content = New-HDTSmbContentProvider -Root $unc -AllowAnonymous `
                -SmbService $smb -FileSystem $fileSystem
            $content.Connect() | Out-Null

            $app = Get-HDTApplication -WorkspaceRoot $unc -Id '7Zip-24.09' `
                -FileSystem $fileSystem -Content $content

            $app.SourcePath | Should -BeExactly 'Z:\Applications\7Zip-24.09\source'
        }

        It 'asks the provider for the path relative to the provider root' {
            $content = New-HDTFakeContentProvider -Root $script:workspaceRoot

            $null = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -FileSystem $script:fileSystem -Content $content

            @($content.Operations)[0].Arguments[0] |
                Should -BeExactly (Join-Path -Path 'Applications' -ChildPath '7Zip-24.09\source')
        }
    }

    Context 'enumerating the catalog' {

        It 'returns every application when no id is given, ordered by id' {
            $app = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)

            @($app | ForEach-Object { $_.Id }) | Should -Be @('7Zip-24.09', 'Corp-Baseline')
        }

        It 'skips a folder that holds no app.yaml' {
            # A stray folder in the share is not an application, and a console that
            # threw over one would be unusable on a share people actually use.
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:sevenZipPath = $script:fixture['valid-7zip.yaml']
                (Join-Path -Path $script:appRoot -ChildPath 'Notes\readme.txt') = 'not an application'
            }

            $app = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem)

            @($app | ForEach-Object { $_.Id }) | Should -Be @('7Zip-24.09')
        }

        It 'returns nothing for a workspace with no Applications folder' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                (Join-Path -Path $script:workspaceRoot -ChildPath 'workspace.yaml') = 'schemaVersion: 1'
            }

            @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem).Count | Should -Be 0
        }

        It 'fails naming the file when one application is invalid' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:sevenZipPath = $script:fixture['valid-7zip.yaml']
                (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Agent\app.yaml') = $script:fixture['invalid-missing-install.yaml']
            }

            $record = $null
            try {
                $null = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $fileSystem)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.TargetObject | Should -BeLike '*Contoso-Agent\app.yaml'
        }
    }

    Context 'what it refuses' {

        It 'names the id and the folder when the application is not in the workspace' {
            $record = $null
            try {
                $null = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Not-Here' -FileSystem $script:fileSystem
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Not-Here*'
            $record.CategoryInfo.Category | Should -Be 'ObjectNotFound'
        }

        It 'surfaces a validation failure naming the file' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                (Join-Path -Path $script:appRoot -ChildPath 'Contoso-Agent\app.yaml') = $script:fixture['invalid-detect-unknown-type.yaml']
            }

            { Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id 'Contoso-Agent' -FileSystem $fileSystem } |
                Should -Throw -ExpectedMessage '*wmi*'
        }
    }

    Context 'the shape of the command' {

        # THE ONLY ONE OF THE FIVE THAT REFUSED A PLAIN CALL. Import, Set and
        # Remove all default the adapter; this one demanded it, so
        # 'Get-HDTApplication -WorkspaceRoot C:\HDTLab\Share' - the first thing
        # anybody types - was an error about a parameter no administrator has.
        It 'does not make -FileSystem mandatory' {
            $parameter = (Get-Command -Name 'Get-HDTApplication').Parameters['FileSystem']
            @($parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
        }

        It 'defaults -FileSystem to the real adapter' {
            $default = (Get-Command -Name 'Get-HDTApplication').ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'FileSystem' }

            [string] $default.DefaultValue.Extent.Text | Should -BeExactly '(New-HDTFileSystem)'
        }

        It 'takes <Name> from the pipeline by property name' -ForEach @(
            @{ Name = 'WorkspaceRoot' }
            @{ Name = 'Id' }
        ) {
            $parameter = (Get-Command -Name 'Get-HDTApplication').Parameters[$Name]
            @($parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object { $_.ValueFromPipelineByPropertyName }) | Should -Contain $true
        }
    }

    Context 'what it hands the next command' {

        It 'carries the workspace it was read from' {
            $read = Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -Id '7Zip-24.09' `
                -FileSystem $script:fileSystem

            [string] $read.WorkspaceRoot | Should -BeExactly $script:workspaceRoot
        }

        It 'carries it on every entry of the whole catalog too' {
            $all = @(Get-HDTApplication -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem)

            $all.Count | Should -BeGreaterThan 1
            @($all | ForEach-Object { [string] $_.WorkspaceRoot }) |
                Should -Not -Contain ''
        }
    }
}

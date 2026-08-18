# DELETING AN APPLICATION, which Deployment Workbench does from the right-click
# menu and HDT could not do at all - an application imported by mistake had to
# be removed with Explorer, which is how somebody deletes the wrong folder.
#
# IT IS A FOLDER DELETE, AND THAT IS WHY THE GUARDS ARE WHAT THEY ARE. The id
# names a folder under Applications\; an id that is a path, or that resolves
# outside the share, is refused rather than resolved. CLAUDE.md's delete rules
# are not advisory in a command whose whole job is Remove-Item.
#
# TWO THINGS CAN BE USING IT, and they fail differently. A task sequence that
# names it in an InstallApplications selection fails at that step, late, on the
# machine in front of somebody. Another APPLICATION that names it as a
# dependency is worse: Resolve-HDTApplicationOrder refuses the whole plan, so
# removing one application can stop an unrelated one from installing at all.
# Both are reported, and neither is a refusal - an administrator replacing a
# package knows more than this command does.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:appYaml = @'
schemaVersion: 1
id: 7Zip-24.09
name: 7-Zip 24.09 x64
install: msiexec.exe /i "7z2409-x64.msi" /qn /norestart
'@

    $script:dependentYaml = @'
schemaVersion: 1
id: Contoso-Suite
name: Contoso Suite
install: setup.exe /quiet
dependencies:
  - 7Zip-24.09
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - name: Install Applications
    type: InstallApplications
    selection: [7Zip-24.09, Contoso-Suite]
'@

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                            = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            'C:\ws\Applications\7Zip-24.09\app.yaml'          = $script:appYaml
            'C:\ws\Applications\7Zip-24.09\source\7z.msi'     = 'not really an msi'
            'C:\ws\Applications\Contoso-Suite\app.yaml'       = $script:dependentYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'       = $script:sequenceYaml
        }
    }
}

Describe 'Remove-HDTApplication' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTApplication' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it deletes a folder' {
            (Get-Command -Name 'Remove-HDTApplication').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'asks first unless it is told not to' {
            $attribute = (Get-Command -Name 'Remove-HDTApplication').ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

            [string] $attribute.ConfirmImpact | Should -BeExactly 'High'
        }
    }

    Context 'what it removes' {

        It 'removes the folder the id names, and its payload with it' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -Confirm:$false

            [string] $result.Id | Should -BeExactly '7Zip-24.09'
            $fileSystem.TestPath('C:\ws\Applications\7Zip-24.09\app.yaml') | Should -BeFalse
            $fileSystem.TestPath('C:\ws\Applications\7Zip-24.09\source\7z.msi') | Should -BeFalse
        }

        It 'leaves everything else on the share alone' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -Confirm:$false)

            $fileSystem.TestPath('C:\ws\workspace.yaml') | Should -BeTrue
            $fileSystem.TestPath('C:\ws\Applications\Contoso-Suite\app.yaml') | Should -BeTrue
            $fileSystem.TestPath('C:\ws\TaskSequences\DEMO-M4\sequence.yaml') | Should -BeTrue
        }

        It 'removes nothing under -WhatIf' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -WhatIf)

            $fileSystem.TestPath('C:\ws\Applications\7Zip-24.09\app.yaml') | Should -BeTrue
        }
    }

    Context 'what it refuses' {

        It 'refuses an id that is a path rather than a folder name: <_>' -ForEach @(
            '..', '.', '7Zip\..\..\Windows', 'C:\Windows', '7 Zip') {

            $fileSystem = & $script:newFileSystem

            { Remove-HDTApplication -Workspace 'C:\ws' -Id $_ -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw

            $fileSystem.TestPath('C:\ws\Applications\7Zip-24.09\app.yaml') | Should -BeTrue
        }

        It 'refuses an id this share has not got, naming it' {
            $fileSystem = & $script:newFileSystem
            $message = ''

            try { Remove-HDTApplication -Workspace 'C:\ws' -Id 'Notepad-Plus' -FileSystem $fileSystem -Confirm:$false }
            catch { $message = [string] $_.Exception.Message }

            $message | Should -BeLike '*Notepad-Plus*'
        }

        It 'refuses a folder that holds no app.yaml, rather than deleting it' {
            # A folder under Applications\ that is not a catalog entry is
            # somebody's staging directory, and this command must not be the
            # thing that removes it.
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                 = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\Applications\Staging\notes.txt' = 'mine'
            }

            { Remove-HDTApplication -Workspace 'C:\ws' -Id 'Staging' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw

            $fileSystem.TestPath('C:\ws\Applications\Staging\notes.txt') | Should -BeTrue
        }
    }

    Context 'what was using it' {

        It 'reports which task sequences name it in a selection' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -Confirm:$false

            @($result.UsedBy) | Should -Be @('DEMO-M4')
        }

        It 'reports which applications depend on it' {
            # THE WORSE OF THE TWO. A missing dependency stops the whole plan,
            # so removing this application would stop Contoso Suite installing.
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -Confirm:$false

            @($result.RequiredBy) | Should -Be @('Contoso-Suite')
        }

        It 'reports none when nothing refers to it' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                   = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\Applications\7Zip-24.09\app.yaml' = $script:appYaml
            }

            $result = Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -Confirm:$false

            @($result.UsedBy) | Should -BeNullOrEmpty
            @($result.RequiredBy) | Should -BeNullOrEmpty
        }

        It 'answers without removing anything under -WhatIf, so a dialog can ask first' {
            # The console asks in its own dialog, and it has to be able to name
            # what is using it BEFORE anybody agrees to anything.
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -FileSystem $fileSystem -WhatIf

            @($result.UsedBy) | Should -Be @('DEMO-M4')
            $fileSystem.TestPath('C:\ws\Applications\7Zip-24.09\app.yaml') | Should -BeTrue
        }
    }
}

# DELETING AN IMPORTED OPERATING SYSTEM, which Deployment Workbench does from
# the right-click menu and HDT could not do at all - an OS imported by mistake
# had to be removed with Explorer.
#
# IT IS A FOLDER DELETE, AND THAT IS WHY THE GUARDS ARE WHAT THEY ARE. The id
# names a folder under OperatingSystems\; an id that is a path, or that resolves
# outside the share, is refused rather than resolved. CLAUDE.md's delete rules
# are not advisory here - this is a command whose whole job is Remove-Item.
#
# A TASK SEQUENCE MAY BE USING IT. Removing the media a sequence applies leaves
# a sequence that fails at Apply Operating System, minutes into a deployment,
# on the machine in front of somebody. So the sequences are read first and the
# ones that name it are reported.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:osYaml = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    version: 10.0.26100.1
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - name: Apply OS
    type: ApplyImage
    operatingSystem: Win11-LTSC-2024
'@

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                                    = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml'          = $script:osYaml
            'C:\ws\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'not really a wim'
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'               = $script:sequenceYaml
        }
    }
}

Describe 'Remove-HDTOperatingSystem' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTOperatingSystem' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it deletes a folder' {
            (Get-Command -Name 'Remove-HDTOperatingSystem').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'asks first unless it is told not to' {
            $attribute = (Get-Command -Name 'Remove-HDTOperatingSystem').ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

            [string] $attribute.ConfirmImpact | Should -BeExactly 'High'
        }
    }

    Context 'what it removes' {

        It 'removes the folder the id names' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem -Confirm:$false

            [string] $result.Id | Should -BeExactly 'Win11-LTSC-2024'
            $fileSystem.TestPath('C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml') | Should -BeFalse
        }

        It 'leaves everything else on the share alone' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem -Confirm:$false)

            $fileSystem.TestPath('C:\ws\workspace.yaml') | Should -BeTrue
            $fileSystem.TestPath('C:\ws\TaskSequences\DEMO-M4\sequence.yaml') | Should -BeTrue
        }

        It 'removes nothing under -WhatIf' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem -WhatIf)

            $fileSystem.TestPath('C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml') | Should -BeTrue
        }
    }

    Context 'what it refuses' {

        It 'refuses an id that is a path rather than a folder name: <_>' -ForEach @(
            '..', '.', 'Win11\..\..\Windows', 'C:\Windows', 'Win 11') {

            $fileSystem = & $script:newFileSystem

            { Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id $_ -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw

            $fileSystem.TestPath('C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml') | Should -BeTrue
        }

        It 'refuses an id this share has not got, naming it' {
            $fileSystem = & $script:newFileSystem
            $message = ''

            try { Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'WS2025-Std' -FileSystem $fileSystem -Confirm:$false }
            catch { $message = [string] $_.Exception.Message }

            $message | Should -BeLike '*WS2025-Std*'
        }

        It 'refuses a folder that holds no os.yaml, rather than deleting it' {
            # A folder under OperatingSystems\ that is not a catalog entry is
            # somebody's staging directory, and this command must not be the
            # thing that removes it.
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                     = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\OperatingSystems\Staging\notes.txt' = 'mine'
            }

            { Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Staging' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw

            $fileSystem.TestPath('C:\ws\OperatingSystems\Staging\notes.txt') | Should -BeTrue
        }
    }

    Context 'the sequences that were using it' {

        It 'reports which task sequences name it' {
            # NOT A REFUSAL: an administrator removing media they have replaced
            # knows more than this command does. But the deployment that would
            # have failed minutes in is worth naming before it does.
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem -Confirm:$false

            @($result.UsedBy) | Should -Be @('DEMO-M4')
        }

        It 'reports none when nothing refers to it' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                           = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = $script:osYaml
            }

            $result = Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' -FileSystem $fileSystem -Confirm:$false

            @($result.UsedBy) | Should -BeNullOrEmpty
        }
    }
}

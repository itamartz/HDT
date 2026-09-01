# DELETING AN IMPORTED WINDOWS UPDATE, which MDT does from the right-click menu
# of its Packages node and HDT could not do at all - an update imported against
# the wrong release had to be removed with Explorer.
#
# IT IS A FOLDER DELETE, AND THAT IS WHY THE GUARDS ARE WHAT THEY ARE. This is
# Remove-HDTOperatingSystem's twin down to the two checks on the id: once as
# typed, once as resolved, because what matters is where it ended up rather than
# how it looked. CLAUDE.md's delete rules are not advisory for a command whose
# whole job is Remove-Item.
#
# AND THE DOCUMENT GOES WITH THE PACKAGE. update.yaml names the .msu beside it by
# file name, so removing one without the other leaves a catalog entry pointing at
# a file that is gone - and the ApplyUpdates step would find that out offline,
# inside an applied image, minutes into a deployment. The folder is the unit.
#
# WHAT USES IT IS REPORTED AND NOT ENFORCED. An ApplyUpdates step names a
# RELEASE, never an update id, so nothing points at this folder by name and
# removing it breaks no sequence - the machine simply arrives without this
# update. That is the honest sentence, and it is not the one an operating system
# gets.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # A REAL SHAPE, from what Import-HDTWindowsUpdate writes.
    $script:updateYaml = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: 2026-06 Cumulative Update for Windows 11 24H2
release: Win11-24H2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64_1b7f.msu
sizeBytes: 812345678
'@

    $script:otherYaml = @'
schemaVersion: 1
id: KB5094125-x64
kb: KB5094125
name: 2026-06 Cumulative Update for Windows Server 2025
release: WS2025
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094125-x64_9ac3.msu
'@

    # THE STEP NAMES A RELEASE, NOT AN ID. That is the whole reason UsedBy reads
    # the way it does.
    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - name: Apply Updates
    type: ApplyUpdates
    release: Win11-24H2
'@

    $script:everythingYaml = @'
schemaVersion: 1
id: DEMO-ALL
name: Deploy everything imported
steps:
  - name: Apply Updates
    type: ApplyUpdates
    release: ''
'@

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                                                        = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            'C:\ws\WindowsUpdates\KB5094126-x64\update.yaml'                              = $script:updateYaml
            'C:\ws\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64_1b7f.msu'       = 'not really a msu'
            'C:\ws\WindowsUpdates\KB5094125-x64\update.yaml'                              = $script:otherYaml
            'C:\ws\WindowsUpdates\KB5094125-x64\windows11.0-kb5094125-x64_9ac3.msu'       = 'not really a msu either'
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'                                   = $script:sequenceYaml
        }
    }
}

Describe 'Remove-HDTWindowsUpdate' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTWindowsUpdate' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it deletes a folder' {
            (Get-Command -Name 'Remove-HDTWindowsUpdate').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'asks first unless it is told not to' {
            $attribute = (Get-Command -Name 'Remove-HDTWindowsUpdate').ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

            [string] $attribute.ConfirmImpact | Should -BeExactly 'High'
        }
    }

    Context 'what it removes' {

        It 'removes the folder the id names' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                -FileSystem $fileSystem -Confirm:$false

            $result.Id | Should -BeExactly 'KB5094126-x64'
            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094126-x64') | Should -BeFalse
        }

        # THE DOCUMENT AND THE PACKAGE GO TOGETHER OR NEITHER GOES. A catalog
        # entry naming a .msu that is gone is the failure mode this command must
        # not create, and it is only ever discovered offline inside an image.
        It 'takes update.yaml and the .msu with it, so nothing names a file that is gone' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                    -FileSystem $fileSystem -Confirm:$false)

            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094126-x64\update.yaml') | Should -BeFalse
            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64_1b7f.msu') |
                Should -BeFalse
        }

        It 'leaves every other update alone' {
            $fileSystem = & $script:newFileSystem

            [void] (Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                    -FileSystem $fileSystem -Confirm:$false)

            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094125-x64\update.yaml') | Should -BeTrue
        }

        # -WhatIf ON A COMMAND THAT DELETES GIGABYTES IS NOT A FORMALITY.
        It 'removes nothing under -WhatIf, and still says what it would have done' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                -FileSystem $fileSystem -WhatIf

            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094126-x64\update.yaml') | Should -BeTrue
            $result.Id | Should -BeExactly 'KB5094126-x64'
        }
    }

    Context 'what it refuses' {

        # THE ID IS A FOLDER NAME, AND IT IS CHECKED TWICE - once as typed and
        # once as resolved. This is the check that stops '..\..\Windows' ever
        # becoming a path at all.
        It 'refuses an id that is a path, rather than resolving it: <Id>' -ForEach @(
            @{ Id = '..' }
            @{ Id = '.' }
            @{ Id = '..\..\Windows' }
            @{ Id = 'C:\Windows' }
            @{ Id = 'KB 5094126' }
        ) {
            $fileSystem = & $script:newFileSystem

            { Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id $Id -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw

            $fileSystem.TestPath('C:\ws\WindowsUpdates\KB5094126-x64\update.yaml') | Should -BeTrue
        }

        It 'refuses an id this share has no update for' {
            $fileSystem = & $script:newFileSystem

            { Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB0000000-x64' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*KB0000000-x64*'
        }

        # A FOLDER WITH NO update.yaml IS NOT AN IMPORTED UPDATE. It is somebody's
        # staging directory that happens to sit under WindowsUpdates\, and this
        # command must not be the thing that removes it.
        It 'refuses a folder that holds no update.yaml' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                   = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\WindowsUpdates\staging\notes.txt' = 'mine, not HDT''s'
            }

            { Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'staging' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*update.yaml*'

            $fileSystem.TestPath('C:\ws\WindowsUpdates\staging\notes.txt') | Should -BeTrue
        }
    }

    Context 'what was using it' {

        # AN ApplyUpdates STEP NAMES A RELEASE, NEVER AN ID, so the question this
        # answers is "which sequences would have applied this update", and the
        # answer is a warning rather than a refusal: the machine arrives without
        # it, and nothing fails.
        It 'reports the task sequences that apply this update''s release' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                -FileSystem $fileSystem -WhatIf

            @($result.UsedBy) | Should -Contain 'DEMO-M4'
        }

        It 'does not report a sequence that applies a different release' {
            $fileSystem = & $script:newFileSystem

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094125-x64' `
                -FileSystem $fileSystem -WhatIf

            @($result.UsedBy) | Should -Not -Contain 'DEMO-M4'
        }

        # AN EMPTY release IS "EVERYTHING IMPORTED", which the step template says
        # in as many words - so a sequence with one applies this update too.
        # A RELEASE THAT IS A VARIABLE IS NOT A MATCH, which is
        # Test-HDTSequenceNamesApplication's rule and it is followed here for its
        # reason: '%HDTOSRelease%' is resolved from the rules at run time, so
        # what it will apply cannot be read from the document. It is also the
        # SHIPPED TEMPLATE'S DEFAULT, so answering yes would name every sequence
        # on the share for every update and make the warning worth nothing.
        It 'does not report a sequence whose release is a variable, which the document cannot resolve' {
            $fileSystem = & $script:newFileSystem
            $fileSystem.WriteAllText('C:\ws\TaskSequences\DEMO-VAR\sequence.yaml',
                ($script:everythingYaml -replace "release: ''", "release: '%HDTOSRelease%'" -replace 'DEMO-ALL', 'DEMO-VAR'))

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                -FileSystem $fileSystem -WhatIf

            @($result.UsedBy) | Should -Not -Contain 'DEMO-VAR'
        }

        It 'reports a sequence that applies everything imported' {
            $fileSystem = & $script:newFileSystem
            $fileSystem.WriteAllText('C:\ws\TaskSequences\DEMO-ALL\sequence.yaml', $script:everythingYaml)

            $result = Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\ws' -Id 'KB5094126-x64' `
                -FileSystem $fileSystem -WhatIf

            @($result.UsedBy) | Should -Contain 'DEMO-ALL'
        }
    }
}

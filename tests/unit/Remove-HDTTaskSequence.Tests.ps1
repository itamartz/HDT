# TAKING A TASK SEQUENCE AWAY, which is the one authoring command that deletes a
# folder rather than splicing lines.
#
# EVERY REFUSAL HERE IS ABOUT WHAT IT MIGHT DELETE INSTEAD. The id is the folder
# name - TaskSequences\<id>\ - so a separator in it climbs out of the share, and
# an id naming a folder that holds no sequence.yaml is somebody's data that
# happens to sit in the wrong place. Neither is this command's to remove.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:newShare = {
        return (New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                          = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \host\share"
                'C:\ws\TaskSequences\WIN11\sequence.yaml'       = "schemaVersion: 1`nid: WIN11`nname: Windows 11`nsteps: []"
                'C:\ws\TaskSequences\WIN11\unattend.xml'        = '<unattend />'
                'C:\ws\TaskSequences\SERVER\sequence.yaml'      = "schemaVersion: 1`nid: SERVER`nname: Server`nsteps: []"
            })
    }
}

Describe 'Remove-HDTTaskSequence' {

    It 'takes the folder, and everything the sequence kept in it' {
        $fs = & $script:newShare

        Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeFalse
        $fs.TestPath('C:\ws\TaskSequences\WIN11\unattend.xml') | Should -BeFalse
        $fs.TestPath('C:\ws\TaskSequences\WIN11') | Should -BeFalse
    }

    It 'leaves every other sequence alone' {
        $fs = & $script:newShare

        Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\ws\TaskSequences\SERVER\sequence.yaml') | Should -BeTrue
        $fs.TestPath('C:\ws\workspace.yaml') | Should -BeTrue
    }

    It 'reports what it removed' {
        $fs = & $script:newShare

        $gone = Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -FileSystem $fs -Confirm:$false

        [string] $gone.Id | Should -BeExactly 'WIN11'
        [string] $gone.Path | Should -BeExactly 'C:\ws\TaskSequences\WIN11'
    }

    It 'writes nothing under -WhatIf' {
        $fs = & $script:newShare

        [void] (Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -FileSystem $fs -WhatIf)

        $fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeTrue
    }

    It 'refuses an id this workspace does not have' {
        $fs = & $script:newShare

        { Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'NOPE' -FileSystem $fs -Confirm:$false } |
            Should -Throw '*NOPE*'
    }

    It 'refuses a folder that holds no sequence' {
        # SOMEBODY'S DATA IN THE WRONG PLACE IS NOT A TASK SEQUENCE. Removing a
        # folder under TaskSequences\ just because it is there would delete it on
        # the strength of where it sits.
        $fs = & $script:newShare
        $fs.WriteAllText('C:\ws\TaskSequences\NOTES\readme.txt', 'mine')

        { Remove-HDTTaskSequence -Workspace 'C:\ws' -Id 'NOTES' -FileSystem $fs -Confirm:$false } |
            Should -Throw '*sequence.yaml*'

        $fs.TestPath('C:\ws\TaskSequences\NOTES\readme.txt') | Should -BeTrue
    }

    It 'refuses an id that is a path' -ForEach @(
        @{ Id = '..' }
        @{ Id = '..\..\Windows' }
        @{ Id = 'WIN11\..\SERVER' }
        @{ Id = 'C:\Windows' }
        @{ Id = 'WIN 11' }
    ) {
        # THE ID IS THE FOLDER NAME. A separator in it is a path, and a path is
        # how a delete leaves the share it was pointed at.
        $fs = & $script:newShare

        { Remove-HDTTaskSequence -Workspace 'C:\ws' -Id $Id -FileSystem $fs -Confirm:$false } |
            Should -Throw

        $fs.TestPath('C:\ws\TaskSequences\SERVER\sequence.yaml') | Should -BeTrue
    }

    It 'is destructive enough to ask' {
        # ConfirmImpact High means it prompts without -Confirm:$false, which is
        # what stops a pipeline removing a sequence somebody still wanted.
        $meta = (Get-Command -Name 'Remove-HDTTaskSequence').ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        $meta.SupportsShouldProcess | Should -BeTrue
        [string] $meta.ConfirmImpact | Should -BeExactly 'High'
    }
}

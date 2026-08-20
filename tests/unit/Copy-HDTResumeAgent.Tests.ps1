# WHAT THE DEPLOYED MACHINE NEEDS IN ORDER TO CARRY ON.
#
# DESIGN 4.5.1 launches the engine at logon from C:\HDT\Start-HDTResume.ps1, and
# DESIGN 4.3 mirrors state.json to the target disk's \HDT\ "as soon as a
# formatted volume exists". Until this command existed the SECOND half was built
# and the first was not: the resume payload and the engine were staged into the
# BOOT IMAGE at X:\HDT\, which is a RAM disk, and nothing ever put them on the
# disk the machine was about to boot from.
#
# The consequence was not a crash. WinPE deployed Windows, the machine restarted,
# Windows autologged on - and then sat at a desktop with a RunOnce entry pointing
# at a file that was not there. Every step in a FullOS group was dead: on the
# shipped client template that is the whole State Restore group, which is where
# applications install. A deployment that installs no software while reporting
# success is the worst shape a bug can take, and it is why this is one command
# with its own tests rather than four lines inside the reboot ceremony.
#
# IT COPIES THE IMAGE'S OWN TREE, rather than rebuilding one from the module on
# the build host. The engine that resumes must be the engine that started, and
# X:\HDT\Modules is by construction the one the boot image was built with.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # THE BOOT IMAGE'S X:\HDT, AS Update-HDTBootImage LEAVES IT. The names are
    # the ones that command actually writes, so a rename there fails here.
    $script:newSource = {
        $file = @{
            'X:\HDT\Start-HDTResume.ps1'                              = '# resume'
            'X:\HDT\Start-HDTDeployment.ps1'                          = '# deployment'
            'X:\HDT\Import-HDTBootCertificate.ps1'                    = '# certificate'
            'X:\HDT\bootstrap.json'                                   = '{ "deployRoot": "\\\\server\\HDTShare" }'
            'X:\HDT\Modules\Hephaestus\Hephaestus.psd1'               = '@{}'
            'X:\HDT\Modules\Hephaestus\Hephaestus.psm1'               = '# loader'
            'X:\HDT\Modules\Hephaestus\Public\Get-HDTThing.ps1'       = '# thing'
            'X:\HDT\Modules\powershell-yaml\powershell-yaml.psd1'     = '@{}'
            'X:\HDT\UI\HDTWizard.xaml'                                = '<Window />'
        }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Copy-HDTResumeAgent' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Copy-HDTResumeAgent' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'staging onto the volume the image was just applied to' {

        BeforeAll {
            $script:fileSystem = & $script:newSource
            $script:staged = Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $script:fileSystem -Confirm:$false
        }

        It 'puts the resume payload where RunOnce will look for it' {
            # Set-HDTAutoLogon's ResumeCommand is <volume>\HDT\Start-HDTResume.ps1,
            # and on the booted machine that volume is C:.
            $script:fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeTrue
        }

        It 'stages the engine beside it, because the payload imports a module' {
            $script:fileSystem.TestPath('W:\HDT\Modules\Hephaestus\Hephaestus.psd1') | Should -BeTrue
            $script:fileSystem.TestPath('W:\HDT\Modules\Hephaestus\Public\Get-HDTThing.ps1') | Should -BeTrue
        }

        It 'stages powershell-yaml, without which the engine reads no document at all' {
            $script:fileSystem.TestPath('W:\HDT\Modules\powershell-yaml\powershell-yaml.psd1') | Should -BeTrue
        }

        It 'stages the bootstrap document, which is how the resume finds the share' {
            # The full-OS leg has to reach Applications\ on the deployment share,
            # and bootstrap.json is what carries the deploy root and the account
            # that opens it. Without it the resume knows only C:.
            $script:fileSystem.TestPath('W:\HDT\bootstrap.json') | Should -BeTrue
        }

        It 'does not stage the WinPE entry point' {
            # X:\HDT\Start-HDTDeployment.ps1 is what startnet.cmd runs. A copy on
            # the deployed machine would be a second answer to "what starts a
            # deployment", and the one nothing launches.
            $script:fileSystem.TestPath('W:\HDT\Start-HDTDeployment.ps1') | Should -BeFalse
        }

        It 'does not stage the technician UI' {
            # The wizard runs in WinPE, before the disk exists. Nothing in the
            # full OS opens it.
            $script:fileSystem.TestPath('W:\HDT\UI\HDTWizard.xaml') | Should -BeFalse
        }

        It 'says what it staged, so a log can carry the answer' {
            $script:staged.Path | Should -BeExactly 'W:\HDT'
            $script:staged.FileCount | Should -BeGreaterThan 0
        }
    }

    Context 'a volume named with a trailing separator' {

        It 'lands in the same place, because a caller passes what it was given' {
            # Get-PathRoot answers 'W:\'; a variable a step published answers 'W:'.
            $fileSystem = & $script:newSource

            [void] (Copy-HDTResumeAgent -TargetVolume 'W:\' -FileSystem $fileSystem -Confirm:$false)

            $fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeTrue
        }
    }

    Context 'a boot image with no resume payload in it' {

        It 'refuses, and names the file' {
            # A SILENTLY EMPTY STAGE IS A MACHINE THAT BOOTS AND DOES NOTHING -
            # the exact failure this command exists to end. It is better to fail
            # in WinPE, where the log is still being written, than to succeed
            # into a desktop nobody is watching.
            $fileSystem = New-HDTFakeFileSystem -File @{ 'X:\HDT\Start-HDTDeployment.ps1' = '# deployment' }

            { Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Start-HDTResume.ps1*'
        }
    }

    Context 'a boot image with no bootstrap document' {

        It 'stages what is there rather than refusing' {
            # An image built for the Local provider carries no share to reach, and
            # a full-OS leg that only runs steps needing no content is legitimate.
            $fileSystem = New-HDTFakeFileSystem -File @{
                'X:\HDT\Start-HDTResume.ps1'                = '# resume'
                'X:\HDT\Modules\Hephaestus\Hephaestus.psd1' = '@{}'
            }

            $staged = Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fileSystem -Confirm:$false

            $staged.FileCount | Should -BeGreaterThan 0
            $fileSystem.TestPath('W:\HDT\bootstrap.json') | Should -BeFalse
        }
    }

    Context 'a source that is not there at all' {

        It 'refuses, and names the folder' {
            $fileSystem = New-HDTFakeFileSystem -File @{ 'W:\Windows\notepad.exe' = 'x' }

            { Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*X:\HDT*'
        }
    }

    Context 'WhatIf' {

        It 'writes nothing' {
            $fileSystem = & $script:newSource

            [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fileSystem -WhatIf)

            $fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeFalse
        }
    }
}

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

    Context 'however the volume is spelled' {

        # THE ENGINE PUBLISHES A BARE LETTER. HDTOSVolume is 'W', not 'W:' and
        # not 'W:\', and Invoke-HDTApplyImageStep normalises with
        # .TrimEnd('\').TrimEnd(':') before building a path from it - the
        # convention every volume variable in HDT follows.
        #
        # THIS TEST USED TO ASSERT 'W:' AND 'W:\' AND NOT 'W', and the missing
        # case is the one that happened. On a real deployment the agent went to
        # 'W\HDT' - a RELATIVE path - so 408 files landed on the RAM disk and
        # died with it. The machine booted, autologged on, and had nothing to
        # run, while the test stayed green against a value the engine never
        # produces. Fixtures come from real captured data; so do parameters.
        It 'stages to the same place given <Spelling>' -ForEach @(
            @{ Spelling = 'W' }
            @{ Spelling = 'W:' }
            @{ Spelling = 'W:\' }
            @{ Spelling = 'w' }
        ) {
            $fileSystem = & $script:newSource

            $staged = Copy-HDTResumeAgent -TargetVolume $Spelling -FileSystem $fileSystem -Confirm:$false

            $fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeTrue
            $staged.Path | Should -BeExactly 'W:\HDT'
        }

        It 'refuses something that is not a drive letter, rather than writing a relative path' {
            # A RELATIVE DESTINATION IS THE FAILURE THIS COMMAND EXISTS TO STOP,
            # reached from the other end: files written somewhere nobody looks,
            # and a machine that boots into nothing.
            $fileSystem = & $script:newSource

            { Copy-HDTResumeAgent -TargetVolume 'the big disk' -FileSystem $fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*drive letter*'
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

# THE SHARE THE MACHINE ACTUALLY REACHED, NOT THE ONE THE IMAGE WAS BUILT WITH.
#
# bootstrap.json is baked into the boot image, so it carries whatever deploy
# root was true when the image was made. A technician who corrects the share at
# the Welcome screen - because the address moved, which in this lab it does -
# fixes the WinPE leg only: the resume agent staged the boot image's own copy,
# so the full-OS leg asked for the dead address again.
#
# Watched happen on 2026-08-21: the WinPE leg ran all nine steps against
# \192.168.2.40\HDTShare after the screen was corrected, then the machine
# rebooted, resumed, and stopped on 'the deployment share could not be reached'
# for \192.168.2.39\HDTShare. Install Applications never ran, and no drive was
# mapped - MDT's Z: - because the connect that maps it had already failed.
Describe 'Copy-HDTResumeAgent and the share that was actually reached' {

    BeforeEach {
        $script:fs = & $script:newSource
    }

    It 'writes the resolved deploy root into the staged document' {
        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $script:fs `
                -DeployRoot '\192.168.2.40\HDTShare' -Confirm:$false)

        $staged = $script:fs.ReadAllText('W:\HDT\bootstrap.json') | ConvertFrom-Json

        $staged.deployRoot | Should -BeExactly '\192.168.2.40\HDTShare'
    }

    # EVERY OTHER KEY IS THE IMAGE'S. The account, the provider, the content
    # marker - one value is corrected and the document is otherwise the one the
    # boot image was built with.
    It 'leaves the rest of the document alone' {
        $script:fs.SeedFile('X:\HDT\bootstrap.json',
            '{ "deployRoot": "\\old\HDTShare", "provider": "Smb", "userId": "svc-hdt-deploy" }')

        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $script:fs `
                -DeployRoot '\new\HDTShare' -Confirm:$false)

        $staged = $script:fs.ReadAllText('W:\HDT\bootstrap.json') | ConvertFrom-Json

        $staged.provider | Should -BeExactly 'Smb'
        $staged.userId | Should -BeExactly 'svc-hdt-deploy'
    }

    # NOT GIVEN ONE, NOT TOUCHED. A caller with nothing to correct copies the
    # document byte for byte, which is what every deployment did before this.
    It 'copies it unchanged when no deploy root is given' {
        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $script:fs -Confirm:$false)

        $staged = $script:fs.ReadAllText('W:\HDT\bootstrap.json') | ConvertFrom-Json

        $staged.deployRoot | Should -BeExactly '\\server\HDTShare'
    }

    It 'still stages nothing when the image carries no bootstrap document' {
        $bare = New-HDTFakeFileSystem -File @{
            'X:\HDT\Start-HDTResume.ps1' = '# resume'
        }

        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $bare `
                -DeployRoot '\new\HDTShare' -Confirm:$false)

        $bare.TestPath('W:\HDT\bootstrap.json') | Should -BeFalse
    }
}

# THE SCREEN THE FULL-OS LEG ENDS ON HAS TO BE ON THE MACHINE THAT SHOWS IT.
#
# UI\ used to be staged NOWHERE, and correctly so: the wizard runs in WinPE,
# before this disk has a partition table. Then the full-OS leg gained MDT's
# Deployment Summary, and that screen is drawn AFTER the reboot - from a module
# whose UI\ folder Update-HDTBootImage deliberately keeps out of the module tree.
#
# So the default path pointed at a file that never exists on a deployed machine,
# Show-HDTDeploymentFailure threw, a try/catch swallowed it into
# Write-Information, and a deployment that SUCCEEDED end to end ended in silence.
# Watched on 2026-08-21: Acrobat installed, autologon torn down, run Succeeded,
# and nothing on screen.
#
# TWO FILES, NOT THE FOLDER. The wizard, the Welcome screen and the theme belong
# to WinPE and are never drawn again; the summary and the PROGRESS BOARD are
# both shown after the reboot.
#
# THE BOARD WAS THE ONE NOBODY NOTICED WAS MISSING. A deployed machine had its
# applications in appwiz.cpl and nobody had watched one install - the full-OS
# leg drew nothing at all, and when it was given a window to draw, the markup it
# needed was still only in the boot image.
Describe 'Copy-HDTResumeAgent and the screens the full OS leg draws' {

    It 'stages the summary screen beside the engine' {
        $fs = & $script:newSource
        $fs.SeedFile('X:\HDT\UI\HDTFailure.xaml', '<Window />')

        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false)

        $fs.TestPath('W:\HDT\UI\HDTFailure.xaml') | Should -BeTrue
    }

    It 'stages the progress board beside it' {
        $fs = & $script:newSource
        $fs.SeedFile('X:\HDT\UI\HDTProgress.xaml', '<Window />')

        [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false)

        $fs.TestPath('W:\HDT\UI\HDTProgress.xaml') | Should -BeTrue
    }

    It 'counts the board too' {
        $fs = & $script:newSource
        $fs.SeedFile('X:\HDT\UI\HDTProgress.xaml', '<Window />')

        $answer = Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false

        @($answer.Item | Where-Object { $_.Name -like '*HDTProgress.xaml' }) | Should -Not -BeNullOrEmpty
    }

    It 'stages neither when the image has neither' {
        $fs = & $script:newSource

        { [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false) } | Should -Not -Throw

        $fs.TestPath('W:\HDT\UI\HDTProgress.xaml') | Should -BeFalse
    }

    It 'counts it, so the log says what was staged' {
        $fs = & $script:newSource
        $fs.SeedFile('X:\HDT\UI\HDTFailure.xaml', '<Window />')

        $answer = Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false

        @($answer.Item | Where-Object { $_.Name -like '*HDTFailure.xaml' }) | Should -Not -BeNullOrEmpty
    }

    # AN IMAGE WITHOUT IT STILL DEPLOYS. An older boot image has no such file,
    # and a machine that cannot show a summary must still finish its sequence.
    It 'stages nothing when the image has no summary screen' {
        $fs = & $script:newSource

        { [void] (Copy-HDTResumeAgent -TargetVolume 'W:' -FileSystem $fs -Confirm:$false) } | Should -Not -Throw

        $fs.TestPath('W:\HDT\UI\HDTFailure.xaml') | Should -BeFalse
    }
}

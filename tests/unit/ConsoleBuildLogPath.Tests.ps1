# THE BUILD LOG EXISTED ONLY WHILE SOMEBODY WAS WATCHING IT.
#
# Every line the boot image build reported went into a WPF list and nowhere
# else, so closing the window threw away the record of what the build did -
# including the build that failed, which is the one anybody would want to read
# afterwards. The Open Log button needs a file, and this decides where it is.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTConsoleBuildLogPath' {

    It 'is reachable inside the module' {
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTConsoleBuildLogPath' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'writes beside the image, the ISO and the manifest' {
        InModuleScope Hephaestus {
            Get-HDTConsoleBuildLogPath -WorkspaceRoot 'C:\HDTLab\Share' -Name 'HDTPE_wiz_x64' |
                Should -BeExactly 'C:\HDTLab\Share\Boot\HDTPE_wiz_x64.build.log'
        }
    }

    It 'names the file for the image, so one build overwrites the last' {
        # NOT ONE FILE PER RUN. "The log" means the last build's, and a dated
        # file per run makes Boot\ grow without bound on a share nobody prunes -
        # the manifest beside it carries the build id when a particular run has
        # to be pinned.
        InModuleScope Hephaestus {
            $first = Get-HDTConsoleBuildLogPath -WorkspaceRoot 'C:\ws' -Name 'WinPE-x64'
            $again = Get-HDTConsoleBuildLogPath -WorkspaceRoot 'C:\ws' -Name 'WinPE-x64'

            $first | Should -BeExactly $again
        }
    }

    It 'still answers for a build that failed before it read the image name' {
        # THE BUILD WITH NO NAME IS EXACTLY THE ONE WHOSE LOG IS WORTH KEEPING.
        InModuleScope Hephaestus {
            Get-HDTConsoleBuildLogPath -WorkspaceRoot 'C:\ws' -Name '' |
                Should -BeExactly 'C:\ws\Boot\bootimage.build.log'
        }
    }
}

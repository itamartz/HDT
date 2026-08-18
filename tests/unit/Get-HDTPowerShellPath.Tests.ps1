# WHICH EXECUTABLE -Detach IS ALLOWED TO RELAUNCH.
#
# FOUND IN THE ISE. Start-HDTConsole -Detach relaunched "whatever executable
# this process is" - GetCurrentProcess().MainModule.FileName - which is right in
# powershell.exe and wrong everywhere else. In the ISE that resolves to
# powershell_ise.exe, and ISE takes exactly three parameters: -File, -Mta and
# -NoProfile. It has never had -STA. So the child was the ISE, started with a
# switch the ISE does not have, and the user got an error about STA from a
# command whose whole job is to get the apartment right.
#
# A HOST IS NOT ALWAYS A CONSOLE. The ISE is the one people hit, but the same
# hole is open in any WPF or WinForms application hosting PowerShell, in the
# runspace inside Visual Studio, and in an app that embeds
# System.Management.Automation - none of them can be handed -File and told to
# run a script.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTPowerShellPath' {

    BeforeEach {
        # A stand-in $PSHOME. The files only have to exist; nothing runs them.
        $script:shellHome = Join-Path -Path $TestDrive -ChildPath ('home-{0}' -f [guid]::NewGuid())
        New-Item -Path $script:shellHome -ItemType Directory -Force | Out-Null
    }

    Context 'the host is already a console' {

        It 'keeps <Leaf>, because it is the one that is already running' -ForEach @(
            @{ Leaf = 'powershell.exe' }
            @{ Leaf = 'pwsh.exe' }
            @{ Leaf = 'PowerShell.exe' }
        ) {
            $processPath = Join-Path -Path 'C:\Windows\System32\WindowsPowerShell\v1.0' -ChildPath $Leaf

            InModuleScope Hephaestus -Parameters @{ ProcessPath = $processPath; ShellHome = $script:shellHome } {
                param($ProcessPath, $ShellHome)

                Get-HDTPowerShellPath -ProcessPath $ProcessPath -InstallPath $ShellHome |
                    Should -BeExactly $ProcessPath
            }
        }
    }

    Context 'the host is not a console' {

        It 'falls back to the console host beside it' {
            $consolePath = Join-Path -Path $script:shellHome -ChildPath 'powershell.exe'
            New-Item -Path $consolePath -ItemType File -Force | Out-Null

            InModuleScope Hephaestus -Parameters @{ ShellHome = $script:shellHome; Console = $consolePath } {
                param($ShellHome, $Console)

                Get-HDTPowerShellPath -ProcessPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe' -InstallPath $ShellHome |
                    Should -BeExactly $Console
            }
        }

        It 'finds pwsh.exe when that is what the install directory holds' {
            $consolePath = Join-Path -Path $script:shellHome -ChildPath 'pwsh.exe'
            New-Item -Path $consolePath -ItemType File -Force | Out-Null

            InModuleScope Hephaestus -Parameters @{ ShellHome = $script:shellHome; Console = $consolePath } {
                param($ShellHome, $Console)

                Get-HDTPowerShellPath -ProcessPath 'C:\Program Files\Some App\host.exe' -InstallPath $ShellHome |
                    Should -BeExactly $Console
            }
        }

        It 'names the host, and what it looked for, when there is nothing to fall back to' {
            # A message that says "STA" sends somebody to read about apartments.
            # The cause is the host, and the message has to say so.
            InModuleScope Hephaestus -Parameters @{ ShellHome = $script:shellHome } {
                param($ShellHome)

                { Get-HDTPowerShellPath -ProcessPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe' -InstallPath $ShellHome } |
                    Should -Throw -ExpectedMessage '*powershell_ise.exe*'

                { Get-HDTPowerShellPath -ProcessPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe' -InstallPath $ShellHome } |
                    Should -Throw -ExpectedMessage ('*{0}*' -f $ShellHome)
            }
        }
    }
}

Describe 'Start-HDTConsole' {

    It 'asks which executable to relaunch rather than assuming its own' {
        # The bug was one line: GetCurrentProcess().MainModule.FileName used
        # directly as the thing to start.
        $text = [string] (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Start-HDTConsole.ps1') -Raw)

        $text | Should -BeLike '*Get-HDTPowerShellPath*'
    }
}

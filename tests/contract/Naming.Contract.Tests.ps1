# Enforces DESIGN 15.1 over the real repository: every function in src/, in
# tests/ (fixtures excluded) and in build.ps1 is named Verb-HDTNoun with an
# uppercase HDT prefix and an approved verb.
#
# The file and function lists are resolved at discovery time, not in BeforeAll:
# Pester 5 expands -ForEach while discovering, so a BeforeAll would produce zero
# test cases. The same setup is repeated in BeforeAll because discovery-phase
# variables do not survive into the run phase.
#
# ONE EXEMPTION, AND IT IS A MODULE WHOSE JOB IS TO IMPERSONATE ANOTHER ONE.
# See $script:HDTImpersonation below. It is scoped to one file AND to one list
# of names, so a helper that merely forgot the prefix still fails there; and it
# is expressed here rather than in Get-HDTSourceFile, deliberately, so the file
# stays covered by PSScriptAnalyzer and by the PowerShell 5.1 syntax contract -
# the exemption is from the naming rule and from nothing else.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:HDTHelperManifest = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
Import-Module -Name $script:HDTHelperManifest -Force -ErrorAction Stop

# THE ONE PLACE A FUNCTION MAY CARRY SOMEBODY ELSE'S NAME, and why.
#
# tests/helpers/HDTFakeHyperV/Hyper-V is a module called Hyper-V that touches no
# hypervisor. It exists because the lab helpers write every hypervisor call
# module-qualified - 'Hyper-V\New-VM' - which SPIKES S8 requires, PowerCLI
# shadowing Get-VM on this host. A module-qualified call resolves straight into
# the module of that name and never reaches the function table Pester's Mock
# injects into, so the only thing such a call CAN be pointed at is a module with
# that name exporting those names. Renaming them to Verb-HDTNoun would leave a
# fake nothing calls, and New-HDTLabVirtualMachine's stamp, its Generation 2 and
# its memory budget would go back to being asserted by reading the source.
#
# RULE 3'S REASON DOES NOT REACH HERE. The rule exists because the engine
# dot-sources user scripts from Scripts\ and third-party step types from
# Modules\ in WinPE, where an unprefixed Invoke-Dism is a live collision. This
# module is never imported by the engine, never shipped, and never loaded except
# by the one test file that imports it BY PATH and removes it again in AfterAll.
#
# THE HONEST FIX IS THE OTHER ONE, and it is not this lane's. If the hypervisor
# were an injected service the way IDiskService and IImageService are (rule 5),
# there would be nothing to shadow and no exemption to write. That means a new
# parameter on New-HDTLabVirtualMachine and a change at every e2e call site.
#
# The exemption is BY NAME as well as by file: a helper in that module that
# merely forgot the prefix is not on this list and still fails. It is declared
# in BeforeAll rather than out here because the run phase is the only place it
# is read, and a discovery variable read from BeforeAll is SPIKES S9.15.
$script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
$script:HDTSourceFunction = @(Get-HDTSourceFunction -Path $script:HDTSourceFile)

Describe 'Naming contract (DESIGN 15.1)' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
        $script:HDTSourceFunction = @(Get-HDTSourceFunction -Path $script:HDTSourceFile)

        $script:HDTEngineManifest = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'

        # THE ONE PLACE A FUNCTION MAY CARRY SOMEBODY ELSE'S NAME. See the file
        # header for why, and for the fix that would remove the need for it.
        $script:HDTImpersonation = @{
            Path   = 'tests/helpers/HDTFakeHyperV/Hyper-V/Hyper-V.psm1'
            Name   = @('New-VM', 'Get-VM', 'Set-VM', 'Set-VMMemory', 'Add-VMHardDiskDrive',
                'Set-VMFirmware', 'Add-VMDvdDrive', 'Get-VMDvdDrive')
            Reason = "the module impersonates Hyper-V's own command names; a module-qualified call cannot be pointed anywhere else"
        }
    }

    It 'discovers at least one source file' {
        $script:HDTSourceFile.Count | Should -BeGreaterThan 0
    }

    It 'discovers at least ten functions across the repository' {
        # Anti-vacuity guard. A naming contract that silently finds nothing to check
        # is worse than no contract: it reports green forever.
        $script:HDTSourceFunction.Count | Should -BeGreaterThan 9
    }

    It 'names every function Verb-HDTNoun with an approved verb' {
        # The impersonations are dropped here and nowhere else - see the header.
        $judged = @($script:HDTSourceFunction | Where-Object {
                -not (($_.Path.Replace('\', '/')) -like ('*{0}' -f $script:HDTImpersonation.Path) -and
                    $script:HDTImpersonation.Name -contains $_.Name)
            })

        $violation = @(Get-HDTFunctionNameViolation -Name @($judged | ForEach-Object { $_.Name }))

        $because = 'DESIGN 15.1 applies to public cmdlets, private helpers, test helpers and build functions alike'
        if ($violation.Count -gt 0) {
            $detail = foreach ($item in $violation) {
                $definition = @($judged | Where-Object { $_.Name -eq $item.Name })
                foreach ($item2 in $definition) {
                    $relative = $item2.Path.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
                    '{0}:{1} {2} {3}' -f $relative, $item2.Line, $item.Name, $item.Reason
                }
            }
            $because = @($detail) -join "`n"
        }

        $violation.Count | Should -Be 0 -Because $because
    }

    It 'exempts only names the impersonating module actually defines' {
        # AN EXEMPTION LIST IS A LOOPHOLE THE MOMENT IT STOPS MATCHING REALITY.
        # A name left here after the fake stopped defining it would silently
        # excuse any function anywhere that happened to be called that, since
        # the file test alone cannot see a name that is no longer there. So the
        # list is held to the file: every entry must be defined in it, and every
        # function in it must either be on the list or pass the naming rule on
        # its own.
        $defined = @($script:HDTSourceFunction | Where-Object {
                ($_.Path.Replace('\', '/')) -like ('*{0}' -f $script:HDTImpersonation.Path)
            } | ForEach-Object { $_.Name })

        @($defined).Count | Should -BeGreaterThan 0 -Because (
            'the exempted file {0} defines no functions, so the exemption is stale' -f $script:HDTImpersonation.Path)

        $stale = @($script:HDTImpersonation.Name | Where-Object { $defined -notcontains $_ })
        $stale -join ', ' | Should -BeExactly '' -Because 'an exempted name that file no longer defines is a loophole'

        $unexcused = @($defined |
                Where-Object { $script:HDTImpersonation.Name -notcontains $_ } |
                Where-Object { -not (Test-HDTFunctionName -Name $_) })

        $unexcused -join ', ' | Should -BeExactly '' -Because (
            'only the impersonations are excused; everything else in that module is Verb-HDTNoun like the rest of the repository')
    }

    It 'exports every public function under a Verb-HDTNoun name' {
        Import-Module -Name $script:HDTEngineManifest -Force -ErrorAction Stop
        $module = Get-Module -Name 'Hephaestus'

        $exported = @($module.ExportedFunctions.Keys)
        $exported.Count | Should -BeGreaterThan 0

        foreach ($item in $exported) {
            Test-HDTFunctionName -Name $item | Should -BeTrue -Because "$item is exported by the engine module"
        }
    }

    It 'does not use DefaultCommandPrefix in the manifest' {
        # DESIGN 15.1: the prefix only applies on import, so it would vanish when the
        # engine dot-sources its own files in WinPE. The prefix is written into every
        # function name at the source instead.
        $manifest = Import-PowerShellDataFile -Path $script:HDTEngineManifest
        $manifest.ContainsKey('DefaultCommandPrefix') | Should -BeFalse
    }

    It 'defines no aliases in committed code' {
        # DESIGN 15.2: "no aliases in committed code". Detected through the AST, so
        # that naming these cmdlets in a string - as this very test does - is not
        # itself a hit.
        $alias = New-Object -TypeName System.Collections.ArrayList

        foreach ($item in $script:HDTSourceFile) {
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item, [ref] $token, [ref] $parseError)
            if (@($parseError).Count -gt 0) {
                continue
            }

            $command = @($ast.FindAll({ $args[0].GetType().Name -eq 'CommandAst' }, $true))
            foreach ($item2 in $command) {
                $name = $item2.GetCommandName()
                if ($name -and ($name -eq 'New-Alias' -or $name -eq 'Set-Alias' -or $name -eq 'nal' -or $name -eq 'sal')) {
                    $relative = $item.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
                    [void] $alias.Add(('{0}:{1} {2}' -f $relative, $item2.Extent.StartLineNumber, $name))
                }
            }
        }

        $alias.Count | Should -Be 0 -Because (@($alias) -join "`n")
    }
}

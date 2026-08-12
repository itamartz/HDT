# Enforces DESIGN 15.1 over the real repository: every function in src/, in
# tests/ (fixtures excluded) and in build.ps1 is named Verb-HDTNoun with an
# uppercase HDT prefix and an approved verb.
#
# The file and function lists are resolved at discovery time, not in BeforeAll:
# Pester 5 expands -ForEach while discovering, so a BeforeAll would produce zero
# test cases. The same setup is repeated in BeforeAll because discovery-phase
# variables do not survive into the run phase.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:HDTHelperManifest = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
Import-Module -Name $script:HDTHelperManifest -Force -ErrorAction Stop

$script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
$script:HDTSourceFunction = @(Get-HDTSourceFunction -Path $script:HDTSourceFile)

Describe 'Naming contract (DESIGN 15.1)' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
        $script:HDTSourceFunction = @(Get-HDTSourceFunction -Path $script:HDTSourceFile)

        $script:HDTEngineManifest = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
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
        $violation = @(Get-HDTFunctionNameViolation -Name @($script:HDTSourceFunction | ForEach-Object { $_.Name }))

        $because = 'DESIGN 15.1 applies to public cmdlets, private helpers, test helpers and build functions alike'
        if ($violation.Count -gt 0) {
            $detail = foreach ($item in $violation) {
                $definition = @($script:HDTSourceFunction | Where-Object { $_.Name -eq $item.Name })
                foreach ($item2 in $definition) {
                    $relative = $item2.Path.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
                    '{0}:{1} {2} {3}' -f $relative, $item2.Line, $item.Name, $item.Reason
                }
            }
            $because = @($detail) -join "`n"
        }

        $violation.Count | Should -Be 0 -Because $because
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

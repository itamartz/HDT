#requires -Version 5.1

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTWorkspacePath' {

    # Why this exists: a workspace folder name that lives only in prose can drift
    # from the code that builds paths to it, and nothing catches the drift.
    # Start-HDTResume.ps1 shipped with 'Sequences' while every document, the
    # sample tree and the flattener said 'TaskSequences'. 2838 unit tests passed;
    # a real deployment would have died at its first reboot, unable to find its
    # own sequence. The layout belongs in exactly one place.

    Context 'the canonical folder names (DESIGN 2.1)' {

        It 'resolves <Kind> to <Folder>' -ForEach @(
            @{ Kind = 'TaskSequences';    Folder = 'TaskSequences' }
            @{ Kind = 'OperatingSystems'; Folder = 'OperatingSystems' }
            @{ Kind = 'Applications';     Folder = 'Applications' }
            @{ Kind = 'Drivers';          Folder = 'Drivers' }
            @{ Kind = 'Boot';             Folder = 'Boot' }
            @{ Kind = 'Logs';             Folder = 'Logs' }
            @{ Kind = 'Captures';         Folder = 'Captures' }
            @{ Kind = 'Control';          Folder = 'Control' }
            @{ Kind = 'Scripts';          Folder = 'Scripts' }
            @{ Kind = 'Modules';          Folder = 'Modules' }
        ) {
            $result = Get-HDTWorkspacePath -Root 'X:\Deploy' -Kind $Kind
            $result | Should -Be ([System.IO.Path]::Combine('X:\Deploy', $Folder))
        }

        It 'rejects a folder name that is not part of the layout' {
            { Get-HDTWorkspacePath -Root 'X:\Deploy' -Kind 'Sequences' } |
                Should -Throw
        }
    }

    Context 'addressing an item inside a kind' {

        It 'appends child segments in order' {
            Get-HDTWorkspacePath -Root 'X:\Deploy' -Kind TaskSequences -ChildPath 'STD-CLIENT', 'sequence.yaml' |
                Should -Be ([System.IO.Path]::Combine('X:\Deploy', 'TaskSequences', 'STD-CLIENT', 'sequence.yaml'))
        }

        It 'is the path the sample tree actually uses' {
            $sample = Get-HDTWorkspacePath -Root (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace') `
                -Kind TaskSequences -ChildPath 'DEMO-M2', 'sequence.yaml'
            Test-Path -LiteralPath $sample -PathType Leaf | Should -BeTrue -Because 'the resolver must agree with the shipped sample workspace'
        }
    }

    Context 'the whole repository agrees on the layout' {

        It 'has no source file building a workspace path from a non-canonical folder literal' {
            # The specific regression: 'Sequences' as a path segment anywhere in
            # shipping code. Comments and docs are free to mention it.
            $file = Get-HDTSourceFile -RepositoryRoot $script:repoRoot |
                Where-Object { $_ -like '*\src\*' }

            $offender = foreach ($path in $file) {
                $token = $null; $parseError = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)
                foreach ($t in $token) {
                    if ($t.Kind -eq 'StringLiteral' -and $t.Value -eq 'Sequences') {
                        '{0}:{1}' -f $path, $t.Extent.StartLineNumber
                    }
                }
            }

            @($offender) -join "`n" | Should -BeNullOrEmpty -Because 'the canonical folder is TaskSequences; build it with Get-HDTWorkspacePath'
        }
    }
}

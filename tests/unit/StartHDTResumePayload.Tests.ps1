# src/Hephaestus/Payload/Start-HDTResume.ps1 - the RunOnce payload.
#
# Not a module file: the loader only dot-sources Private\ and Public\, so this is
# staged to C:\HDT\ and launched by the RunOnce entry Set-HDTAutoLogon writes.
#
# IT IS TESTED BY PARSING AND INSPECTING IT rather than by running it. Running it
# for real means importing a module from C:\HDT\Modules, building real service
# adapters, and rebooting a machine - which belongs to phase 04's integration
# layer, where there is a machine to reboot. What CAN be proven from a desk is
# the thing most likely to be got wrong: that the boot reconcile runs BEFORE
# anything else (DESIGN 4.5.2), that the payload passes the reconciled state to
# the loop rather than starting a new run, and that it parses under both engines.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTResume.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = $null

    if (Test-Path -LiteralPath $script:payloadPath -PathType Leaf) {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $script:token, [ref] $script:parseError)
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) {
            return @()
        }

        # Copied into a local before the nested predicate closes over it:
        # PSScriptAnalyzer cannot see a parameter used only inside a nested
        # scriptblock and reports it unused.
        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }
}

Describe 'Start-HDTResume.ps1' {

    It 'exists at src/Hephaestus/Payload/Start-HDTResume.ps1' {
        Test-Path -LiteralPath $script:payloadPath -PathType Leaf | Should -BeTrue
    }

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'passes the PowerShell 5.1 syntax scanner' {
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $script:payloadPath)

        $violation.Count | Should -Be 0 -Because (@($violation | ForEach-Object { $_.Reason }) -join "`n")
    }

    It 'defines no unprefixed function' {
        $name = @(Get-HDTSourceFunction -Path $script:payloadPath | ForEach-Object { $_.Name })
        $violation = @(Get-HDTFunctionNameViolation -Name $name)

        $violation.Count | Should -Be 0
    }

    It 'is not dot-sourced by the module loader' {
        # Payload\ is deliberately outside Private\ and Public\: this script runs
        # as a script, not as an exported command.
        $loader = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psm1') -Raw

        $loader | Should -Not -BeLike '*Payload*'
    }

    Context 'the parameters' {

        It 'takes a -ModulePath parameter' {
            $parameter = @($script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

            $parameter | Should -Contain 'ModulePath'
        }

        It 'defaults the module path to C:\HDT\Modules\Hephaestus' {
            $modulePath = @($script:ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'ModulePath' })[0]

            $modulePath.DefaultValue.Extent.Text | Should -BeLike '*C:\HDT\Modules\Hephaestus*'
        }

        It 'takes a -StatePath parameter defaulting to C:\HDT\state.json' {
            $statePath = @($script:ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'StatePath' })

            $statePath.Count | Should -Be 1
            $statePath[0].DefaultValue.Extent.Text | Should -BeLike '*C:\HDT\state.json*'
        }

        It 'sets StrictMode and ErrorActionPreference' {
            @(& $script:commandNamed 'Set-StrictMode').Count | Should -Be 1
            $script:text | Should -BeLike "*ErrorActionPreference = 'Stop'*"
        }
    }

    Context 'the order of operations' {

        It 'calls Invoke-HDTBootReconciliation' {
            @(& $script:commandNamed 'Invoke-HDTBootReconciliation').Count | Should -Be 1
        }

        It 'calls Invoke-HDTTaskSequence' {
            @(& $script:commandNamed 'Invoke-HDTTaskSequence').Count | Should -Be 1
        }

        It 'calls the reconcile before the loop' {
            # DESIGN 4.5.2: "before doing anything else".
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            $reconcile.Extent.StartOffset | Should -BeLessThan $loop.Extent.StartOffset
        }

        It 'imports the module before the reconcile' {
            $import = @(& $script:commandNamed 'Import-Module')[0]
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]

            $import.Extent.StartOffset | Should -BeLessThan $reconcile.Extent.StartOffset
        }

        It 'returns without running the sequence when the reconcile said Teardown' {
            # The guard has to name Teardown and has to come between the two.
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            $guard = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.IfStatementAst]
                    }, $true) | Where-Object {
                    $_.Extent.StartOffset -gt $reconcile.Extent.StartOffset -and
                    $_.Extent.StartOffset -lt $loop.Extent.StartOffset -and
                    $_.Extent.Text -like '*Teardown*'
                })

            $guard.Count | Should -BeGreaterOrEqual 1
            @($guard | Where-Object { $_.Extent.Text -like '*exit 0*' -or $_.Extent.Text -like '*return*' }).Count |
                Should -BeGreaterOrEqual 1
        }
    }

    Context 'what it hands the loop' {

        It 'passes -State to Invoke-HDTTaskSequence' {
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            @($loop.CommandElements | ForEach-Object { $_.Extent.Text }) | Should -Contain '-State'
        }

        It 'rebuilds the log context from the state seq' {
            $script:text | Should -BeLike '*-Seq*'
            $script:text | Should -BeLike '*New-HDTLogContext*'
        }

        It 're-imports the sequence rather than assuming one' {
            @(& $script:commandNamed 'Import-HDTSequenceDocument').Count | Should -Be 1
        }

        It 'builds the real service adapters' {
            foreach ($name in @('New-HDTFileSystem', 'New-HDTClock', 'New-HDTRegistryService', 'New-HDTLsaService', 'New-HDTPowerService')) {
                @(& $script:commandNamed $name).Count | Should -BeGreaterOrEqual 1 -Because "the payload has to build $name"
            }
        }

        It 'names no fake' {
            $script:text | Should -Not -BeLike '*New-HDTFake*'
        }
    }
}

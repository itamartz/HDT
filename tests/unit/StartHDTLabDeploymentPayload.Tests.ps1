# tests/e2e/payload/Start-HDTLabDeployment.ps1 - the launcher the E2E types at
# the WinPE prompt.
#
# IT IS TESTED BY PARSING AND INSPECTING IT, exactly as 03-04 tests
# Start-HDTResume.ps1. Running it for real means a VM, a content disk and a
# machine to shut down, which is what tests/e2e is.
#
# THE ASSERTION THIS FILE EXISTS FOR: the launcher contains NO DEPLOYMENT LOGIC.
# ROADMAP M3's exit criterion is "a VM boots into Windows FROM A SEQUENCE RUN
# end-to-end". A launcher that partitioned a disk itself, or applied an image
# itself, would make that claim a lie while still producing a booting VM - and
# nobody would notice, because the VM would boot. So this file asserts, by AST,
# that it names no Storage cmdlet, no DISM cmdlet, no bcdboot, bcdedit,
# reagentc or diskpart, and calls Invoke-HDTTaskSequence exactly once.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/payload/Start-HDTLabDeployment.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = $null
    $script:text = ''

    if (Test-Path -LiteralPath $script:payloadPath -PathType Leaf) {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $script:token, [ref] $script:parseError)
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) { return @() }

        # Copied into a local before the nested predicate closes over it, or
        # PSScriptAnalyzer reports the parameter unused.
        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    $script:everyCommandName = @()
    if ($null -ne $script:ast) {
        $script:everyCommandName = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { [string] $_.GetCommandName() } | Where-Object { $_ })
    }

    # The Storage and DISM cmdlets IDiskService and IImageService exist to be
    # the only callers of, plus the native tools they wrap.
    $script:forbiddenCommand = @(
        'Get-Disk', 'Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Set-Partition',
        'Remove-Partition', 'Get-Partition', 'Format-Volume', 'Get-Volume',
        'Remove-PartitionAccessPath', 'Add-PartitionAccessPath',
        'Get-WindowsImage', 'Expand-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage',
        'Add-WindowsDriver', 'Add-WindowsPackage'
    )

    $script:forbiddenText = @('bcdboot', 'bcdedit', 'reagentc', 'diskpart', 'dism.exe')

    # THE CODE, WITHOUT THE COMMENTS. The header of the launcher says in prose
    # that it calls no bcdboot - and a raw text scan would fail on that sentence,
    # which would teach the next author to delete the sentence rather than keep
    # the property. Scanning the token stream with the comments dropped asserts
    # the thing that matters.
    $script:codeOnly = ''
    if ($null -ne $script:token) {
        $script:codeOnly = (@($script:token |
                    Where-Object { $_.Kind -ne 'Comment' } |
                    ForEach-Object { [string] $_.Text }) -join ' ')
    }
}

Describe 'Start-HDTLabDeployment.ps1' {

    It 'exists at tests/e2e/payload/Start-HDTLabDeployment.ps1' {
        Test-Path -LiteralPath $script:payloadPath -PathType Leaf | Should -BeTrue
    }

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'passes the PowerShell 5.1 compatibility scanner' {
        # It runs inside WinPE, which has 5.1 and no pwsh at all.
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $script:payloadPath)

        $violation.Count | Should -Be 0 -Because (@($violation | ForEach-Object { $_.Reason }) -join "`n")
    }

    It 'defines no unprefixed function' {
        $name = @(Get-HDTSourceFunction -Path $script:payloadPath | ForEach-Object { $_.Name })
        $violation = @(Get-HDTFunctionNameViolation -Name $name)

        $violation.Count | Should -Be 0
    }

    It 'sets StrictMode and ErrorActionPreference' {
        @(& $script:commandNamed 'Set-StrictMode').Count | Should -Be 1
        $script:text | Should -BeLike "*ErrorActionPreference = 'Stop'*"
    }

    Context 'it does no deployment work itself' {

        It 'names no fake' {
            $script:text | Should -Not -BeLike '*New-HDTFake*'
        }

        It 'names no Storage or DISM cmdlet' {
            $hit = @($script:everyCommandName | Where-Object { $script:forbiddenCommand -contains $_ })

            $hit | Should -BeNullOrEmpty -Because ('the launcher called: {0}' -f ($hit -join ', '))
        }

        It 'names no native boot tool' {
            $script:codeOnly | Should -Not -BeNullOrEmpty

            foreach ($tool in $script:forbiddenText) {
                $script:codeOnly | Should -Not -Match ('\b{0}\b' -f [regex]::Escape($tool)) `
                    -Because "$tool belongs to IImageService, not to a launcher"
            }
        }

        It 'calls Invoke-HDTTaskSequence exactly once' {
            # ONE call. Not one per step, not one per group - the loop owns the
            # sequence, and a launcher that drove steps itself would not be
            # proving the engine ran the deployment.
            @(& $script:commandNamed 'Invoke-HDTTaskSequence').Count | Should -Be 1
        }

        It 'invokes no step function directly' {
            $hit = @($script:everyCommandName | Where-Object { $_ -like 'Invoke-HDT*Step' })

            $hit | Should -BeNullOrEmpty -Because ('the launcher called: {0}' -f ($hit -join ', '))
        }
    }

    Context 'the dependency proof' {

        It 'imports powershell-yaml before it imports Hephaestus' {
            # ConvertFrom-HDTYaml imports powershell-yaml lazily and reports
            # HDTDependencyError when it is absent, so the engine cannot read a
            # single YAML document without it. It is STAGED on the content disk
            # rather than installed, and this is the order that proves it.
            $import = @(& $script:commandNamed 'Import-Module')

            $yaml = @($import | Where-Object { $_.Extent.Text -like '*powershell-yaml*' })
            $engine = @($import | Where-Object { $_.Extent.Text -like '*Hephaestus*' })

            $yaml.Count | Should -BeGreaterOrEqual 1
            $engine.Count | Should -BeGreaterOrEqual 1

            $yaml[0].Extent.StartOffset | Should -BeLessThan $engine[0].Extent.StartOffset
        }

        It 'logs the version of each module it loaded' {
            # THE WinPE DEPENDENCY PROOF. Whether powershell-yaml loads inside
            # WinPE had never been tested before 04-04, and a run that does not
            # record which version loaded cannot answer the question afterwards.
            $script:text | Should -BeLike '*yamlVersion*'
            $script:text | Should -BeLike '*engineVersion*'
        }

        It 'puts the content disk Modules folder on PSModulePath' {
            $script:text | Should -BeLike '*PSModulePath*'
        }

        It 'scans for the content drive rather than assuming a letter' {
            # WinPE's drive letter assignment is not guaranteed.
            $script:text | Should -Match "'C', 'D', 'E'"
        }
    }

    Context 'what it builds and what it hands the loop' {

        It 'builds the real service adapters' {
            foreach ($name in @('New-HDTFileSystem', 'New-HDTClock', 'New-HDTDiskService',
                    'New-HDTImageService', 'New-HDTRegistryService', 'New-HDTEnvironmentProvider',
                    'New-HDTCimProvider', 'New-HDTProcessService', 'New-HDTPowerService',
                    'New-HDTScriptInvoker', 'New-HDTServiceCatalog')) {

                @(& $script:commandNamed $name).Count | Should -BeGreaterOrEqual 1 -Because "the launcher has to build $name"
            }
        }

        It 'gathers facts and resolves variables' {
            @(& $script:commandNamed 'Get-HDTMachineFact').Count | Should -Be 1
            @(& $script:commandNamed 'Resolve-HDTVariable').Count | Should -Be 1
        }

        It 'imports the sequence and the rules through the engine' {
            @(& $script:commandNamed 'Import-HDTSequenceDocument').Count | Should -Be 1
            @(& $script:commandNamed 'Import-HDTRuleDocument').Count | Should -Be 1
        }

        It 'builds a log context, a run state and an execution context' {
            @(& $script:commandNamed 'New-HDTLogContext').Count | Should -Be 1
            @(& $script:commandNamed 'New-HDTRunState').Count | Should -Be 1
            @(& $script:commandNamed 'New-HDTExecutionContext').Count | Should -Be 1
        }

        It 'builds every workspace path through Get-HDTWorkspacePath' {
            # The harness stages the layout by hand; the engine reading it uses
            # the one owner of that layout. This is the assertion that keeps the
            # two agreeing.
            @(& $script:commandNamed 'Get-HDTWorkspacePath').Count | Should -BeGreaterOrEqual 1
            $script:text | Should -Not -Match "'TaskSequences'"
        }

        It 'passes -LogDestination so the log survives the shutdown' {
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            @($loop.CommandElements | ForEach-Object { $_.Extent.Text }) | Should -Contain '-LogDestination'
        }

        It 'passes -State to the loop' {
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            @($loop.CommandElements | ForEach-Object { $_.Extent.Text }) | Should -Contain '-State'
        }
    }

    Context 'how the harness knows the run ended' {

        It 'writes a RESULT.json' {
            $script:text | Should -BeLike '*RESULT.json*'
        }

        It 'writes it as UTF-8 without a BOM' {
            # SPIKES S6's third finding: the default under 5.1 is UTF-16, which
            # half the tooling cannot read.
            $script:text | Should -BeLike '*UTF8Encoding*'
        }

        It 'shuts the machine down at the end' {
            $script:text | Should -BeLike '*wpeutil*'
            $script:text | Should -BeLike '*shutdown*'
        }

        It 'shuts down even when the run threw' {
            # A VM left at a WinPE prompt tells the harness nothing except that
            # its timeout expired. The shutdown is AFTER the catch, not inside
            # the try.
            $shutdown = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.Extent.Text) -like '*wpeutil*'
                    }, $true))

            $shutdown.Count | Should -BeGreaterOrEqual 1

            $try = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)

            $last = @($shutdown | Sort-Object { $_.Extent.StartOffset })[-1]

            $last.Extent.StartOffset | Should -BeGreaterThan $try[0].Extent.EndOffset
        }
    }
}

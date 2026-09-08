#Requires -Modules Pester

# THE GATE NOW RUNS ON A MACHINE HDT DEPLOYED, SO NO TEST MAY ASSUME OTHERWISE.
#
# The first CI run on GHRUNNER01 failed on exactly one test:
#
#   Expected $false, because C:\HDT\Logs\HDT.jsonl exists only inside the fake,
#   but got $true.
#
# Nothing was wrong with the code. GHRUNNER01 was itself deployed by HDT, zero
# touch from the lab share (.planning/PROJECT.md, "GHRUNNER01"), so C:\HDT\Logs
# there holds the log of the deployment that BUILT it - HDT.jsonl, HDT.log,
# state.json, Steps\, all written on 2026-09-07 by run-20260907-072951. The
# suite was green on the author's laptop and red on the runner FOR BEING A
# RUNNER, which is the defect fb3ef00 fixed once already in the lab-safety
# guards, in a different disguise.
#
# THE MECHANISM WAS WRONG, NOT THE INTENT. "This fake-driven run wrote nothing
# real" is worth asserting: a step that reached past its injected service and
# called Set-Content itself would leave the journal spotless and the disk
# changed. What cannot carry that claim is the ABSENCE of a path, because
# absence is a fact about the machine and HDT's own paths belong to any machine
# HDT has touched. The honest proof is a reading taken before the run and
# compared after - Get-HDTRealMachineState, which is what those suites use now.
#
# SO THE RULE IS WRITTEN AGAINST THE CLASS, NOT AGAINST THE ONE THAT FAILED.
# What is refused is a fake-driven test reaching for HDT'S OWN FOOTPRINT on the
# real machine at all, by any cmdlet and in either direction: <drive>:\HDT\,
# C:\Windows\Logs\HDT, HKLM:\SOFTWARE\Hephaestus, the Winlogon and RunOnce keys
# autologon is armed in, and MININT. Every one of them exists on a deployed
# machine, and three of them exist on a machine that is mid-deployment.
#
# tests/unit AND tests/contract ONLY. tests/integration and tests/e2e read the
# real machine BECAUSE THAT IS WHAT THEY TEST - they mount images, deploy VMs
# and then assert what landed - and a rule that refused them the real registry
# would be refusing them their subject. The rule is for the suites whose whole
# claim is that they never leave the fakes.
#
# A PATH BUILT FROM A VARIABLE IS NOT CAUGHT, and that is the honest limit of an
# AST rule: this reads literal arguments, the way PhaseLiteral does. The suites
# it exists for spell their paths out.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # HDT's own marks on a machine it has deployed, or is deploying.
    #
    #   <drive>:\HDT\             the log and staging root - Get-HDTLogPath
    #                             returns <SystemDrive>\HDT\Logs in the full OS
    #                             and X:\HDT\Logs in WinPE
    #   \Windows\Logs\HDT         where Invoke-HDTTaskSequence copies the run
    #   HKLM:\SOFTWARE\Hephaestus the tattoo
    #   Winlogon, RunOnce         the two keys autologon is armed and torn down
    #                             in - a machine mid-deployment carries values
    #                             in both, and so does any machine an admin has
    #                             ever set autologon on by hand
    #   <drive>:\MININT           the resume agent's staging directory
    $script:footprintPattern = @(
        '(?i)[a-z]:\\HDT\\',
        '(?i)\\Windows\\Logs\\HDT',
        '(?i)HKLM:\\SOFTWARE\\Hephaestus',
        '(?i)\\CurrentVersion\\Winlogon',
        '(?i)\\CurrentVersion\\RunOnce',
        '(?i)[a-z]:\\MININT'
    )

    # Every cmdlet that reaches the real machine through a path, reading or
    # writing. Get-HDTRealMachineState is deliberately NOT here: it is the tool
    # that makes the claim provable, and it returns a reading rather than an
    # assertion about what the machine ought to hold.
    $script:realMachineCommand = @(
        'Test-Path', 'Get-Item', 'Get-ChildItem', 'Get-Content',
        'Get-ItemProperty', 'Get-ItemPropertyValue',
        'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item',
        'Copy-Item', 'Move-Item', 'Rename-Item',
        'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty'
    )

    # THE SCANNER, shared by the assertion and by the bait below so that both
    # judge with the same code.
    $script:findFootprintUse = {
        param([string[]] $File)

        $found = New-Object -TypeName System.Collections.ArrayList

        foreach ($item in @($File)) {
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item, [ref] $token, [ref] $null)

            $command = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true))

            foreach ($current in $command) {
                $name = $current.GetCommandName()
                if ([string]::IsNullOrEmpty($name)) { continue }
                if ($script:realMachineCommand -notcontains $name) { continue }

                foreach ($element in @($current.CommandElements)) {
                    $text = ''
                    if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $text = [string] $element.Value
                    } elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                        $text = [string] $element.Value
                    }

                    if ([string]::IsNullOrEmpty($text)) { continue }

                    foreach ($pattern in $script:footprintPattern) {
                        if ($text -match $pattern) {
                            [void] $found.Add([pscustomobject] @{
                                    Path    = $item
                                    Line    = $element.Extent.StartLineNumber
                                    Command = $name
                                    Literal = $text
                                })

                            break
                        }
                    }
                }
            }
        }

        return @($found | Sort-Object -Property Path, Line)
    }

    $script:fakeDrivenFile = @(
        foreach ($suite in @('tests/unit', 'tests/contract')) {
            $path = Join-Path -Path $script:repoRoot -ChildPath $suite
            if (Test-Path -LiteralPath $path -PathType Container) {
                Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse |
                    ForEach-Object { $_.FullName }
            }
        }
    )
}

Describe 'no fake-driven test reaches for HDT''s own footprint on the real machine' {

    It 'finds every suite to judge' {
        # A contract that scans nothing passes for the wrong reason
        # (tests/helpers/README.md section 12), and @($null).Count is 1, so the
        # set is named as well as counted.
        @($script:fakeDrivenFile).Count | Should -BeGreaterThan 400

        $name = @($script:fakeDrivenFile | ForEach-Object { Split-Path -Leaf $_ })
        $name | Should -Contain 'TaskSequence.EndToEnd.Tests.ps1'
        $name | Should -Contain 'Imaging.EndToEnd.Tests.ps1'
        $name | Should -Contain 'GatherAndResolve.EndToEnd.Tests.ps1'
        $name | Should -Contain 'Naming.Contract.Tests.ps1'
    }

    It 'reports no use across tests/unit and tests/contract' {
        $use = @(& $script:findFootprintUse $script:fakeDrivenFile)

        $detail = ($use | ForEach-Object { '{0}({1}): {2} {3}' -f $_.Path, $_.Line, $_.Command, $_.Literal }) -join "`n"

        $use.Count | Should -Be 0 -Because (
            "the machine running this gate was deployed by HDT, so C:\HDT\Logs, the Winlogon " +
            "autologon values and the tattoo key are ITS OWN and exist there. A fake-driven " +
            "test that reads them is asserting a fact about the machine. Take a reading with " +
            "Get-HDTRealMachineState before the run and compare it after.`n" + $detail)
    }

    It 'still bites on the deliberate fixture' {
        $bait = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/footprint/FootprintAbsenceAssertion.ps1'

        $use = @(& $script:findFootprintUse $bait)

        # Asserted on what it named rather than on a count alone: @($null).Count
        # is 1, so a count would pass for a scanner that returned nothing.
        @($use | ForEach-Object { $_.Command }) | Should -Contain 'Test-Path'
        @($use | ForEach-Object { $_.Command }) | Should -Contain 'Get-ItemProperty'
        @($use | ForEach-Object { $_.Literal }) | Should -Contain 'C:\HDT\Logs\HDT.jsonl'
    }

    It 'lets a reading through, because a reading is the fix' {
        # The shape the suites use now must not be what the scanner refuses,
        # or the rule would have no permitted way to make the claim.
        $file = Join-Path -Path $script:repoRoot -ChildPath 'tests/unit/TaskSequence.EndToEnd.Tests.ps1'

        $body = Get-Content -LiteralPath $file -Raw

        $body | Should -BeLike '*Get-HDTRealMachineState*' -Because 'the suite proves it with a before-and-after reading'
        @(& $script:findFootprintUse $file).Count | Should -Be 0
    }
}

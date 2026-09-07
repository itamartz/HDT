#Requires -Modules Pester

# A FILE THAT DERIVES ITS OWN WORLD MAY NOT ALSO ASSERT ONE.
#
# tests/contract/PowerService.Contract.Tests.ps1 wrote this rule for exactly one
# decision: which -Environment a New-HDTPowerService call is handed. It caught
# the defect it was written for and it caught nothing else, because
# Start-HDTDeployment.ps1 was making the SAME environment-shaped decision in
# three more places and each one was spelled differently:
#
#   Get-HDTFinishAction -Environment WinPE          a parameter, like the power one
#   'wpeutil {0}' -f $ending                        a string naming a WinPE-only exe
#   & "$env:SystemRoot\System32\wpeutil.exe" ...    a command that is not in Windows
#   X:\HDT\RESULT.json                              a path rooted on the RAM disk
#
# Every one of them is the same mistake - a run that CAN start on either leg
# saying which leg it is - and none of them looks like the others, so a rule
# written against the shape of the first would have missed all three. This file
# is written against the CLASS: what a phase-deriving file may not contain,
# whatever spelling somebody reaches for next.
#
# THE TRIGGER IS Get-HDTDeploymentPhase, NOT A LIST OF FILENAMES. A file that
# asks which leg it is on can be started on either, so nothing in it may claim
# to know; a file that never asks has one world by construction - the boot
# payload launchers are single-world because startnet.cmd is the only thing that
# runs them - and a literal is the honest answer there. Written this way, a file
# that starts deriving a phase tomorrow is judged from the moment it does.
#
# A COMPARISON IS NOT AN ASSERTION. `if ($endingPhase -eq 'WinPE')` names a
# world in order to BRANCH on the derived value, which is the correct shape and
# the only one that can serve both legs. What is refused is naming a world where
# a value should have been carried: a parameter argument, an executable, a path.
#
# BOTH SIDES ARE ASSERTED NON-EMPTY. A set-driven rule that matches nothing
# passes forever, and this one is looking for the absence of a literal.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # The two worlds, and the executables that exist in exactly one of them.
    # SPIKES/05-06 mounted the boot image: shutdown.exe is ABSENT from WinPE and
    # wpeutil.exe is absent from every installed Windows.
    $script:worldName = @('WinPE', 'FullOS')
    $script:worldOnlyExecutable = @('wpeutil', 'shutdown.exe')

    # -Environment and -Phase are the two parameter names in this module that
    # take a world. Anything else that grows one is caught by the reviewer, not
    # by this file, and that is the honest limit of an AST rule.
    $script:worldParameter = @('Environment', 'Phase')

    $script:file = @()

    foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') -Filter '*.ps1' -Recurse -File |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })) {

        $token = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref] $token, [ref] $null)

        # COMMENTS ARE NOT IN THE AST, AND THAT IS THE POINT. Half this module's
        # comment-based help carries `Get-HDTLogPath -Phase WinPE` as an EXAMPLE,
        # and a raw text scan would fail on the documentation rather than on the
        # code - which teaches the next author to delete the example.
        $derives = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-HDTDeploymentPhase'
                }, $true)).Count -gt 0

        # THE PARAMETER BLOCK IS JUDGED SEPARATELY, and the last Describe in this
        # file says why: Start-HDTDeployment.ps1 defaults its paths to X: because
        # WinPE is where it was written to run, and what makes that safe is not
        # the default but the full-OS launcher answering every one of them.
        $statement = @()
        if ($null -ne $ast.EndBlock) { $statement += @($ast.EndBlock.Statements) }
        if ($null -ne $ast.BeginBlock) { $statement += @($ast.BeginBlock.Statements) }
        if ($null -ne $ast.ProcessBlock) { $statement += @($ast.ProcessBlock.Statements) }

        $literalWorldArgument = @()
        $worldExecutable = @()
        $ramDiskPath = @()

        foreach ($node in $statement) {

            foreach ($command in $node.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {

                $element = @($command.CommandElements)

                for ($i = 0; $i -lt $element.Count - 1; $i++) {
                    if (-not ($element[$i] -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                    if ($script:worldParameter -notcontains $element[$i].ParameterName) { continue }

                    $argument = $element[$i + 1]

                    if ($argument -is [System.Management.Automation.Language.VariableExpressionAst]) { continue }

                    $text = ([string] $argument.Extent.Text).Trim("'`"")
                    if ($script:worldName -notcontains $text) { continue }

                    $literalWorldArgument += ('{0}:{1} {2} -{3} {4}' -f
                        $item.Name, $argument.Extent.StartLineNumber, $command.GetCommandName(),
                        $element[$i].ParameterName, $text)
                }
            }

            foreach ($string in $node.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {

                $value = [string] $string.Extent.Text

                foreach ($executable in $script:worldOnlyExecutable) {
                    if ($value -like ('*{0}*' -f $executable)) {

                        # INSIDE A BRANCH ON THE DERIVED PHASE IS THE CORRECT
                        # SHAPE, and the only one that can serve both legs. The
                        # tail of Start-HDTDeployment.ps1 runs after the catch,
                        # on a machine that may have failed before the module
                        # imported, so it cannot ask Get-HDTPowerCommand - it
                        # carries the two plans itself, one per branch, and an
                        # anti-drift test compares them with the engine's.
                        $guarded = $false
                        $walk = $string.Parent

                        while ($null -ne $walk) {
                            if ($walk -is [System.Management.Automation.Language.IfStatementAst]) {
                                foreach ($clause in $walk.Clauses) {
                                    if (([string] $clause.Item1.Extent.Text) -match '(?i)phase') { $guarded = $true }
                                }
                            }

                            $walk = $walk.Parent
                        }

                        if (-not $guarded) {
                            $worldExecutable += ('{0}:{1} {2}' -f $item.Name, $string.Extent.StartLineNumber, $value)
                        }
                    }
                }

                # A PATH ROOTED ON THE RAM DISK, not a sentence that mentions
                # one. Get-HDTRefreshLaunchPlan's refusal tells the operator
                # "startnet.cmd launches X:\HDT\Start-HDTDeployment.ps1", which
                # is prose about the other leg and is exactly right; what is
                # refused is a value the code then opens.
                if (($value.Trim("'`"")) -match '^[Xx]:[\\/]') {
                    $ramDiskPath += ('{0}:{1} {2}' -f $item.Name, $string.Extent.StartLineNumber, $value)
                }
            }
        }

        $script:file += [pscustomobject] @{
            Name                 = $item.Name
            Derives              = $derives
            LiteralWorldArgument = $literalWorldArgument
            WorldExecutable      = $worldExecutable
            RamDiskPath          = $ramDiskPath
        }
    }

    $script:deriving = @($script:file | Where-Object { $_.Derives })
    $script:singleWorld = @($script:file | Where-Object { -not $_.Derives })
}

Describe 'a file that derives its deployment phase keeps no literal about which world it is in' {

    It 'finds files that derive a phase at all' {
        @($script:deriving).Count | Should -BeGreaterOrEqual 2 -Because (
            'Start-HDTDeployment.ps1 and Get-HDTRefreshLaunchPlan.ps1 both ask Get-HDTDeploymentPhase, ' +
            'and a set-driven rule that matches nothing passes forever')
    }

    It 'finds single-world files still holding their literals' {
        # THE OTHER SIDE OF THE RULE, asserted so that a mistake in the AST walk
        # cannot make this whole file vacuous. Get-HDTPowerCommand.ps1 names both
        # executables and Import-HDTBootCertificate.ps1 defaults to X:\HDT\ -
        # neither derives a phase, and both are right to.
        $carrying = @($script:singleWorld | Where-Object {
                @($_.WorldExecutable).Count -gt 0 -or @($_.RamDiskPath).Count -gt 0 -or
                @($_.LiteralWorldArgument).Count -gt 0
            })

        @($carrying).Count | Should -BeGreaterOrEqual 1 -Because (
            'a file with one world by construction keeps its literal, and this rule must be able to see one')
    }

    It 'passes no literal world to a command that takes one' {
        $offender = @($script:deriving | ForEach-Object { $_.LiteralWorldArgument })

        $offender | Should -BeNullOrEmpty -Because (
            'a run that can start on either leg must carry the phase it derived, and these name one: {0}' -f
            ($offender -join '; '))
    }

    It 'names no world-only executable outside a branch on the derived phase' {
        $offender = @($script:deriving | ForEach-Object { $_.WorldExecutable })

        $offender | Should -BeNullOrEmpty -Because (
            'wpeutil is not in Windows and shutdown.exe is not in WinPE, so an unguarded one is a command the other leg does not have: {0}' -f
            ($offender -join '; '))
    }

    It 'opens no path rooted on the WinPE RAM disk' {
        $offender = @($script:deriving | ForEach-Object { $_.RamDiskPath })

        $offender | Should -BeNullOrEmpty -Because (
            'X: is a RAM disk that only exists on the WinPE leg, and does not exist at all on a Refresh: {0}' -f
            ($offender -join '; '))
    }
}

Describe 'every X: parameter default the payload declares is answered on the full-OS leg' {

    # WHAT THIS USED TO BE AND WHY IT CHANGED. It froze the set at eight names so
    # a ninth could not join quietly - a freeze on a known gap rather than a pass
    # mark, because six of those eight were XAML paths that nothing on the full-OS
    # leg overrode. Get-HDTRefreshLaunchPlan passed -BootstrapPath and -ModuleRoot
    # and stopped there, so a Refresh inherited X:\HDT\UI\*.xaml on a machine with
    # no X: at all and every window it draws - wizard, progress, failure, welcome,
    # boot status - had no file to load.
    #
    # THE GAP IS CLOSED, SO THE RULE IS THE REAL ONE NOW. An X:-rooted DEFAULT is
    # legal and stays: WinPE is the leg this payload was written for,
    # Update-HDTBootImage genuinely stages those paths onto the RAM disk, and its
    # letter is fixed. What is not legal is one the full-OS launcher leaves
    # unanswered.
    #
    # AND BOTH SIDES ARE DERIVED, WHICH IS THE WHOLE POINT. The X: set is read off
    # the payload's own param block. The answers are read off a plan a REAL
    # Get-HDTRefreshLaunchPlan produced against a fake share carrying the REAL
    # payload - the parameters the launcher template names on its handover line,
    # plus the keys of the splat that plan hands it. Neither side is a list in
    # this file, so a ninth default added tomorrow is judged the moment it lands
    # and a name deleted from a test cannot hide one.

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'
        $script:payloadText = [System.IO.File]::ReadAllText($payloadPath)

        $payload = [System.Management.Automation.Language.Parser]::ParseInput($script:payloadText, [ref] $null, [ref] $null)

        $script:ramDiskDefault = @()

        foreach ($parameter in @($payload.ParamBlock.Parameters)) {
            if ($null -eq $parameter.DefaultValue) { continue }

            if ((([string] $parameter.DefaultValue.Extent.Text).Trim("'`"")) -match '^[Xx]:[\\/]') {
                $script:ramDiskDefault += [string] $parameter.Name.VariablePath.UserPath
            }
        }

        # THE SHARE IS ON Q:, A DRIVE THIS SESSION HAS NOT MOUNTED, for the reason
        # the launcher's own tests give: a line that reached Join-Path instead of
        # [IO.Path]::Combine would throw DriveNotFound rather than answer.
        $fileSystem = New-HDTFakeFileSystem -File @{
            'Q:\Share\rules.yaml'     = "schemaVersion: 1`nrules: []`n"
            'Q:\Share\workspace.yaml' = "schemaVersion: 1`nid: HDT-LAB`nname: HDT lab`n"
            ([System.IO.Path]::Combine('Q:\Share', 'Modules', 'Hephaestus', 'Payload', 'Start-HDTDeployment.ps1')) = $script:payloadText
        }

        $script:plan = Get-HDTRefreshLaunchPlan -ScriptRoot 'Q:\Share\Scripts' -SystemDrive 'C:' `
            -IsElevated $true -FileSystem $fileSystem

        # THE PARAMETERS THE LAUNCHER NAMES ITSELF, read off the template's
        # handover line rather than written out here. The splat on that same line
        # is what carries the rest.
        $launcherPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/Launcher/Start-HDTRefresh.ps1'
        $launcher = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref] $null, [ref] $null)

        $handover = @($launcher.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | Where-Object { ([string] $_.Extent.Text) -like '*PayloadPath*' })

        $script:named = @($handover | ForEach-Object { $_.CommandElements } |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { [string] $_.ParameterName })

        $script:answered = @($script:named) + @($script:plan.UiArgument.Keys)
    }

    It 'finds X:-rooted defaults at all' {
        # A SET-DRIVEN RULE THAT MATCHES NOTHING PASSES FOREVER, and this one is
        # checking a set for coverage. Eight is what the payload has today; the
        # floor is what stops the AST walk silently breaking.
        @($script:ramDiskDefault).Count | Should -BeGreaterOrEqual 8 -Because (
            'Start-HDTDeployment.ps1 defaults its bootstrap, its module root and every window it draws to X:')
    }

    It 'finds the launcher answering some of them explicitly' {
        # THE OTHER SIDE, asserted for the same reason: a handover line the AST
        # walk failed to find would make every assertion below vacuous.
        @($script:named).Count | Should -BeGreaterOrEqual 2
        @($script:plan.UiArgument.Keys).Count | Should -BeGreaterOrEqual 6 -Because (
            'six windows default onto the RAM disk and the plan resolves every one of them off the share')
    }

    It 'leaves not one of them for the full-OS leg to inherit' {
        # THE ASSERTION THE DEFECT WAS WORTH. Every X:-rooted default, covered
        # either by a parameter the launcher names or by a key in the splat the
        # plan builds from the payload's own param block.
        $orphan = @($script:ramDiskDefault | Where-Object { $script:answered -notcontains $_ })

        $orphan | Should -BeNullOrEmpty -Because (
            ('these default onto the WinPE RAM disk and nothing answers them on a Refresh, so the machine gets a path with no drive: {0}. ' -f
                ($orphan -join ', ')) +
            'Either the launcher passes it, or - if it is a window - it goes in X:\HDT\UI\ where Get-HDTPayloadUiPath finds it')
    }

    It 'answers each of them with a path that exists on a machine with no RAM disk' {
        $offender = @($script:plan.UiArgument.Values | Where-Object { $_ -match '^[Xx]:[\\/]' })

        $offender | Should -BeNullOrEmpty -Because (
            'the answer to an X: default cannot be another X: path: {0}' -f ($offender -join ', '))

        $script:plan.BootstrapPath | Should -Not -Match '^[Xx]:[\\/]'
        $script:plan.ModuleRoot | Should -Not -Match '^[Xx]:[\\/]'
    }

    It 'reads them out of the engine staged beside the payload it runs' {
        # NOT A NEW STAGING STEP AND NOT A COPY. UI\ ships inside the module
        # folder, -ModuleRoot already points at Modules\, and the launcher has
        # already refused a share with no engine in it - so the screens travel
        # with the engine that draws them and cannot be a version out of step.
        $script:plan.UiRoot | Should -Be 'Q:\Share\Modules\Hephaestus\UI'

        foreach ($value in @($script:plan.UiArgument.Values)) {
            $value | Should -BeLike 'Q:\Share\Modules\Hephaestus\UI\*'
        }
    }
}


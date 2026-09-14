# NO foreach LOOP VARIABLE MAY CARRY THE NAME OF A TYPE-CONSTRAINED PARAMETER
# IN THE SAME SCRIPT BLOCK.
#
# WHAT IT COSTS WHEN ONE DOES, measured rather than imagined. The console's
# Import Windows Update dialog gained a `[string] $Release` parameter so that
# right-clicking a release row could preselect that release. Twenty lines below
# it, the loop that fills the release list was already written
#
#     foreach ($release in @(& $call 'Get-HDTOsRelease' -WorkspaceRoot $Workspace))
#
# and PowerShell variable names are case-insensitive, so those are ONE variable.
# The type constraint declared in the param block does not go away when the loop
# assigns to it: every release object was converted to its string form on the way
# in, and the next line - '[string] $release.Name' - threw "The property 'Name'
# cannot be found on this object" under StrictMode. The dialog could not open at
# all. It was found by opening the window, not by a test, and the release that
# shipped it had a green suite.
#
# WHY THIS IS A CONTRACT AND NOT A LINT PREFERENCE. PSScriptAnalyzer has no rule
# for it, the parser accepts it, and StrictMode turns it into an exception at a
# LINE THAT IS INNOCENT - the property access, never the loop - so the stack
# trace points somewhere the bug is not. Worse, without StrictMode there is no
# exception: the loop simply reads empty strings and the window comes up looking
# right with a list of blanks. It is the exact shape of defect that survives
# review, survives unit tests written against the functions the handler calls,
# and reaches an administrator.
#
# AND THE SECOND HALF IS AS BAD AS THE FIRST. After such a loop the parameter is
# gone - it holds the LAST item, not what the caller passed - so any use of it
# below the loop is reading the wrong value silently. In the case above,
# '$releaseId.IndexOf([string] $Release)' would have searched for the last
# release in the list rather than the one the administrator right-clicked.
#
# WHY IT SCANS EVERY SCRIPT BLOCK AND NOT ONLY FUNCTIONS. The console's windows
# are built out of ScriptMethod blocks and closures, each with its own param
# block, and that is precisely where this happened. A scan of
# FunctionDefinitionAst alone comes back clean on the file that carries the bug.
#
# ANTI-VACUITY. "No file contains X" is trivially true of no files, and
# SPIKES S9.15b records how easily that passes for a result here. So the
# discovery is asserted against a floor - a file count and a count of blocks
# that actually declare typed parameters - before anything is judged.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:moduleRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

    # THE BUNDLE IS GENERATED FROM THE FILES BESIDE IT, so scanning it reports
    # every finding twice and names a line number in a file nobody edits.
    $script:scanned = @(Get-ChildItem -LiteralPath $script:moduleRoot -Filter '*.ps1' -File -Recurse |
            Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

    $script:blockCount = 0
    $script:offence = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in $script:scanned) {
        $token = $null
        $parseError = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref] $token, [ref] $parseError)

        $block = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ScriptBlockAst]
                }, $true))

        foreach ($one in $block) {
            if ($null -eq $one.ParamBlock) { continue }

            # [object] IS NOT A CONSTRAINT WORTH COUNTING. Everything converts
            # to it, so a loop variable that shares its name loses nothing - and
            # the injected-service parameters are all [object], which would make
            # this rule fire on half the engine for no defect at all.
            $typed = @{}

            foreach ($parameter in @($one.ParamBlock.Parameters)) {
                if ($null -eq $parameter.StaticType) { continue }
                if ($parameter.StaticType -eq [object]) { continue }

                $typed[$parameter.Name.VariablePath.UserPath.ToLowerInvariant()] =
                [string] $parameter.StaticType.Name
            }

            if ($typed.Count -eq 0) { continue }

            $script:blockCount = $script:blockCount + 1

            $loop = @($one.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ForEachStatementAst]
                    }, $true))

            foreach ($each in $loop) {
                $name = $each.Variable.VariablePath.UserPath

                if (-not $typed.ContainsKey($name.ToLowerInvariant())) { continue }

                [void] $script:offence.Add(('{0}:{1} - foreach (${2} ...) shadows the [{3}] parameter ${2}' -f
                        $file.FullName.Substring($script:moduleRoot.Length + 1),
                        $each.Extent.StartLineNumber, $name, $typed[$name.ToLowerInvariant()]))
            }
        }
    }
}

Describe 'Typed parameters are never used as loop variables' {

    Context 'the scan itself' {

        It 'read the module' {
            $script:scanned.Count | Should -BeGreaterThan 400
        }

        It 'found script blocks that actually declare typed parameters' {
            # Without this floor the whole file passes on a scan that matched
            # nothing - the vacuous green SPIKES S9.15b warns about.
            $script:blockCount | Should -BeGreaterThan 400
        }
    }

    Context 'the rule' {

        It 'no foreach loop variable carries the name of a typed parameter' {
            # THE WHOLE LIST IS IN THE MESSAGE. A count says one is wrong and
            # leaves whoever reads it to run the scan again by hand.
            $said = ''
            if ($script:offence.Count -gt 0) {
                $said = [System.Environment]::NewLine + (@($script:offence) -join [System.Environment]::NewLine)
            }

            $script:offence.Count | Should -Be 0 -Because ("a loop variable takes its parameter's type constraint, so every item is silently converted on the way in:{0}" -f $said)
        }
    }
}

# THE SECOND HALF OF THE SAME CONTRACT: A PLAIN ASSIGNMENT, NOT A LOOP.
#
# The rule above catches `foreach ($release in ...)` standing on a [string]
# $Release. This catches `$foreground = @{ ... }` standing on a [bool]
# $Foreground - the same collision, reached by the other syntax, and the loop
# scan comes back clean on the file that carries it.
#
# WHAT IT COST, off a real machine in WinPE on 2026-09-14. New-HDTWizardHost's
# Show gained a `[bool] $Foreground` parameter - the caller's opt-in to raising
# a window over the Start menu - and, sixty lines below it, a hashtable holding
# the state its handlers mutate:
#
#     $foreground = @{ Busy = $false; Suppressed = $false; LastUtc = ... }
#
# One variable, and the parameter's type constraint owns the name. The hashtable
# was not stored: it was CONVERTED, and [bool] @{...} is $true. So every
# $foreground['Suppressed'] below it threw
#
#     Unable to index into an object of type System.Boolean.
#
# and the Add_Click handler that does it first has no try/catch - so the FIRST
# PRESS OF ANY BUTTON killed the window. That window is HDTWelcome.xaml, THE
# RECOVERY SCREEN: the one a technician gets when the deployment share cannot be
# reached. A machine that had already lost its share lost the screen it was
# given to fix it, and the run ended. 15,894 green tests, and none of them could
# see it - the line lives inside a WPF click handler, which nothing in Pester
# reaches.
#
# TWO MORE CONSEQUENCES, BOTH SILENT. The two reads in Add_Deactivated ARE
# inside a try/catch, so the Start-menu fix that hashtable was added for had been
# dead since the day it landed, logging a Verbose line nobody reads. And
# `if ($Foreground)` further down was testing a hashtable-turned-$true, so every
# wizard window in WinPE was forcing the foreground - which injects a real
# Escape and a real Alt - onto screens a technician types a computer name into.
# Nobody asked for any of it and nothing failed.
#
# THE RULE IS INVERTED ON PURPOSE. It does not list the scalar types that must
# not receive a collection; a deny-list like that goes stale the moment somebody
# uses a type nobody thought of, and the failure mode of a stale deny-list is a
# defect shipped. It lists the types that CAN hold one and refuses the rest, so
# a parameter declared with a type written tomorrow has to EARN the exemption
# rather than inherit it.
#
# WHAT IS NOT AN OFFENCE. `[object] $FileSystem = New-HDTFileSystem` - the
# injected-service default this engine uses in well over a hundred commands - is
# an assignment to a typed parameter and is entirely correct, because [object]
# holds anything. So are `[string[]] $order = @(...)` and `[scriptblock]
# $Download = { ... }`. Only a SHAPE going into something that cannot hold it is
# refused.

Describe 'Typed parameters are never reassigned a value of another shape' {

    BeforeAll {
        $script:assignRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:assignModuleRoot = Join-Path -Path $script:assignRepoRoot -ChildPath 'src/Hephaestus'

        # THE TYPES THAT MAY RECEIVE A COLLECTION, A HASHTABLE OR A SCRIPTBLOCK.
        # Anything whose name ends in '[]' is an array and is admitted by the
        # scan itself rather than listed here one element type at a time.
        $script:assignContainer = @(
            'object', 'psobject', 'pscustomobject',
            'hashtable', 'ordered', 'idictionary', 'dictionary',
            'array', 'arraylist', 'collection', 'ilist', 'ienumerable',
            'scriptblock', 'xml', 'type'
        )

        function Get-HDTTypedParameterShadow {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([Parameter(Mandatory = $true)] [string] $Path)

            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $Path, [ref] $token, [ref] $parseError)

            $found = New-Object -TypeName System.Collections.ArrayList
            $typedCount = 0

            # EVERY SCOPE THAT OWNS A param BLOCK, NOT EVERY FUNCTION - the same
            # reason the loop scan above gives. The defect was in a
            # ScriptMethod's param block, which is not a FunctionDefinitionAst
            # at all.
            foreach ($block in @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.ScriptBlockAst]
                        }, $true))) {

                if ($null -eq $block.ParamBlock) { continue }

                $typed = @{}
                foreach ($parameter in @($block.ParamBlock.Parameters)) {
                    $declared = ''
                    foreach ($attribute in $parameter.Attributes) {
                        if ($attribute -is [System.Management.Automation.Language.TypeConstraintAst]) {
                            $declared = [string] $attribute.TypeName.Name
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($declared)) { continue }

                    $typed[$parameter.Name.VariablePath.UserPath.ToLowerInvariant()] = $declared
                    $typedCount = $typedCount + 1
                }

                if ($typed.Count -eq 0) { continue }

                foreach ($assignment in @($block.FindAll({
                                param($node)
                                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                            }, $true))) {

                    if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

                    # CASE-INSENSITIVELY, WHICH IS THE WHOLE POINT. $foreground
                    # and $Foreground are one variable; a case-sensitive lookup
                    # here would reproduce the defect rather than catch it.
                    $name = [string] $assignment.Left.VariablePath.UserPath
                    if (-not $typed.ContainsKey($name.ToLowerInvariant())) { continue }

                    $declared = [string] $typed[$name.ToLowerInvariant()]

                    $right = $assignment.Right
                    if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) {
                        $right = $right.Expression
                    }

                    $shape = ''
                    if ($right -is [System.Management.Automation.Language.HashtableAst]) {
                        $shape = 'a hashtable'
                    } elseif ($right -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                        $shape = 'an array'
                    } elseif ($right -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                        $shape = 'an array'
                    } elseif ($right -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $shape = 'a scriptblock'
                    }

                    if ([string]::IsNullOrWhiteSpace($shape)) { continue }

                    $lower = $declared.ToLowerInvariant()
                    if ($lower.EndsWith('[]')) { continue }
                    if ($script:assignContainer -contains $lower) { continue }

                    [void] $found.Add([pscustomobject] @{
                            Line     = [int] $assignment.Extent.StartLineNumber
                            Variable = $name
                            Declared = $declared
                            Shape    = $shape
                        })
                }
            }

            return [pscustomobject] @{ Shadow = @($found); TypedParameter = $typedCount }
        }

        # A SAMPLE, PARSED FROM DISK because ParseFile is what the scan uses.
        # The detector has to be shown catching something and shown leaving
        # something alone; one only ever run against a clean tree is one nobody
        # has watched work, and it stays green when it stops working.
        function Test-HDTShadowSample {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes one scratch file it created and removes it in the same call.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([Parameter(Mandatory = $true)] [string] $Source)

            $sample = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(), ('HDTShadowSample-{0}.ps1' -f [guid]::NewGuid()))

            try {
                [System.IO.File]::WriteAllText($sample, $Source)
                return Get-HDTTypedParameterShadow -Path $sample
            } finally {
                # BY LITERAL PATH, AND IT IS A PATH THIS CALL CREATED - CLAUDE.md
                # on what code here may remove.
                Remove-Item -LiteralPath $sample -Force -ErrorAction SilentlyContinue
            }
        }

        $script:assignScanned = @(Get-ChildItem -LiteralPath $script:assignModuleRoot -Filter '*.ps1' -File -Recurse |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

        $script:assignOffence = New-Object -TypeName System.Collections.ArrayList
        $script:assignTypedCount = 0

        foreach ($file in $script:assignScanned) {
            $verdict = Get-HDTTypedParameterShadow -Path $file.FullName
            $script:assignTypedCount = $script:assignTypedCount + [int] $verdict.TypedParameter

            foreach ($shadow in @($verdict.Shadow)) {
                [void] $script:assignOffence.Add(('{0}:{1} - ${2} is declared [{3}] and is reassigned {4}' -f
                        $file.FullName.Substring($script:assignModuleRoot.Length + 1),
                        $shadow.Line, $shadow.Variable, $shadow.Declared, $shadow.Shape))
            }
        }
    }

    Context 'the scan itself' {

        It 'read the module' {
            $script:assignScanned.Count | Should -BeGreaterThan 400
        }

        It 'found typed parameters to judge' {
            $script:assignTypedCount | Should -BeGreaterThan 400
        }
    }

    Context 'the detector' {

        It 'catches the shape that crashed the Welcome screen' {
            $verdict = Test-HDTShadowSample -Source @'
function Test-HDTSampleOffender {
    param([bool] $Foreground)
    $foreground = @{ Busy = $false }
    $foreground['Busy'] = $true
}
'@

            @($verdict.Shadow).Count | Should -Be 1
            [string] @($verdict.Shadow)[0].Variable | Should -BeExactly 'foreground'
            [string] @($verdict.Shadow)[0].Declared | Should -BeExactly 'bool'
        }

        It 'catches it inside a script method, which is where it actually happened' {
            $verdict = Test-HDTShadowSample -Source @'
function New-HDTSampleService {
    $service = [pscustomobject] @{ Answer = '' }
    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        param([string] $Title, [bool] $Foreground)
        $foreground = @{ Suppressed = $false }
        $foreground['Suppressed'] = $true
    }
    return $service
}
'@

            @($verdict.Shadow).Count | Should -Be 1
        }

        It 'leaves the injected-service default and the honest reassignments alone' {
            $verdict = Test-HDTShadowSample -Source @'
function Test-HDTSampleInnocent {
    param([object] $FileSystem, [string[]] $Order, [scriptblock] $Probe, [hashtable] $Map)
    if ($null -eq $FileSystem) { $FileSystem = @{ Kind = 'fake' } }
    $Order = @('a', 'b')
    $Probe = { 'ok' }
    $Map = @{ One = 1 }
}
'@

            @($verdict.Shadow).Count | Should -Be 0
        }
    }

    Context 'the rule' {

        It 'no typed parameter name is reassigned a collection, a hashtable or a scriptblock' {
            # THE WHOLE LIST IS IN THE MESSAGE, for the same reason the loop rule
            # above gives: a count says one is wrong and leaves whoever reads it
            # to run the scan again by hand.
            $said = ''
            if ($script:assignOffence.Count -gt 0) {
                $said = [System.Environment]::NewLine + (@($script:assignOffence) -join [System.Environment]::NewLine)
            }

            $script:assignOffence.Count | Should -Be 0 -Because ("a parameter's type constraint stays attached to its name, so the value is silently converted - a hashtable converted to bool is always true - and every later index into it throws 'Unable to index into an object of type System.Boolean.':{0}" -f $said)
        }
    }
}

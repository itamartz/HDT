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

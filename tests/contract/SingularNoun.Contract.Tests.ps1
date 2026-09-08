# Catches the class of PSScriptAnalyzer finding the 5.1 gate structurally cannot
# see: PSUseSingularNouns verdicts that differ between PowerShell editions.
#
# WHY THIS EXISTS. PSScriptAnalyzer 1.25.0 is ONE module version that ships TWO
# copies of the rule assembly, and they do not pluralise with the same engine:
#
#   <module>\Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules.dll
#       loaded by Windows PowerShell; pluralises with .NET Framework's
#       System.Data.Entity.Design.PluralizationServices
#
#   <module>\PSv7\Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules.dll
#       loaded by PowerShell 7; pluralises with the bundled Pluralize.NET.dll
#
# They disagree IN BOTH DIRECTIONS. PluralizationServices calls Media the plural
# of Medium and says nothing about Metadata; Pluralize.NET singularises Metadata
# to Metadatum and treats Media as already singular. So a name can be clean on
# 5.1 and dirty on 7, which is exactly what happened to
# ConvertFrom-HDTUpdateMetadata: 0 diagnostics on the 5.1 gate, and CI's pwsh leg
# red on the same commit.
#
# THE GATE HERE IS 5.1 AND OSDTEST01 HAS NO pwsh AT ALL, so "run the analyzer
# under the other edition" is not a test this repository can run where it needs
# to run. What it CAN do is load the very pluralizer the PSv7 rule assembly
# carries - Pluralize.NET.dll loads under .NET Framework 4.x as well as Core, and
# it ships in the module directory on BOTH editions - and apply the rule's own
# predicate to every function name in the repository. That runs on the gate's
# edition and reproduces the other edition's verdict.
#
# THE PREDICATE IS THE RULE'S, NOT AN APPROXIMATION OF IT. UseSingularNouns on
# the PSv7 build flags a noun that is `!IsSingular && IsPlural`, which is why
# Media (both singular and plural to Pluralize.NET) is NOT a Core finding while
# Metadata and Wds are. Reproducing the conjunction rather than just IsSingular
# is what keeps this test from inventing violations the analyzer would never
# report.
#
# WHAT IT DOES NOT COVER. It is one rule, not the whole rule set. Any other rule
# whose verdict turns on the edition would still reach CI unseen. The durable
# guard for that is CI's two-leg matrix; this contract exists so the single rule
# that has already cost a red build fails here first, on the edition a developer
# actually runs.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

Describe 'Singular noun contract across PowerShell editions' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

        $script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
        $script:HDTSourceFunction = @(Get-HDTSourceFunction -Path $script:HDTSourceFile)

        # THE PLURALIZER IS THE ANALYZER'S OWN COPY, found by asking the module
        # where it lives rather than by naming a path. It sits under PSv7\ in
        # every PSScriptAnalyzer 1.25.0 install, Desktop and Core alike, because
        # the package carries both rule assemblies regardless of which one the
        # running edition loads.
        $script:HDTPluralizer = $null
        $script:HDTPluralizerReason = ''

        $analyzerModule = @(Get-Module -Name PSScriptAnalyzer -ListAvailable |
                Sort-Object -Property Version -Descending) | Select-Object -First 1

        if ($null -eq $analyzerModule) {
            # The 'test' task deliberately does not require PSScriptAnalyzer -
            # it is not importable under 5.1 on every machine - so this is the
            # same condition under which the lint task does not run either.
            $script:HDTPluralizerReason = 'PSScriptAnalyzer is not installed for this edition, so its pluralizer cannot be borrowed. The lint task does not run here either.'
        }
        else {
            $dll = @(Get-ChildItem -LiteralPath (Split-Path -Parent $analyzerModule.Path) -Recurse -Filter 'Pluralize.NET.dll' -ErrorAction SilentlyContinue) |
                Select-Object -First 1

            if ($null -eq $dll) {
                $script:HDTPluralizerReason = ("PSScriptAnalyzer {0} carries no Pluralize.NET.dll, so the PowerShell 7 pluralizer is not available to borrow." -f $analyzerModule.Version)
            }
            else {
                if (-not ('Pluralize.NET.Pluralizer' -as [type])) {
                    Add-Type -Path $dll.FullName -ErrorAction Stop
                }
                $script:HDTPluralizer = New-Object -TypeName Pluralize.NET.Pluralizer
            }
        }

        # The rule's own predicate. Both halves matter - see the file header.
        function Test-HDTNounIsPlural {
            param(
                [Parameter(Mandatory = $true)] [object] $Pluralizer,
                [Parameter(Mandatory = $true)] [string] $Noun
            )

            return ((-not $Pluralizer.IsSingular($Noun)) -and $Pluralizer.IsPlural($Noun))
        }

        # The noun the rule judges is everything after the first hyphen, with
        # HDT's own prefix removed: the analyzer never sees the prefix as part of
        # the noun on names like Get-HDTMedia, and leaving it on turns every name
        # in the repository into HDT-something.
        function Get-HDTJudgedNoun {
            param(
                [Parameter(Mandatory = $true)] [string] $Name
            )

            if ($Name -notmatch '^[A-Za-z]+-(.+)$') {
                return ''
            }

            $noun = $Matches[1]
            if ($noun -cmatch '^HDT') {
                $noun = $noun.Substring(3)
            }

            return $noun
        }

        # A function carries the suppression when its param block does. That is
        # where PSScriptAnalyzer looks for a function-scoped [SuppressMessage],
        # and it is where every existing one in this repository sits.
        function Get-HDTSuppressedSingularNounName {
            param(
                [Parameter(Mandatory = $true)] [string[]] $Path
            )

            $suppressed = New-Object -TypeName System.Collections.ArrayList

            foreach ($item in $Path) {
                $token = $null
                $parseError = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($item, [ref] $token, [ref] $parseError)

                if (@($parseError).Count -gt 0) {
                    $first = @($parseError)[0]
                    throw ("Parse error in '{0}' at line {1}: {2}" -f $item, $first.Extent.StartLineNumber, $first.Message)
                }

                $definition = @($ast.FindAll({ $args[0].GetType().Name -eq 'FunctionDefinitionAst' }, $true))

                foreach ($function in $definition) {
                    if ($null -eq $function.Body -or $null -eq $function.Body.ParamBlock) {
                        continue
                    }

                    foreach ($attribute in @($function.Body.ParamBlock.Attributes)) {
                        if ($attribute.GetType().Name -ne 'AttributeAst') {
                            continue
                        }
                        if ($attribute.TypeName.Name -notlike '*SuppressMessage*') {
                            continue
                        }

                        $positional = @($attribute.PositionalArguments)
                        if ($positional.Count -lt 1) {
                            continue
                        }
                        if ($positional[0].Extent.Text -notmatch 'PSUseSingularNouns') {
                            continue
                        }

                        [void] $suppressed.Add($function.Name)
                    }
                }
            }

            return [string[]] @($suppressed)
        }
    }

    It 'discovers enough functions for the sweep to mean something' {
        # Anti-vacuity. A contract that silently finds nothing to judge reports
        # green forever.
        $script:HDTSourceFunction.Count | Should -BeGreaterThan 99
    }

    It 'borrows the pluralizer PowerShell 7 judges nouns with' {
        if ($null -eq $script:HDTPluralizer) {
            Set-ItResult -Skipped -Because $script:HDTPluralizerReason
            return
        }

        # Anti-vacuity again, and the one case that started this: a pluralizer
        # that answered nothing would make the sweep below pass by not looking.
        # Metadata -> Metadatum is the exact disagreement the 5.1 engine does not
        # have, so if this stops holding the borrowed engine has changed and the
        # sweep is no longer reproducing PowerShell 7's verdict.
        $script:HDTPluralizer.Singularize('Metadata') | Should -Be 'Metadatum'
    }

    It 'suppresses PSUseSingularNouns on every name PowerShell 7 would call plural' {
        if ($null -eq $script:HDTPluralizer) {
            Set-ItResult -Skipped -Because $script:HDTPluralizerReason
            return
        }

        $suppressed = @(Get-HDTSuppressedSingularNounName -Path $script:HDTSourceFile)

        $violation = @(
            foreach ($function in $script:HDTSourceFunction) {
                $noun = Get-HDTJudgedNoun -Name $function.Name
                if ($noun.Length -eq 0) {
                    continue
                }
                if (-not (Test-HDTNounIsPlural -Pluralizer $script:HDTPluralizer -Noun $noun)) {
                    continue
                }
                if ($suppressed -contains $function.Name) {
                    continue
                }

                '{0} ({1}, noun "{2}" -> "{3}") at {4}:{5}' -f $function.Name,
                'PSUseSingularNouns fires on PowerShell 7 only',
                $noun,
                $script:HDTPluralizer.Singularize($noun),
                $function.Path,
                $function.Line
            }
        )

        # The message has to say what to do, because the developer reading it is
        # on 5.1 and their own `./build.ps1 lint` was green.
        $violation -join [Environment]::NewLine | Should -BeNullOrEmpty -Because (
            "PSScriptAnalyzer's PowerShell 7 rule assembly reads these nouns as plural and CI's pwsh leg will fail on them, " +
            "while the 5.1 lint task reports nothing. Either rename the command or add " +
            "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = '...')] to its param block, " +
            "saying why the name is right rather than that the rule is noisy"
        )
    }
}

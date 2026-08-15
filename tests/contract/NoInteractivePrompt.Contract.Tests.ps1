# NOTHING THE ENGINE RUNS UNATTENDED MAY STOP AND ASK A PERSON.
#
# WHY THIS IS A CONTRACT AND NOT A STYLE RULE. The engine runs in WinPE, on a
# machine being wiped, with nobody at the keyboard. A cmdlet reached without an
# argument for a mandatory parameter does NOT error there - PowerShell blocks on
# a prompt, and the deployment hangs forever with a half-imaged disk and a
# console nobody is watching. The failure looks like a hung machine, hours after
# the mistake, with nothing in the log to say what happened; the missing
# argument is invisible in every code review because the call site looks fine.
#
# Read-Host is the obvious form of the same defect. The mandatory-parameter form
# is the one that gets written by accident.
#
# THIS IS THE GUARD THE REPOSITORY DID NOT HAVE. Asked whether a rule already
# stopped this, the answer was no: NoKeystroke.Contract.Tests.ps1 forbids an E2E
# TEST typing into a VM, which is a different thing entirely.
#
# WHAT IT DELIBERATELY DOES NOT COVER. A splatted call (@argument) cannot be
# checked from the syntax tree - the hashtable is built at runtime - so those are
# counted and reported rather than failed, which keeps the number visible instead
# of letting it grow silently.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # THE INTERACTIVE PATH IS ONE FILE AND IT IS NAMED HERE. Start-HDTDeployment
    # asks for a credential when the share has none and the image said to prompt
    # - that is a person at a keyboard in front of a wizard, which is the one
    # place in the product where asking is the correct behaviour. Naming it
    # means adding a second such file is a decision somebody has to write down.
    $script:promptAllowed = @(
        'Start-HDTDeployment.ps1'
    )

    $script:engineFile = @(
        Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') `
            -Filter '*.ps1' -Recurse -File
    )

    # Every HDT command the engine exposes, with the parameters it will block on
    # - PER PARAMETER SET, because satisfying ONE set is what PowerShell asks
    # for. Get-HDTAdkPath takes either -Asset or -All, and a guard that demanded
    # the union of every set reported the correct call
    # 'Get-HDTAdkPath -Asset Oscdimg' as missing -All. Found by running this
    # against the repository, which is what a contract test is for.
    $script:mandatory = @{}

    foreach ($command in @(Get-Command -Module 'Hephaestus' -CommandType Function)) {
        $set = @()

        foreach ($current in @($command.ParameterSets)) {
            $required = @($current.Parameters |
                    Where-Object { $_.IsMandatory } |
                    ForEach-Object { [string] $_.Name })

            $set = $set + , ([string[]] @($required))
        }

        # A command with a set that needs nothing can never block.
        $blocking = @($set | Where-Object { @($_).Count -gt 0 })

        if (@($blocking).Count -gt 0 -and @($blocking).Count -eq @($set).Count) {
            $script:mandatory[[string] $command.Name] = $set
        }
    }

    # THE SYNTAX TREE, NOT A REGEX. A text scan cannot tell code from
    # documentation: Set-HDTShareCredential's own .EXAMPLE block shows
    # `-Credential (Get-Credential)`, which is exactly the line an administrator
    # should type and exactly what a regex reports as a violation. The first
    # version of this file failed on that, which is the right moment to find it.
    function Get-HDTCommandCallName {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string] $Path
        )

        $token = $null
        $parseError = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $token, [ref] $parseError)

        $call = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))

        return [string[]] @($call | ForEach-Object { [string] $_.GetCommandName() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    function Get-HDTUnattendedCallViolation {
        [CmdletBinding()]
        [OutputType([pscustomobject[]])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string] $Path
        )

        $found = New-Object -TypeName System.Collections.ArrayList

        $token = $null
        $parseError = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $token, [ref] $parseError)

        $call = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))

        foreach ($current in $call) {
            $name = [string] $current.GetCommandName()

            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not $script:mandatory.ContainsKey($name)) { continue }

            $element = @($current.CommandElements)

            # A splat cannot be read from the tree; the hashtable is built at
            # runtime. Counted elsewhere, not judged here.
            $splatted = @($element | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $_.Splatted
                })

            if (@($splatted).Count -gt 0) { continue }

            $supplied = @($element |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { [string] $_.ParameterName })

            # A NAMED PARAMETER'S VALUE IS A SEPARATE ELEMENT, and counting it as
            # a positional argument is how the first version of this guard
            # silently passed everything: '-Clock (New-HDTClock)' is two
            # elements, so every named call looked as if it had bare arguments
            # and was skipped as unjudgeable. Proven by planting a violation and
            # watching the guard not fire.
            #
            # An element is consumed as a value when the element before it is a
            # parameter that carries no inline argument of its own (-Clock:$x
            # does, -Clock $x does not).
            $positional = New-Object -TypeName System.Collections.ArrayList

            for ($e = 1; $e -lt $element.Count; $e++) {
                $current = $element[$e]

                if ($current -is [System.Management.Automation.Language.CommandParameterAst]) { continue }

                $previous = $element[$e - 1]

                if ($previous -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $null -eq $previous.Argument) {
                    continue
                }

                [void] $positional.Add($current)
            }

            # A genuinely bare argument may be binding something positionally,
            # and proving which parameter from the tree is guesswork - so a call
            # with one is unjudgeable rather than a violation.
            if (@($positional).Count -gt 0) { continue }

            # SATISFYING ONE PARAMETER SET IS ENOUGH, which is all PowerShell
            # asks for.
            $missing = $null

            foreach ($set in $script:mandatory[$name]) {
                $absent = @($set | Where-Object {
                        $parameter = $_

                        # PowerShell accepts an unambiguous prefix, so -FileSys
                        # binds -FileSystem. Matching on prefix is what the
                        # shell does.
                        @($supplied | Where-Object { $parameter -like ($_ + '*') }).Count -eq 0
                    })

                if (@($absent).Count -eq 0) {
                    $missing = $null
                    break
                }

                if ($null -eq $missing) { $missing = $absent }
            }

            if ($null -ne $missing) {
                [void] $found.Add([pscustomobject] @{
                        File      = Split-Path -Leaf $Path
                        Line      = $current.Extent.StartLineNumber
                        Command   = $name
                        Parameter = (@($missing) -join ', ')
                    })
            }
        }

        return [pscustomobject[]] @($found)
    }
}

Describe 'the engine never stops and asks a person' {

    Context 'Read-Host and its relatives' {

        It 'never calls <Command>, which blocks forever on a machine with nobody at it' -ForEach @(
            @{ Command = 'Read-Host' }
            @{ Command = 'Pause' }
        ) {
            $offender = @($script:engineFile | Where-Object {
                    (Get-HDTCommandCallName -Path $_.FullName) -contains $Command
                } | ForEach-Object { $_.Name })

            ($offender -join ', ') | Should -BeExactly ''
        }

        It 'does not use PromptForChoice, which blocks the same way' {
            # A method on $Host.UI rather than a command, so this one IS a text
            # scan - but of the syntax the parser kept, not of help blocks.
            $offender = @($script:engineFile | Where-Object {
                    $token = $null
                    $parseError = $null
                    [void] [System.Management.Automation.Language.Parser]::ParseFile(
                        $_.FullName, [ref] $token, [ref] $parseError)

                    @($token | Where-Object { $_.Text -eq 'PromptForChoice' }).Count -gt 0
                } | ForEach-Object { $_.Name })

            ($offender -join ', ') | Should -BeExactly ''
        }

        It 'calls Get-Credential only on the one interactive path, which is named' {
            # Start-HDTDeployment asks when the image said to prompt and the
            # share has no credential - a person in front of a wizard, which is
            # the one place asking is right. A second such file has to be a
            # decision somebody writes down here.
            $offender = @($script:engineFile | Where-Object {
                    $script:promptAllowed -notcontains $_.Name -and
                    (Get-HDTCommandCallName -Path $_.FullName) -contains 'Get-Credential'
                } | ForEach-Object { $_.Name })

            ($offender -join ', ') | Should -BeExactly ''
        }
    }

    Context 'a mandatory parameter nobody supplied' {

        It 'is never left unsupplied at an HDT call site in src/Hephaestus' {
            # THE ONE THAT GETS WRITTEN BY ACCIDENT. The call site looks fine in
            # review; the machine hangs hours later with a half-imaged disk.
            $violation = @($script:engineFile | ForEach-Object {
                    Get-HDTUnattendedCallViolation -Path $_.FullName
                })

            $reported = @($violation | ForEach-Object {
                    '{0}:{1} {2} -{3}' -f $_.File, $_.Line, $_.Command, $_.Parameter
                })

            ($reported -join '; ') | Should -BeExactly ''
        }
    }
}

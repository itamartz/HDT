function Get-HDTSlowSuiteSkipViolation {
    <#
        .SYNOPSIS
            Reports every $script: variable a Pester file sets in BeforeDiscovery
            and reads from BeforeAll.

        .DESCRIPTION
            SPIKES S9.15, as a scanner. Pester's discovery and run phases DO NOT
            SHARE A SCOPE. A $script: variable assigned in BeforeDiscovery is
            what the -Skip: on a Describe reads while discovering; reading the
            same variable inside BeforeAll reaches across a boundary that is not
            there.

            Under Set-StrictMode -Version Latest - which ./build.ps1 sets and a
            bare Invoke-Pester does not - that read throws "The variable cannot
            be retrieved because it has not been set" inside BeforeAll and takes
            the whole container, every test in the file, down with it. WITHOUT
            StrictMode it is worse: the read evaluates to $null, 'if (-not
            $null)' is TRUE, and the expensive body runs on a machine that was
            supposed to be skipping it. A guard that means the opposite of what
            it says when its input is missing is worse than no guard.

            The fix, and the shape this scanner treats as correct, is to
            RECOMPUTE the condition inside BeforeAll from the same inputs.
            Discovery keeps its own copy for -Skip:.

            AST, NOT REGEX, for a file that parses. The assignment and the read
            are the same token - $script:skipSlow - and a text scan cannot tell
            one from the other. A read is reported only when it happens before
            the first assignment to that name inside the same BeforeAll.

            A FILE THAT DOES NOT PARSE FALLS BACK TO A LINE SCAN, and says so in
            the message - the same discipline Get-HDTMdtDependency carries, for
            the same reason: returning nothing for a file with a syntax error
            would let the violation hide behind it.

        .PARAMETER Path
            One or more Pester files to scan.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Line, Column,
            Variable and Message.

        .EXAMPLE
            Get-HDTSlowSuiteSkipViolation -Path ./tests/integration/ImageService.Integration.Tests.ps1

            Returns nothing: that file recomputes its skip condition in BeforeAll.

        .EXAMPLE
            Get-ChildItem ./tests/e2e -Filter *.ps1 |
                ForEach-Object { $_.FullName } | Get-HDTSlowSuiteSkipViolation

            Scans a whole slow suite.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        $rule = 'SPIKES S9.15: Pester discovery and run phases do not share a scope - recompute the condition inside BeforeAll'
        $violation = New-Object -TypeName System.Collections.ArrayList
    }

    process {
        foreach ($item in $Path) {
            if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
                throw "Pester file '$item' does not exist."
            }

            $fullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $item).ProviderPath)

            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref] $token, [ref] $parseError)

            if (@($parseError).Count -eq 0) {
                # -- the block bodies ------------------------------------------
                $blockBody = {
                    param($Root, $Name)

                    # Copied to a local first: the predicate below is a nested
                    # scriptblock, and a parameter used only inside one reads as
                    # unused to PSScriptAnalyzer.
                    $wanted = $Name

                    $command = $Root.FindAll({
                            param($Node)
                            ($Node -is [System.Management.Automation.Language.CommandAst]) -and
                            ($Node.GetCommandName() -eq $wanted)
                        }, $true)

                    $body = New-Object -TypeName System.Collections.ArrayList
                    foreach ($current in @($command)) {
                        foreach ($element in @($current.CommandElements)) {
                            if ($element -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                                [void] $body.Add($element.ScriptBlock)
                            }
                        }
                    }

                    # No unary comma: the caller rewraps with @(), and a wrapped
                    # empty list would arrive as one element that is an array.
                    return @($body)
                }

                # -- $script: names assigned somewhere -------------------------
                $assignedName = {
                    param($Body)

                    $assignment = $Body.FindAll({
                            param($Node) $Node -is [System.Management.Automation.Language.AssignmentStatementAst]
                        }, $true)

                    $found = @{}
                    foreach ($current in @($assignment)) {
                        $left = $current.Left
                        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                        if (-not ($left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }

                        $variablePath = $left.VariablePath
                        if (-not $variablePath.IsScript) { continue }

                        $name = $variablePath.UserPath -replace '^(?i)script:', ''
                        $offset = $current.Extent.StartOffset
                        if ((-not $found.ContainsKey($name)) -or ($offset -lt $found[$name])) {
                            $found[$name] = $offset
                        }
                    }

                    return $found
                }

                $discoveryName = @{}
                foreach ($body in @(& $blockBody $ast 'BeforeDiscovery')) {
                    foreach ($key in @((& $assignedName $body).Keys)) {
                        $discoveryName[$key] = $true
                    }
                }

                if ($discoveryName.Count -eq 0) {
                    continue
                }

                foreach ($body in @(& $blockBody $ast 'BeforeAll')) {
                    $reassigned = & $assignedName $body

                    $read = $body.FindAll({
                            param($Node) $Node -is [System.Management.Automation.Language.VariableExpressionAst]
                        }, $true)

                    foreach ($current in @($read)) {
                        $variablePath = $current.VariablePath
                        if (-not $variablePath.IsScript) { continue }

                        $name = $variablePath.UserPath -replace '^(?i)script:', ''
                        if (-not $discoveryName.ContainsKey($name)) { continue }

                        # The left-hand side of an assignment is a write, and a
                        # write is the fix rather than the defect.
                        if ($reassigned.ContainsKey($name) -and ($current.Extent.StartOffset -ge $reassigned[$name])) { continue }

                        [void] $violation.Add([pscustomobject] @{
                                Path     = $fullPath
                                Line     = $current.Extent.StartLineNumber
                                Column   = $current.Extent.StartColumnNumber
                                Variable = $name
                                Message  = ("`$script:{0} is assigned in BeforeDiscovery and read in BeforeAll ({1})." -f $name, $rule)
                            })
                    }
                }

                continue
            }

            # -- the fallback, for a file that does not parse ------------------
            #
            # Brace depth from the line a block opens on, which is crude and is
            # meant to be: it exists so a syntax error cannot hide a violation.
            $line = @(Get-Content -LiteralPath $fullPath -ErrorAction Stop)
            $mode = ''
            $modeDepth = 0
            $depth = 0
            $discoveryName = @{}
            $fallback = New-Object -TypeName System.Collections.ArrayList

            for ($index = 0; $index -lt $line.Count; $index++) {
                $text = $line[$index]
                $trimmed = $text.TrimStart()

                if (($mode -eq '') -and ($trimmed -match '^(BeforeDiscovery|BeforeAll)\b')) {
                    $mode = $matches[1]
                    $modeDepth = $depth
                }

                if (-not $trimmed.StartsWith('#')) {
                    if ($mode -eq 'BeforeDiscovery') {
                        $match = [regex]::Match($text, '\$script:(\w+)\s*=')
                        if ($match.Success) { $discoveryName[$match.Groups[1].Value] = $true }
                    } elseif ($mode -eq 'BeforeAll') {
                        foreach ($match in [regex]::Matches($text, '\$script:(\w+)')) {
                            $name = $match.Groups[1].Value
                            $isWrite = [regex]::IsMatch($text, ('\$script:' + [regex]::Escape($name) + '\s*='))
                            [void] $fallback.Add([pscustomobject] @{
                                    Name    = $name
                                    Line    = $index + 1
                                    Column  = $match.Index + 1
                                    IsWrite = $isWrite
                                })
                        }
                    }
                }

                $depth += (@([regex]::Matches($text, '\{')).Count - @([regex]::Matches($text, '\}')).Count)

                if (($mode -ne '') -and ($depth -le $modeDepth)) { $mode = '' }
            }

            $written = @{}
            foreach ($current in @($fallback)) {
                if ($current.IsWrite) {
                    if (-not $written.ContainsKey($current.Name)) { $written[$current.Name] = $current.Line }
                }
            }

            foreach ($current in @($fallback)) {
                if ($current.IsWrite) { continue }
                if (-not $discoveryName.ContainsKey($current.Name)) { continue }
                if ($written.ContainsKey($current.Name) -and ($current.Line -ge $written[$current.Name])) { continue }

                [void] $violation.Add([pscustomobject] @{
                        Path     = $fullPath
                        Line     = $current.Line
                        Column   = $current.Column
                        Variable = $current.Name
                        Message  = ("`$script:{0} is assigned in BeforeDiscovery and read in BeforeAll ({1}). This file did not parse on the current engine ({2}), so it was checked by a raw text scan that skips comment lines." -f $current.Name, $rule, $PSVersionTable.PSVersion)
                    })
            }
        }
    }

    end {
        return @($violation | Sort-Object -Property Path, Line, Column)
    }
}

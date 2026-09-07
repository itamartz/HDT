#requires -Version 5.1

# Nothing in this repository may delete the repository, the lab root, or the
# staged media. The rule exists because the cost is asymmetric: a wrong
# Remove-Item costs hours of restaging at best and the project at worst, while
# the guard costs one grep.
#
# Scope note: this scans for the *dangerous shapes* - a recursive delete whose
# target is a bare drive-root-ish literal, or one of the named protected paths.
# It deliberately does NOT ban Remove-Item, because clearing out/ and cleaning up
# a scratch VHDX a test itself created are both legitimate and necessary.

BeforeAll {
    $script:contractRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE FILE LIST IS BUILT HERE, IN THE RUN PHASE, AND NOT IN BeforeDiscovery.
    # SPIKES S9.15: discovery and run do not share a scope. Read from an It body,
    # a $script: variable set in BeforeDiscovery throws under ./build.ps1's
    # StrictMode - and WITHOUT StrictMode it is $null, @($null).Count is 1, so
    # "scans at least one PowerShell file" passed while the scan itself covered
    # nothing at all. Nothing here is expanded at discovery time (there is no
    # -ForEach), so the run phase is the only place this belongs.
    $script:scanFile = @(
        Get-ChildItem -LiteralPath $script:contractRepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch '\\out\\' -and
                $_.FullName -notmatch '\\\.git\\' -and
                $_.FullName -notmatch '\\tests\\fixtures\\' -and
                $_.Name -ne 'ProtectedPath.Contract.Tests.ps1'
            }
    )

    # Literal paths that must never appear as the target of a delete.
    $script:protectedPattern = @(
        'GithubRepos\\HDT'
        'C:\\HDTLab'''
        'C:\\HDTLab"'
        'C:\\HDTLab\\media'
        'C:\\HDTLab\\Share'
        'C:\\HDTLab\\reference'
    )

    # EVERY SPELLING OF A DELETE THAT REACHES A WINDOWS SHELL, and the list is
    # the whole point. On 2026-09-07 this pattern read
    # ^(Remove-Item|rd|rmdir|Remove-VMHardDiskDrive)$ and an agent typed 'rm'.
    # The path matched. The verb did not. Sixteen per-machine overrides went.
    #
    # Move-Item is here for the same reason and not as an afterthought: a file
    # moved off C:\HDTLab\Share is as gone as a file removed from it, and it
    # leaves no Recycle Bin entry either.
    $script:deleteVerbPattern = '^(Remove-Item|ri|rm|del|erase|rd|rmdir|Move-Item|mv|move|Remove-VMHardDiskDrive)$'

    # Only the shapes that destroy a tree - Move-Item is not one of them, and a
    # recursive move does not exist.
    $script:destroyVerbPattern = '^(Remove-Item|ri|rm|del|erase|rd|rmdir)$'

    # [System.IO.File]::Delete and [System.IO.Directory]::Delete tokenise as a
    # type name, '::' and 'Delete' - not as a command - so they need their own
    # recogniser. New-HDTFileSystem uses both; they are how the adapter deletes.
    $script:ioTypePattern = '^\[?(System\.)?IO\.(File|Directory)\]?$'

    # THE THREE LOCATIONS CLAUDE.md PERMITS, as they look in source. A delete
    # whose target the scan can trace to one of these is legal; one it cannot
    # trace anywhere is not, whether or not it names C:\HDTLab out loud.
    $script:permittedRootPattern = @(
        '\$TestDrive'                     # Pester throws it away itself
        '\$env:TEMP'
        '\$env:TMP'
        'GetTempPath'
        'C:\\HDTLab\\scratch'             # a scratch tree this run created
        'C:\\HDTLab\\vms'                 # an HDT-* VM folder this run created
        'HDTOutputPath'                   # out\, via ./build.ps1 -Task clean
        'TestRegistry:'                   # Pester's own registry drive
    )

    # SHORT, ARGUED, AND IN ONE REVIEWED PLACE - the same shape as the KEEP list
    # in ScratchTeardown.Contract.Tests.ps1, and for the same reason: an
    # exemption that lives beside the code it exempts is an exemption nobody
    # reviews. Each entry is a delete whose target is a PARAMETER, so the
    # narrowing happens at the call site and no file-local scan can see it.
    $script:shapeExemption = @(
        @{ File = 'src\Hephaestus\Payload\Remove-HDTAgentTree.ps1'; Variable = 'Target'
            Why = 'the RemoveTree adapter scriptblock. Its caller has already proved the path is a staged agent tree, and the adapter is branch-free by rule 1.' }
        @{ File = 'tests\contract\RegistryService.Contract.Tests.ps1'; Variable = 'WriteRoot'
            Why = 'an HKCU registry key, not a filesystem path. The suite passes its own scratch root and the fake row never creates it.' }
        @{ File = 'tests\integration\BootImage.Integration.Tests.ps1'; Variable = 'Root'
            Why = 'the workspace this file built under C:\HDTLab\scratch; the one call site passes $script:workspaceRoot.' }
        @{ File = 'tests\integration\WinPeContent.Integration.Tests.ps1'; Variable = 'MountPath'
            Why = 'a WIM mount folder this file created under C:\HDTLab\scratch, removed in the finally that dismounts it.' }
    )

    # Tokens of one statement, starting at the verb. BOUNDED AT THE NEWLINE so a
    # literal on the following line cannot be read as this delete's target - the
    # unbounded window was fine for a scan that only ever said "too close for
    # comfort", and is not fine for one that decides a shape.
    function Get-HDTStatementToken {
        param($Code, [int] $Start)

        $window = @()
        for ($k = $Start; $k -lt $Code.Count -and $window.Count -lt 40; $k++) {
            $kind = $Code[$k].Kind.ToString()
            if ($k -gt $Start -and ($kind -eq 'NewLine' -or $kind -eq 'Semi' -or $kind -eq 'RCurly')) { break }
            if ($kind -eq 'NewLine' -or $kind -eq 'Semi') { continue }
            $window += $Code[$k]
        }

        return $window
    }

    # The bare variable a delete is aimed at: one directly after the verb, or
    # after -Path / -LiteralPath, and at paren depth zero. The depth matters -
    # Remove-Item -Path (Join-Path -Path $tree -ChildPath 'Private') aims at the
    # Join-Path result, not at $tree, and reading $tree there would flag a line
    # that is already as narrow as it can be.
    function Get-HDTDeleteTargetVariable {
        param($Window, [string] $Verb)

        $depth = 0
        for ($j = 1; $j -lt $Window.Count; $j++) {
            $kind = $Window[$j].Kind.ToString()
            if ($kind -eq 'LParen' -or $kind -eq 'AtParen' -or $kind -eq 'LCurly') { $depth++; continue }
            if ($kind -eq 'RParen' -or $kind -eq 'RCurly') { $depth--; continue }
            if ($depth -ne 0 -or $kind -ne 'Variable') { continue }

            $prev = [string] $Window[$j - 1].Text
            if ($prev -eq $Verb -or $prev -match '^-(Path|LiteralPath)$') { return [string] $Window[$j].Text }
        }

        return $null
    }

    # Can this variable be traced to a location CLAUDE.md permits? Follows
    # assignments through the file, because that is how the permitted roots are
    # actually written: $script:HDTOutputPath, then $stagePath from it, then
    # $trim from that. Three hops covers every one of them here.
    function Test-HDTRootedVariable {
        param([string] $Name, [string] $Text, [int] $Depth = 0)

        $short = ($Name.TrimStart('$') -split ':')[-1]
        if ([string]::IsNullOrWhiteSpace($short)) { return $false }
        $escaped = [regex]::Escape($short)

        # Two variables ARE a permitted root rather than merely pointing at one:
        # Pester's own scratch drive, and the build's out\ directory.
        if ($short -match '^(TestDrive|HDTOutputPath)$') { return $true }

        # An Assert-HDT* call naming it, or a comparison narrowing it, is the
        # assertion CLAUDE.md asks for in so many words.
        if ($Text -match ('Assert-[A-Za-z]+[^\r\n]*\$(\w+:)?' + $escaped + '\b')) { return $true }
        if ($Text -match ('\$(\w+:)?' + $escaped + '\b[^\r\n]*(StartsWith|-match|-notmatch|-like|-clike)')) { return $true }

        if ($Depth -ge 3) { return $false }

        $assignment = [regex]::Matches($Text, ('\$(?:\w+:)?' + $escaped + '\s*=([^\r\n]*)'))
        foreach ($match in $assignment) {
            $rhs = $match.Groups[1].Value

            foreach ($root in $script:permittedRootPattern) {
                if ($rhs -match $root) { return $true }
            }

            foreach ($referenced in [regex]::Matches($rhs, '\$(?:\w+:)?(\w+)')) {
                $next = $referenced.Groups[1].Value
                if ($next -eq $short) { continue }
                if (Test-HDTRootedVariable -Name $next -Text $Text -Depth ($Depth + 1)) { return $true }
            }
        }

        return $false
    }

    function Test-HDTRootedLiteral {
        param([string] $Literal)

        $bare = $Literal.Trim("'", '"')
        foreach ($root in $script:permittedRootPattern) {
            if ($bare -match $root) { return $true }
        }

        return $false
    }

    function Get-HDTProtectedDeleteViolation {
        param([System.IO.FileInfo[]] $File)

        foreach ($item in $File) {
            $token = $null; $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $item.FullName, [ref] $token, [ref] $parseError)

            # Comments may discuss the rule; code may not break it.
            $code = @($token | Where-Object { $_.Kind.ToString() -ne 'Comment' })

            for ($i = 0; $i -lt $code.Count; $i++) {
                $text = [string] $code[$i].Text

                $isVerb = $text -match $script:deleteVerbPattern
                $isIoDelete = ($text -match $script:ioTypePattern) -and
                    ($i + 3 -lt $code.Count) -and ([string] $code[$i + 3].Text -eq 'Delete')

                if (-not $isVerb -and -not $isIoDelete) { continue }

                $window = (Get-HDTStatementToken -Code $code -Start $i | ForEach-Object { [string] $_.Text }) -join ' '

                foreach ($p in $script:protectedPattern) {
                    if ($window -match $p) {
                        [pscustomobject]@{
                            Path    = $item.FullName.Substring($script:contractRepoRoot.Length + 1)
                            Line    = $code[$i].Extent.StartLineNumber
                            Pattern = $p
                            Window  = $window.Substring(0, [math]::Min(110, $window.Length))
                        }
                    }
                }
            }
        }
    }

    # THE SHAPE SCAN. The literal scan above can only catch a delete that names
    # a protected path out loud; these are the two that never do.
    function Get-HDTDeleteShapeViolation {
        param(
            [System.IO.FileInfo[]] $File,
            [string] $Shape,

            # For the one test that proves the exemption list is not stale: an
            # exemption nobody can see firing is an exemption nobody reviews.
            [switch] $IgnoreExemption
        )

        $wanted = $null
        if ($PSBoundParameters.ContainsKey('Shape')) { $wanted = $Shape }
        $found = New-Object System.Collections.ArrayList

        foreach ($item in $File) {
            $token = $null; $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $item.FullName, [ref] $token, [ref] $parseError)

            $code = @($token | Where-Object { $_.Kind.ToString() -ne 'Comment' })
            $text = [string] (Get-Content -LiteralPath $item.FullName -Raw -ErrorAction SilentlyContinue)
            $relative = $item.FullName
            if ($relative.StartsWith($script:contractRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $relative.Substring($script:contractRepoRoot.Length + 1)
            }

            for ($i = 0; $i -lt $code.Count; $i++) {
                $verb = [string] $code[$i].Text
                if ($verb -notmatch $script:destroyVerbPattern) { continue }

                $window = @(Get-HDTStatementToken -Code $code -Start $i)
                $windowText = ($window | ForEach-Object { [string] $_.Text }) -join ' '
                $line = $code[$i].Extent.StartLineNumber

                $exempt = (-not $IgnoreExemption) -and
                    @($script:shapeExemption | Where-Object { $relative -like ('*' + $_.File) }).Count -gt 0

                # -- shape 1: a variable handed to a recursive delete ----------
                $recursive = @($window | Where-Object {
                        $_.Kind.ToString() -eq 'Parameter' -and [string] $_.Text -eq '-Recurse' }).Count -gt 0

                if ($recursive) {
                    $target = Get-HDTDeleteTargetVariable -Window $window -Verb $verb

                    if ($target -and -not (Test-HDTRootedVariable -Name $target -Text $text)) {
                        $named = (-not $IgnoreExemption) -and
                            @($script:shapeExemption | Where-Object {
                                    $relative -like ('*' + $_.File) -and $target.TrimStart('$') -eq $_.Variable }).Count -gt 0

                        if (-not $named) {
                            $null = $found.Add([pscustomobject]@{
                                    Path = $relative; Line = $line; Shape = 'UnrootedVariable'
                                    Detail = ('{0} traces to no permitted root :: {1}' -f $target, $windowText)
                                })
                        }
                    }
                }

                # -- shape 2a: a target built by enumerating a parent ----------
                if ($i -gt 0 -and $code[$i - 1].Kind.ToString() -eq 'Pipe') {
                    $lo = [math]::Max(0, $i - 30)
                    $upstream = @()
                    for ($k = $i - 2; $k -ge $lo; $k--) {
                        if ($code[$k].Kind.ToString() -eq 'NewLine' -or $code[$k].Kind.ToString() -eq 'Semi') { break }
                        $upstream = @($code[$k]) + $upstream
                    }

                    $upstreamText = ($upstream | ForEach-Object { [string] $_.Text }) -join ' '

                    if ($upstreamText -match '(^|\s)(Get-ChildItem|gci|dir|ls)(\s|$)') {
                        $enumerated = Get-HDTDeleteTargetVariable -Window $upstream -Verb (($upstreamText -split ' ')[0])
                        $rooted = $false
                        if ($enumerated) { $rooted = Test-HDTRootedVariable -Name $enumerated -Text $text }
                        if (-not $rooted) {
                            foreach ($t in $upstream) {
                                if ($t.Kind.ToString() -match 'String' -and (Test-HDTRootedLiteral -Literal ([string] $t.Text))) { $rooted = $true }
                            }
                        }

                        if (-not $rooted -and -not $exempt) {
                            $null = $found.Add([pscustomobject]@{
                                    Path = $relative; Line = $line; Shape = 'EnumeratedParent'
                                    Detail = ('the target comes from {0}' -f $upstreamText)
                                })
                        }
                    }
                }

                # -- shape 2b: a target built by a wildcard --------------------
                foreach ($t in $window) {
                    $literal = [string] $t.Text
                    if ($t.Kind.ToString() -notmatch 'String|Generic') { continue }
                    if ($literal -notmatch '[\\/][^\\/\s]*\*') { continue }
                    if (Test-HDTRootedLiteral -Literal $literal) { continue }
                    if ($exempt) { continue }

                    $null = $found.Add([pscustomobject]@{
                            Path = $relative; Line = $line; Shape = 'WildcardTarget'
                            Detail = ('{0} names every file that matches, not the one meant' -f $literal)
                        })
                }
            }
        }

        return @($found | Where-Object { $null -eq $wanted -or $_.Shape -eq $wanted })
    }
}

Describe 'Protected paths (CLAUDE.md)' {

    It 'scans at least one PowerShell file' {
        @($script:scanFile).Count | Should -BeGreaterThan 0 -Because 'a contract that scans nothing proves nothing'
    }

    It 'deletes nothing under the repository root, the lab root, the media, the share or the reference clone' {
        $violation = @(Get-HDTProtectedDeleteViolation -File $script:scanFile)

        $message = ($violation | ForEach-Object { '{0}:{1} matched {2} -> {3}' -f $_.Path, $_.Line, $_.Pattern, $_.Window }) -join "`n"
        $violation.Count | Should -Be 0 -Because "these paths are never delete targets:`n$message"
    }

    It 'catches a deliberate violation' {
        # The guard has to be shown to bite, or it is decoration.
        $bait = Join-Path -Path $TestDrive -ChildPath 'bait.ps1'
        Set-Content -LiteralPath $bait -Value 'Remove-Item -Path "C:\HDTLab\media" -Recurse -Force' -Encoding UTF8

        $hit = @(Get-HDTProtectedDeleteViolation -File @(Get-Item -LiteralPath $bait))
        $hit.Count | Should -BeGreaterThan 0 -Because 'a delete of the staged media must be caught'
    }

    It 'permits clearing the build output directory' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'ok.ps1'
        Set-Content -LiteralPath $ok -Value 'Remove-Item -Path $script:HDTOutputPath -Recurse -Force' -Encoding UTF8

        @(Get-HDTProtectedDeleteViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'build.ps1 -Task clean must stay legal'
    }
}

Describe 'The verbs that delete (2026-09-07)' {

    # ONE It PER VERB, driven off the set rather than off the one that bit.
    # 'rm' was missing on 2026-09-07 and the scan passed the command that
    # emptied Control\machines: the path matched and the verb did not. A test
    # naming 'rm' would pass for 'rm' and fail nobody after it, so this drives
    # off every spelling of a delete that reaches a Windows shell.
    It "catches '<Verb>' against a protected path" -ForEach @(
        @{ Verb = 'Remove-Item'; Line = "Remove-Item -Path 'C:\HDTLab\media' -Recurse -Force" }
        @{ Verb = 'rm';          Line = "rm -Recurse -Force 'C:\HDTLab\media'" }
        @{ Verb = 'del';         Line = "del 'C:\HDTLab\Share\Control'" }
        @{ Verb = 'erase';       Line = "erase 'C:\HDTLab\Share\Control'" }
        @{ Verb = 'ri';          Line = "ri -LiteralPath 'C:\HDTLab\reference' -Recurse" }
        @{ Verb = 'rd';          Line = "rd 'C:\HDTLab\media'" }
        @{ Verb = 'rmdir';       Line = "rmdir 'C:\HDTLab\media'" }
        @{ Verb = 'IO.File';     Line = "[System.IO.File]::Delete('C:\HDTLab\Share\Control\machines\HDT-WDS-01.yaml')" }
        @{ Verb = 'IO.Directory'; Line = "[IO.Directory]::Delete('C:\HDTLab\Share', `$true)" }

        # MOVING A FILE OFF A PROTECTED PATH DESTROYS IT AS EFFECTIVELY AS
        # DELETING IT, and leaves no Recycle Bin entry either. The override that
        # decides HDT-WDS-01 gets Server 2025 is gone whether it was removed or
        # relocated.
        @{ Verb = 'Move-Item';   Line = "Move-Item -LiteralPath 'C:\HDTLab\Share\Control' -Destination `$elsewhere" }
        @{ Verb = 'mv';          Line = "mv 'C:\HDTLab\Share\Control' `$elsewhere" }
    ) {
        $bait = Join-Path -Path $TestDrive -ChildPath ('verb-{0}.ps1' -f ($Verb -replace '\W', '_'))
        Set-Content -LiteralPath $bait -Value $Line -Encoding UTF8

        @(Get-HDTProtectedDeleteViolation -File @(Get-Item -LiteralPath $bait)).Count |
            Should -BeGreaterThan 0 -Because "'$Verb' destroys a protected path as surely as Remove-Item does"
    }

    It 'catches the command that emptied Control\machines' {
        # THE ACTUAL STRING, read from the fixture rather than retyped here, so
        # that loosening the scanner cannot quietly stop covering it.
        $incident = Get-Item -LiteralPath (
            [IO.Path]::Combine($script:contractRepoRoot, 'tests', 'fixtures', 'protectedpath', 'incident-2026-09-07.ps1'))

        @(Get-HDTProtectedDeleteViolation -File @($incident)).Count |
            Should -BeGreaterThan 0 -Because 'the one command this contract exists to catch must be caught'
    }
}

Describe 'The shapes that delete (CLAUDE.md, "Paths that must never be deleted")' {

    # TWO SHAPES CLAUDE.md NAMES IN PROSE AND NOTHING TESTED. Both are the ones
    # that lose files nobody named:
    #
    #   "never pass a variable to Remove-Item -Recurse without asserting first
    #    that it is one of the permitted locations above"
    #   "never build a delete target by enumerating a parent directory"
    #
    # A LITERAL SCAN CANNOT CATCH THESE, because there is no protected literal
    # in the line to match - the path arrives in a variable, or is produced by a
    # wildcard at run time. So the rule is inverted: a recursive delete, or a
    # delete of an enumerated or wildcarded target, must be PROVABLY ROOTED in
    # one of the three locations CLAUDE.md permits. Anything the scan cannot
    # trace to one of those is a violation, whether or not it names C:\HDTLab.

    It 'the repository has no unrooted recursive delete and no enumerated delete target' {
        $violation = @(Get-HDTDeleteShapeViolation -File $script:scanFile)

        $message = ($violation | ForEach-Object { '{0}:{1} [{2}] {3}' -f $_.Path, $_.Line, $_.Shape, $_.Detail }) -join "`n"
        $violation.Count | Should -Be 0 -Because "a delete must be traceable to out\, a temp tree this run made, or C:\HDTLab\scratch|vms:`n$message"
    }

    It 'has no stale exemption, and so is proven to bite on real repository code' {
        # THE SCAN THAT FINDS NOTHING IS THE FAILURE MODE HERE. If a refactor
        # makes the shape scan blind, every assertion above still passes on its
        # bait file and the repository-wide one passes because it found zero.
        # This is the assertion that notices: every exemption must name a site
        # that DOES fire once the exemptions are lifted.
        $unexempted = @(Get-HDTDeleteShapeViolation -File $script:scanFile -IgnoreExemption)

        foreach ($entry in $script:shapeExemption) {
            $matched = @($unexempted | Where-Object {
                    $_.Path -like ('*' + $entry.File) -and $_.Detail -like ('*$' + $entry.Variable + '*') })

            $matched.Count | Should -BeGreaterThan 0 -Because (
                "the exemption for {0} in {1} claims to cover a site the scan finds. It does not, so either the scan went blind or the exemption is stale ({2})" -f
                $entry.Variable, $entry.File, $entry.Why)
        }
    }

    It 'catches a variable passed to a recursive delete with nothing asserted about it' {
        $bait = Join-Path -Path $TestDrive -ChildPath 'unrooted.ps1'
        Set-Content -LiteralPath $bait -Value @'
param([string] $Where)
Remove-Item -LiteralPath $Where -Recurse -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $bait) -Shape 'UnrootedVariable').Count |
            Should -BeGreaterThan 0 -Because 'this is DiskPartition guessing which disk to wipe, in file form'
    }

    It 'catches a delete target built by enumerating a parent directory' {
        $bait = Join-Path -Path $TestDrive -ChildPath 'enumerated.ps1'
        Set-Content -LiteralPath $bait -Value @'
param([string] $Where)
Get-ChildItem -LiteralPath $Where -File | Remove-Item -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $bait) -Shape 'EnumeratedParent').Count |
            Should -BeGreaterThan 0 -Because 'the parent is what gets emptied when the enumeration is wider than intended'
    }

    It 'catches a delete target built by a wildcard' {
        $bait = Join-Path -Path $TestDrive -ChildPath 'wildcard.ps1'
        Set-Content -LiteralPath $bait -Value 'Remove-Item -Path "C:\HDTLab\Share\Control\machines\*.yaml" -Force' -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $bait) -Shape 'WildcardTarget').Count |
            Should -BeGreaterThan 0 -Because 'a wildcard names every file that happens to match, not the one you meant'
    }

    It 'catches the shape of the command that emptied Control\machines' {
        $incident = Get-Item -LiteralPath (
            [IO.Path]::Combine($script:contractRepoRoot, 'tests', 'fixtures', 'protectedpath', 'incident-2026-09-07.ps1'))

        @(Get-HDTDeleteShapeViolation -File @($incident) -Shape 'WildcardTarget').Count |
            Should -BeGreaterThan 0 -Because 'the literal scan and the shape scan must each catch it on their own'
    }

    It 'permits a recursive delete rooted in the build output directory' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'rooted-out.ps1'
        Set-Content -LiteralPath $ok -Value @'
$script:HDTOutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'out'
$stage = Join-Path -Path $script:HDTOutputPath -ChildPath 'stage'
Remove-Item -LiteralPath $stage -Recurse -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'build.ps1 -Task clean and its staging tree are explicitly permitted'
    }

    It 'permits a recursive delete rooted in a scratch tree this run created' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'rooted-scratch.ps1'
        Set-Content -LiteralPath $ok -Value @'
$root = Join-Path -Path 'C:\HDTLab\scratch' -ChildPath 'HDT-suite'
Remove-Item -LiteralPath $root -Recurse -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'a scratch tree the run created is one of the three permitted locations'
    }

    It 'permits a recursive delete of a TestDrive path' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'rooted-testdrive.ps1'
        Set-Content -LiteralPath $ok -Value @'
$tree = Join-Path -Path $TestDrive -ChildPath 'tree'
Remove-Item -LiteralPath $tree -Recurse -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'Pester throws TestDrive away itself; a suite tidying inside it is not a risk'
    }

    It 'permits a recursive delete guarded by an assertion on the target' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'asserted.ps1'
        Set-Content -LiteralPath $ok -Value @'
param([string] $Where)
Assert-HDTLabVmPath -Path $Where -Name 'HDT-M3-Smoke'
Remove-Item -LiteralPath $Where -Recurse -Force
'@ -Encoding UTF8

        @(Get-HDTDeleteShapeViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'an Assert-HDT* call is exactly the narrowing CLAUDE.md asks for'
    }
}

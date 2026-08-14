# THE 5.1 TRAP THAT KILLED THE FIRST INTEGRATION RUN UNDER powershell.exe.
#
# Every adapter that shells out captures the tool's own words, because "oscdimg
# failed" without oscdimg's sentence is the log entry that wastes an hour
# (New-HDTBootImageService's own help says so). The way to capture them is
#
#     $output = @(& $tool @argument 2>&1)
#
# and under WINDOWS POWERSHELL 5.1 that line THROWS as soon as the tool writes
# its first line to stderr, when $ErrorActionPreference is 'Stop' - which engine
# code always sets (CLAUDE.md rule 7). 5.1 wraps each stderr line in an
# ErrorRecord; Stop makes the first one terminating. Reproduced in one line:
#
#     PS 5.1> $ErrorActionPreference='Stop'; & cmd /c 'echo oops 1>&2' 2>&1
#     THREW: oops
#
#     PS 5.1> $ErrorActionPreference='Continue'; & cmd /c 'echo oops 1>&2' 2>&1
#     no throw, output: oops
#
# pwsh 7 does not do this, which is why nothing noticed: every integration run
# before 05-06 was under pwsh. The first ./build.ps1 -Task integration under
# powershell.exe died in BootImage.Integration.Tests.ps1's setup with
#
#     Exception calling "NewIso" with "3" argument(s): "The running command
#     stopped because the preference variable "ErrorActionPreference" ... : 0%
#     complete"
#
# "0% complete" is OSCDIMG'S PROGRESS METER. The build was killed by a progress
# bar. And the exit code was never even consulted, so a tool that had merely
# been chatty was indistinguishable from one that had failed.
#
# THE FIX IS ONE LINE PER METHOD and it adds no branch, so the adapters keep
# CLAUDE.md rule 1's exemption. THIS FILE IS WHAT KEEPS IT THERE: the next
# adapter that captures a tool's output gets the same line or this goes red.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src'

    # Built in BeforeAll, not BeforeDiscovery, and asserted against a floor
    # rather than by -Count -gt 0: @($null).Count is 1 (SPIKES S9.15b).
    $script:sourceFile = @(Get-ChildItem -Path $script:sourceRoot -Filter '*.ps1' -Recurse -File)

    # One row per stderr-merging redirection anywhere in src/, with the enclosing
    # scriptblock it lives in.
    $script:merge = @()

    foreach ($file in $script:sourceFile) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)

        $redirection = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.MergingRedirectionAst]
                }, $true))

        foreach ($node in $redirection) {
            # The nearest enclosing scriptblock - a ScriptMethod's body, or the
            # function's own body when it is not one.
            $scope = $node.Parent
            while ($null -ne $scope -and -not ($scope -is [System.Management.Automation.Language.ScriptBlockAst])) {
                $scope = $scope.Parent
            }

            $script:merge += [pscustomobject] @{
                File  = $file.Name
                Line  = [int] $node.Extent.StartLineNumber
                Text  = [string] $node.Parent.Extent.Text
                Scope = $scope
            }
        }
    }
}

Describe 'a native command whose stderr is captured' {

    It 'scanned the engine source' {
        # Against a known floor. A scan that read nothing would make every
        # assertion below true for the wrong reason.
        @($script:sourceFile).Count | Should -BeGreaterThan 100
    }

    It 'found the redirections it is about' {
        # And a floor here too: the five known ones are dism, oscdimg, bcdboot,
        # reagentc and bcdedit. Fewer means the parse found nothing and the file
        # is decoration.
        @($script:merge).Count | Should -BeGreaterOrEqual 5
    }

    It 'sets ErrorActionPreference to Continue first: <File>:<Line>' -ForEach @(
        # Discovery reads nothing here; the rows are the files themselves, and
        # the assertion body does the lookup. Keeps -Skip:/-ForEach off a
        # BeforeAll variable (SPIKES S9.15).
        @{ File = 'New-HDTBootImageService.ps1'; Line = 'dism.exe' }
        @{ File = 'New-HDTBootImageService.ps1'; Line = 'oscdimg' }
        @{ File = 'New-HDTImageService.ps1'; Line = 'bcdboot.exe' }
        @{ File = 'New-HDTImageService.ps1'; Line = 'reagentc' }
        @{ File = 'New-HDTImageService.ps1'; Line = 'bcdedit.exe' }
    ) {
        $wantedFile = $File
        $wantedTool = $Line

        $row = @($script:merge | Where-Object {
                $_.File -eq $wantedFile -and $_.Text -match [regex]::Escape($wantedTool)
            })

        @($row).Count | Should -BeGreaterOrEqual 1 -Because "there should be a 2>&1 capture of $wantedTool in $wantedFile"

        foreach ($item in $row) {
            [string] $item.Scope.Extent.Text |
                Should -Match "\`$ErrorActionPreference\s*=\s*'Continue'" -Because (
                "under 5.1 with ErrorActionPreference Stop, $wantedTool's first stderr line makes this a terminating error - and a progress meter counts as stderr")
        }
    }

    It 'sets it in every such scope, including ones nobody has added yet' {
        # The rows above name the five that exist. This one is the rule.
        foreach ($item in $script:merge) {
            [string] $item.Scope.Extent.Text |
                Should -Match "\`$ErrorActionPreference\s*=\s*'Continue'" -Because (
                "{0}:{1} captures a native command's stderr and must not be killed by it" -f $item.File, $item.Line)
        }
    }
}

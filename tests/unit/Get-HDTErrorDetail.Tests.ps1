# WHAT A catch ACTUALLY HAS, AND WHAT THE LOG USED TO GET.
#
# run-20260830-204613 died at step 12 and the whole record was one sentence:
#
#   The task sequence stopped: Exception calling "SetValue" with "4"
#   argument(s): "The running command stopped because the preference variable
#   "ErrorActionPreference" or common parameter is set to Stop: Cannot delete a
#   subkey tree because the subkey does not exist."
#
# Three quoted layers deep, naming SetValue while the real failure was a DELETE,
# with no type, no file, no line and no stack. An administrator cannot act on
# that, and neither could the engineer who had to find the defect - which took
# reading the adapter rather than reading the log.
#
# THE OUTER LAYER IS THE LEAST INFORMATIVE ONE AND IS WHAT USED TO WIN.
# "Exception calling SetValue with 4 argument(s)" is PowerShell describing its
# own method-call plumbing; the sentence that names the cause is the INNERMOST.
# So the unwrap goes all the way down, and every layer is kept - the chain is
# itself evidence, because it says the ArgumentException arrived through a
# ScriptMethod under ErrorActionPreference Stop rather than being thrown
# directly.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A REAL ErrorRecord, CAUGHT THE WAY THE ENGINE CATCHES ONE. Constructing an
    # ErrorRecord by hand would prove nothing about InvocationInfo or
    # ScriptStackTrace, which are the two fields the log was missing and which
    # only PowerShell itself fills in.
    #
    # THE SHAPE IS THE ONE THAT FAILED: a ScriptMethod on a pscustomobject, whose
    # body sets ErrorActionPreference Stop and calls something that throws. That
    # is exactly New-HDTRegistryService.SetValue, and it is what produces the
    # three-layer MethodInvocationException the log could not read.
    # PRIVATE, so every call goes through InModuleScope. The ErrorRecord itself
    # is made OUTSIDE the module, because it has to be a real one caught from
    # real PowerShell plumbing rather than anything the module helped build.
    $script:detailOf = {
        param([object] $Record)

        return InModuleScope Hephaestus -Parameters @{ R = $Record } {
            param($R)
            Get-HDTErrorDetail -ErrorRecord $R
        }
    }

    $script:summaryOf = {
        param([object] $Record)

        return InModuleScope Hephaestus -Parameters @{ R = $Record } {
            param($R)
            Get-HDTErrorSummary -ErrorRecord $R
        }
    }

    $script:makeNestedError = {
        $service = [pscustomobject] @{}
        $service | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
            param([string] $Path, [string] $Name, [object] $Value, [string] $Type)

            $ErrorActionPreference = 'Stop'
            Get-Item -LiteralPath 'HKCU:\Software\HDT-No-Such-Key-For-A-Test' -ErrorAction Stop | Out-Null
        }

        $caught = $null
        try {
            $service.SetValue('HKLM:\SOFTWARE\Nothing', 'AutoAdminLogon', '1', 'String')
        } catch {
            $caught = $_
        }

        return $caught
    }
}

Describe 'Get-HDTErrorDetail' {

    Context 'a nested exception from a ScriptMethod' {

        BeforeAll {
            $script:record = & $script:makeNestedError
            $script:detail = & $script:detailOf $script:record
        }

        It 'caught something with more than one exception layer' {
            # The premise of the whole file. If this ever stops being true the
            # rest of the tests are asserting nothing.
            $script:record | Should -Not -BeNullOrEmpty
            $script:record.Exception.InnerException | Should -Not -BeNullOrEmpty
        }

        It 'names the innermost exception type rather than the wrapper' {
            $script:detail['exceptionType'] | Should -Not -BeNullOrEmpty
            $script:detail['exceptionType'] | Should -Not -Be 'System.Management.Automation.MethodInvocationException'
        }

        It 'names the outer exception type as well, because the chain is evidence' {
            $script:detail['outerExceptionType'] |
                Should -BeExactly 'System.Management.Automation.MethodInvocationException'
        }

        It 'carries every layer of the chain, not only the innermost' {
            @($script:detail['exceptionChain']).Count | Should -BeGreaterOrEqual 2
        }

        It 'takes the cause from the innermost layer' {
            # The innermost message is the one that says what actually went
            # wrong. The outer one says only that a method call failed.
            $script:detail['cause'] | Should -Not -BeNullOrEmpty
            $script:detail['cause'] | Should -Not -BeLike 'Exception calling*'
        }

        It 'carries the position message, which is the file and the line' {
            $script:detail['position'] | Should -Not -BeNullOrEmpty
        }

        It 'carries the script line number' {
            $script:detail['scriptLineNumber'] | Should -BeGreaterThan 0
        }

        It 'carries the script stack trace' {
            $script:detail['stackTrace'] | Should -Not -BeNullOrEmpty
        }

        It 'carries the fully qualified error id' {
            $script:detail['fullyQualifiedErrorId'] | Should -Not -BeNullOrEmpty
        }

        It 'carries the category' {
            $script:detail['category'] | Should -Not -BeNullOrEmpty
        }

        It 'carries the invocation name' {
            $script:detail.Contains('invocationName') | Should -BeTrue
        }

        It 'summarises to one sentence that names the cause and where it happened' {
            $summary = & $script:summaryOf $script:record

            $summary | Should -BeLike ('*{0}*' -f $script:detail['cause'])
            $summary | Should -BeLike '*Get-HDTErrorDetail.Tests.ps1*'
        }

        It 'keeps the summary to a single line, because the CMTrace twin is read by eye' {
            $summary = & $script:summaryOf $script:record

            @($summary -split "`n").Count | Should -Be 1
        }
    }

    Context 'a plain single-layer exception' {

        BeforeAll {
            $script:plain = $null
            try {
                throw [System.InvalidOperationException]::new('a flat failure')
            } catch {
                $script:plain = $_
            }

            $script:plainDetail = & $script:detailOf $script:plain
        }

        It 'reports the one type as both the innermost and the outermost' {
            $script:plainDetail['exceptionType'] | Should -BeExactly 'System.InvalidOperationException'
            $script:plainDetail['outerExceptionType'] | Should -BeExactly 'System.InvalidOperationException'
        }

        It 'reports a chain of one' {
            @($script:plainDetail['exceptionChain']).Count | Should -Be 1
        }

        It 'takes the cause from it' {
            $script:plainDetail['cause'] | Should -BeExactly 'a flat failure'
        }
    }

    Context 'the shape the log needs' {

        It 'returns something Write-HDTLog will accept as -Data' {
            $record = & $script:makeNestedError

            & $script:detailOf $record | Should -BeOfType ([System.Collections.IDictionary])
        }

        It 'survives a record with no invocation information' {
            # Not every ErrorRecord has one - a record rehydrated from a remote
            # session or constructed by a caller may not - and an engine that
            # threw while describing a failure would replace the failure with its
            # own.
            $bare = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('bare'), 'HDTTest', 'NotSpecified', $null)

            { & $script:detailOf $bare } | Should -Not -Throw
        }
    }
}

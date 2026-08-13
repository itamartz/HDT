function New-HDTSmbService {
    <#
        .SYNOPSIS
            Creates the real ISmbService adapter over the SmbShare module.

        .DESCRIPTION
            A THIN ADAPTER, AND DELIBERATELY DUMB (DESIGN 12.2.3, CLAUDE.md hard
            rule 1). It constructs arguments for four SmbShare cmdlets and
            projects what they return; every decision that could be got wrong -
            whether the identity that came back is a guest, whether the dialect
            is acceptable, whether a credential was supplied at all - lives in
            New-HDTSmbContentProvider, where it is unit tested against
            New-HDTFakeSmbService.

              NewMapping(remotePath, userName, password)  New-SmbMapping
              RemoveMapping(remotePath)                   Remove-SmbMapping -Force
              GetConnection(serverName)                   Get-SmbConnection
              GetClientConfiguration()                    Get-SmbClientConfiguration

            THE SmbShare MODULE IS THE MECHANISM BECAUSE IT IS PRESENT IN WinPE.
            DESIGN 5.1's contents table records SmbShare as present and NetTCPIP,
            NetAdapter and DnsClient as absent, so nothing here may reach for
            those - and 'net use' is not needed as a fallback.

            IT CARRIES EXACTLY ONE BRANCH, and it is named rather than hidden:
            New-SmbMapping refuses an empty -UserName, so a connection made as
            the caller's own identity - which is what the loopback integration
            test does, and what -AllowAnonymous means - has to omit the two
            parameters rather than pass them empty. The rule that adapters stay
            branch-free exists because they are not unit tested; this one is
            exercised for real by
            tests/integration/SmbContentProvider.Integration.Tests.ps1 against a
            throwaway share, which is the same bargain README section 11 records
            for New-HDTScriptInvoker.

            THE PASSWORD IS RECORDED AS '<redacted>'. $Operations is printed
            verbatim in a failure dump, and the deployment account's password
            does not belong in one (tests/helpers/README.md section 4).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the four ISmbService
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $smb = New-HDTSmbService
            $content = New-HDTSmbContentProvider -Root '\\server\HdtShare' -Credential $credential -SmbService $smb
            $content.Connect()
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The adapter boundary: New-SmbMapping -Password takes a plain string, and the provider above it holds the PSCredential.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUserNameAndPasswordParams', '',
        Justification = 'The adapter boundary: these are New-SmbMapping parameters, not a credential prompt.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'SmbService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name NewMapping -Value {
        param([string] $RemotePath, [string] $UserName, [string] $Password)

        $this.Record('NewMapping', @($RemotePath, $UserName, '<redacted>'))

        $argument = @{
            RemotePath = $RemotePath
            Persistent = $false
        }

        # The one branch, and the reason for it is in the help above.
        if (-not [string]::IsNullOrEmpty($UserName)) {
            $argument['UserName'] = $UserName
            $argument['Password'] = $Password
        }

        New-SmbMapping @argument | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveMapping -Value {
        param([string] $RemotePath)

        $this.Record('RemoveMapping', @($RemotePath))

        Remove-SmbMapping -RemotePath $RemotePath -Force | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetConnection -Value {
        param([string] $ServerName)

        $this.Record('GetConnection', @($ServerName))

        $row = @(Get-SmbConnection -ServerName $ServerName -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject] @{
                        ServerName = [string] $_.ServerName
                        ShareName  = [string] $_.ShareName
                        UserName   = [string] $_.UserName
                        Dialect    = [string] $_.Dialect
                        Encrypted  = [bool] $_.Encrypted
                        Signed     = [bool] $_.Signed
                    }
                })

        # The unary comma is mandatory: a ScriptMethod collapses a single-element
        # array to a scalar without it (tests/helpers/README.md F3), and one
        # connection is the normal case.
        return , ([object[]] $row)
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetClientConfiguration -Value {
        $this.Record('GetClientConfiguration', @())

        $configuration = Get-SmbClientConfiguration

        return [pscustomobject] @{
            EnableInsecureGuestLogons = [bool] $configuration.EnableInsecureGuestLogons
            RequireSecuritySignature  = [bool] $configuration.RequireSecuritySignature
        }
    }

    return $service
}

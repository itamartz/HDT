function New-HDTSmbService {
    <#
        .SYNOPSIS
            Creates the real ISmbService adapter over the SmbShare module.

        .DESCRIPTION
            A THIN ADAPTER, AND DELIBERATELY DUMB. It constructs arguments for
            five cmdlets and
            projects what they return; every decision that could be got wrong -
            whether the identity that came back is a guest, whether the dialect
            is acceptable, whether a credential was supplied at all - lives in
            New-HDTSmbContentProvider, where it is unit tested against
            New-HDTFakeSmbService.

              NewMapping(path, user, password, drive)     New-SmbMapping
              RemoveMapping(remotePath)                   Remove-SmbMapping -Force
              GetUsedDriveLetter()                        [IO.DriveInfo]::GetDrives
              GetConnection(serverName)                   Get-SmbConnection
              GetClientConfiguration()                    Get-SmbClientConfiguration

            THE MAPPING TAKES A DRIVE LETTER. A share connected without one can
            only be reached by its UNC path, and cmd.exe REFUSES A UNC WORKING
            DIRECTORY - it prints "UNC paths are not supported", moves itself to
            %SystemRoot%, and every application whose install command names its
            own installer relatively then runs in the wrong folder. The letter
            is chosen by the provider, which is where "the first free one from Z
            downward" is unit tested; this passes it to New-SmbMapping and
            nothing more.

            THE LETTERS IN USE COME FROM [IO.DriveInfo], NOT Get-SmbMapping. The
            question is which letters are free, and a local disk, the WinPE RAM
            disk on X: and somebody else's mapping all answer it; only one of
            the three is an SMB mapping.

            THE SmbShare MODULE IS THE MECHANISM BECAUSE IT IS PRESENT IN WinPE.
            The boot image contents table records SmbShare as present and NetTCPIP,
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
            System.Management.Automation.PSCustomObject with the five ISmbService
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $smb = New-HDTSmbService
            $content = New-HDTSmbContentProvider -Root '\\LAP-AMMSO01\HDTShare$' `
                -Credential (Get-Credential) -SmbService $smb
            $content.Connect()

            How WinPE reaches the deployment share: an authenticated SMB connection,
            made once, that every read afterwards goes through.

        .EXAMPLE
            @($smb.GetOperationName())

            What it was asked to do. The engine never calls net use itself - a step that
            did could not be tested without a share to connect to.

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
        param([string] $RemotePath, [string] $UserName, [string] $Password, [string] $LocalPath)

        $this.Record('NewMapping', @($RemotePath, $UserName, '<redacted>', $LocalPath))

        $argument = @{
            RemotePath = $RemotePath
            LocalPath  = $LocalPath
            Persistent = $false
        }

        # The one branch, and the reason for it is in the help above.
        if (-not [string]::IsNullOrEmpty($UserName)) {
            $argument['UserName'] = $UserName
            $argument['Password'] = $Password
        }

        New-SmbMapping @argument | Out-Null
    }

    # -- the server side ---------------------------------------------------
    #
    # THE OTHER HALF OF SMB, and the half MDT's New Deployment Share wizard
    # uses: a deployment share is a folder that has been PUBLISHED, and
    # DeployRoot is \<server>\<share> derived from that. These three are as
    # dumb as the mapping methods above and for the same reason - they are the
    # part no unit test can reach.

    $service | Add-Member -MemberType ScriptMethod -Name NewShare -Value {
        param([string] $Path, [string] $Name, [string] $Description)

        $this.Record('NewShare', @($Path, $Name, $Description))

        New-SmbShare -Name $Name -Path $Path -Description $Description | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetShare -Value {
        param([string] $Name)

        $this.Record('GetShare', @($Name))

        # A NAME THAT IS NOT THERE IS AN ERROR FROM Get-SmbShare, not an empty
        # answer, and "is this name taken" is a question with a false answer.
        $found = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue

        return [bool] ($null -ne $found)
    }

    $service | Add-Member -MemberType ScriptMethod -Name GrantShareAccess -Value {
        param([string] $Name, [string] $Account, [string] $Right)

        $this.Record('GrantShareAccess', @($Name, $Account, $Right))

        Grant-SmbShareAccess -Name $Name -AccountName $Account -AccessRight $Right -Force | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveMapping -Value {
        param([string] $RemotePath)

        $this.Record('RemoveMapping', @($RemotePath))

        Remove-SmbMapping -RemotePath $RemotePath -Force | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetUsedDriveLetter -Value {
        $this.Record('GetUsedDriveLetter', @())

        $letter = @([System.IO.DriveInfo]::GetDrives() |
                ForEach-Object { [string] $_.Name.Substring(0, 1).ToUpperInvariant() })

        return , ([string[]] $letter)
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

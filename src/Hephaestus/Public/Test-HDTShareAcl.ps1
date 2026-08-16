function Test-HDTShareAcl {
    <#
        .SYNOPSIS
            Judges whether the deployment account is least-privileged on the
            workspace.

        .DESCRIPTION
            DESIGN 6.3's mitigation, as a command rather than a paragraph:
            "least privilege is the mitigation, and it is enforced, not just
            documented ... Update-HDTBootImage runs this check and warns loudly
            when the account is over-privileged - a domain admin credential in a
            boot image is a domain compromise, and that is the failure worth
            catching."

            THE EXPECTED POSTURE:

              workspace root   Read only
              Logs\            Write (or Modify)
              Captures\        Write (or Modify)
              everything else  no more than Read

            THE FINDINGS:

              FullControl anywhere                      Critical
              write outside Logs\ and Captures\         Warning
              no read at the workspace root             Critical
              the account is an admin group             Critical
              an ACL that could not be read             Information

            Compliant is $true only when there is no finding above Information.

            IT NEVER THROWS AND IT NEVER BLOCKS A BUILD. DESIGN 6.3 says warn.
            An administrator whose boot image build died because the checker
            could not read one ACL is an administrator who turns the checker off,
            and then nobody is told about the domain admin credential either.

            IT IS PURE LOGIC. The rows come from Get-HDTShareAccessRule, which is
            the only file in HDT that calls Get-Acl; everything judged here is
            judged against hand-written rows in the unit tests, with no share
            attached.

            The folder list it recognises is Get-HDTWorkspacePath's closed set,
            read at run time rather than repeated here, so the DESIGN 2.1 layout
            is written down once. docs/share-account.md names the same folders,
            and a test asserts that rather than leaving a reader to check.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share. Used to build the
            path each finding names.

        .PARAMETER Identity
            The deployment account, as 'DOMAIN\name' or a bare name. Rules
            granted to anybody else are ignored: BUILTIN\Administrators has
            FullControl on very nearly every share there has ever been, and
            judging that would make Compliant unreachable and this check
            ignorable.

        .PARAMETER AccessRule
            Folder relative path -> the rows Get-HDTShareAccessRule returned for
            it. '.' or '' is the workspace root. A $null value means the ACL
            could not be read.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Compliant [bool] and
            Finding - rows of Path, Severity and Message, Critical first.

        .EXAMPLE
            $accessRule = @{ '.' = $rootRule; 'Logs' = $logRule }
            Test-HDTShareAcl -WorkspaceRoot '\\server\HdtShare' -Identity 'CONTOSO\svc-hdt-deploy' -AccessRule $accessRule

        .EXAMPLE
            $result = Test-HDTShareAcl -WorkspaceRoot $root -Identity $account -AccessRule $accessRule
            if (-not $result.Compliant) {
                $result.Finding | ForEach-Object { Write-Warning $_.Message }
            }

            What Update-HDTBootImage does with it: warn loudly, build anyway.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Identity,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $AccessRule
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # DESIGN 2.1's layout, read from the one place it is written down.
    $kind = @((Get-Command -Name Get-HDTWorkspacePath).Parameters['Kind'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })

    $writableFolder = @('Logs', 'Captures')
    $adminGroupPattern = 'Domain Admins|Enterprise Admins|Administrators'

    $finding = New-Object -TypeName System.Collections.ArrayList

    $add = {
        param([string] $Path, [string] $Severity, [string] $Message)

        [void] $finding.Add([pscustomobject] @{
                Path     = $Path
                Severity = $Severity
                Message  = $Message
            })
    }

    # -- which rows belong to the deployment account --------------------------

    $bareIdentity = $Identity
    if ($Identity.Contains('\')) { $bareIdentity = $Identity.Substring($Identity.LastIndexOf('\') + 1) }

    $isOurs = {
        param([object] $Row)

        $rowIdentity = [string] $Row.Identity
        if ([string]::IsNullOrWhiteSpace($rowIdentity)) { return $false }

        if ($rowIdentity -eq $Identity) { return $true }

        $bareRow = $rowIdentity
        if ($rowIdentity.Contains('\')) { $bareRow = $rowIdentity.Substring($rowIdentity.LastIndexOf('\') + 1) }

        return ($bareRow -eq $bareIdentity)
    }

    # -- the account itself ---------------------------------------------------

    if ($bareIdentity -match $adminGroupPattern) {
        & $add $WorkspaceRoot 'Critical' (
            ("The deployment account is '{0}', which is an administrative group. A domain admin credential in a boot image is a domain compromise, and that is the failure worth catching. Use a dedicated account - docs/share-account.md has the steps." -f $Identity))
    }

    # -- the workspace root ---------------------------------------------------

    $rootKey = ''
    foreach ($key in @($AccessRule.Keys)) {
        $normalized = ([string] $key).Trim().Trim('\', '/')
        if (($normalized -eq '') -or ($normalized -eq '.')) { $rootKey = [string] $key }
    }

    $rootIsReadable = $false
    $rootIsUnreadable = $false

    if ($rootKey -ne '') {
        $rootRow = $AccessRule[$rootKey]
        if ($null -eq $rootRow) {
            $rootIsUnreadable = $true
        } else {
            foreach ($row in @($rootRow)) {
                if (([string] $row.Type -ne 'Allow') -or (-not (& $isOurs $row))) { continue }
                if ([string] $row.Rights -match 'Read|FullControl') { $rootIsReadable = $true }
            }
        }
    }

    if ((-not $rootIsReadable) -and (-not $rootIsUnreadable)) {
        & $add $WorkspaceRoot 'Critical' (
            ("'{0}' cannot read the workspace root '{1}'. The deployment cannot work: a booted machine reads its rules, its sequences and its images from here." -f $Identity, $WorkspaceRoot))
    }

    # -- every folder that was read ------------------------------------------

    foreach ($key in @($AccessRule.Keys)) {
        $normalized = ([string] $key).Trim().Trim('\', '/')
        $isRoot = (($normalized -eq '') -or ($normalized -eq '.'))

        if ($isRoot) {
            $path = $WorkspaceRoot
        } elseif ($kind -contains $normalized) {
            $path = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind $normalized
        } else {
            $path = [System.IO.Path]::Combine($WorkspaceRoot, $normalized)
        }

        $row = $AccessRule[$key]

        if ($null -eq $row) {
            & $add $path 'Information' (
                ("The access control list on '{0}' could not be read, so the least-privilege check could not judge it. Run the check from an account that can read it, or check it by hand." -f $path))
            continue
        }

        $mayWrite = ($isRoot -eq $false) -and ($writableFolder -contains $normalized)

        foreach ($current in @($row)) {
            if ([string] $current.Type -ne 'Allow') { continue }
            if (-not (& $isOurs $current)) { continue }

            $rights = [string] $current.Rights

            if ($rights -match 'FullControl') {
                & $add $path 'Critical' (
                    ("'{0}' has FullControl on '{1}'. FullControl carries ChangePermissions and TakeOwnership, so the account in the boot image can rewrite the share's own security." -f $Identity, $path))
                continue
            }

            if (($rights -match 'Write|Modify|Delete|ChangePermissions|TakeOwnership') -and (-not $mayWrite)) {
                & $add $path 'Warning' (
                    ("'{0}' can write to '{1}' ({2}). The deployment account is expected to be read-only everywhere except {3}." -f
                        $Identity, $path, $rights, ($writableFolder -join '\ and ')))
            }
        }
    }

    # -- the result -----------------------------------------------------------

    $order = @{ 'Critical' = 0; 'Warning' = 1; 'Information' = 2 }
    $sorted = @($finding | Sort-Object -Property @{ Expression = { $order[[string] $_.Severity] } }, 'Path')

    $blocking = @($sorted | Where-Object { [string] $_.Severity -ne 'Information' })

    return [pscustomobject] @{
        Compliant = [bool] ($blocking.Count -eq 0)
        Finding   = [object[]] $sorted
    }
}

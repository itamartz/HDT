function Get-HDTShareAccessRule {
    <#
        .SYNOPSIS
            Projects the access control entries on a folder into the rows
            Test-HDTShareAcl judges.

        .DESCRIPTION
            A THIN ADAPTER, AND DELIBERATELY DUMB. It is the only file in HDT
            that calls Get-Acl, and it
            contains no judgement at all: every decision about whether an access
            rule is acceptable lives in Test-HDTShareAcl, which is pure logic and
            is unit tested against hand-written rows.

            Four properties per row - Identity, Rights, Type, IsInherited -
            because those are the four the least-privilege check
            needs and nothing else is wanted.

            AN ACL IT CANNOT READ IS $null, NOT AN EXCEPTION. HDT says
            Update-HDTBootImage warns; a UNC the builder has no rights to
            enumerate must produce an Information finding, not a failed boot
            image build. Test-HDTShareAcl takes $null for a folder to mean
            exactly that.

        .PARAMETER Path
            The folder to read.

        .OUTPUTS
            System.Object[] of PSCustomObject with Identity, Rights, Type and
            IsInherited, or $null where the ACL could not be read.

        .EXAMPLE
            Get-HDTShareAccessRule -Path '\\server\HdtShare\Logs'

        .EXAMPLE
            $accessRule = @{}
            foreach ($folder in @('.', 'Logs', 'Captures')) {
                $accessRule[$folder] = Get-HDTShareAccessRule -Path (Join-Path $root $folder)
            }
            Test-HDTShareAcl -WorkspaceRoot $root -Identity $account -AccessRule $accessRule

            The adapter and the judgement, which is how Update-HDTBootImage uses
            both.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest

    # -Stop is deliberately not set: an unreadable ACL is $null and is a finding,
    # not a failure (see the description).
    $acl = Get-Acl -LiteralPath $Path -ErrorAction SilentlyContinue

    if ($null -eq $acl) {
        return $null
    }

    return , ([psobject[]] @($acl.Access | ForEach-Object {
                [pscustomobject] @{
                    Identity    = [string] $_.IdentityReference
                    Rights      = [string] $_.FileSystemRights
                    Type        = [string] $_.AccessControlType
                    IsInherited = [bool] $_.IsInherited
                }
            }))
}

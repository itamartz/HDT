function Get-HDTLogDestination {
    <#
        .SYNOPSIS
            Where this run's logs are copied to - MDT's SLShare, or the deploy
            root when nothing says otherwise.

        .DESCRIPTION
            THE COPY-BACK DESTINATION USED TO BE DERIVED AND NOTHING COULD
            CHANGE IT. Logs landed under <deployRoot>\Logs and nowhere else,
            which is right for a lab and wrong for most of the sites MDT is used
            in: the deployment share is frequently read-only to the account the
            deployment runs as, is frequently a replica, and is frequently not
            where a team keeps logs.

            SO HDTSLShare, WITH MDT'S NAME AND MDT'S BEHAVIOUR. An administrator
            arriving from Workbench searches for what they already know, which is
            why this is not called HDTLogShare - the same reason the Skip
            properties kept their names under HDT's prefix.

            IT IS THE FOLDER, NOT A PARENT OF ONE. MDT writes <SLShare>\<computer>
            and never <SLShare>\Logs\<computer>, and an engine that appended
            'Logs' would put a site's deployment logs somewhere nobody named. The
            per-computer folder underneath is Copy-HDTLog's business, exactly as
            it is for the deploy root.

            IT RESOLVES LIKE ANY OTHER VARIABLE, so a site sets it once in
            rules.yaml, or per model, or per subnet, and the provenance says
            where the value came from. It is NOT a bootstrap setting: the copy
            happens after the share is reachable, so there is no reason to bake
            it into a boot image.

            NO DEPLOY ROOT IS NOT NO DESTINATION. A run that never reached the
            share is exactly the run whose log somebody wants, and HDTSLShare is
            the one destination that can still be written to - so it is honoured
            even when there is no root at all.

            IT VALIDATES NOTHING ABOUT THE PATH. Whether the account can write
            there is a question with one honest answer - try it - and Copy-HDTLog
            already reports what happened without failing the deployment. A
            pre-flight here would be a second opinion that can be wrong.

        .PARAMETER WorkspaceRoot
            The resolved deploy root. Empty is not an error.

        .PARAMETER Variable
            The resolved variables. HDTSLShare is read and nothing else.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path and Source
            ('HDTSLShare', 'DeployRoot' or 'None').

        .EXAMPLE
            $workspaceRoot = 'C:\HDTLab\Share'
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $resolved = Resolve-HDTVariable -Rule @() -Fact (Get-HDTMachineFact)
            Get-HDTLogDestination -WorkspaceRoot $workspaceRoot -Variable $resolved.Variable

        .EXAMPLE
            Add-HDTRule -Line $line -Name 'Log server' -Set @{ HDTSLShare = '\\logs-01\HDTLogs' }

            What a site writes once in rules.yaml.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $WorkspaceRoot,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $share = ''
    if ($null -ne $Variable -and $Variable.Contains('HDTSLShare')) {
        $share = ([string] $Variable['HDTSLShare']).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($share)) {
        return [pscustomobject] @{
            Path   = $share
            Source = 'HDTSLShare'
        }
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        # '\Logs' is a path on whatever drive this process happens to be
        # standing on, which in WinPE is the RAM disk that is about to go.
        return [pscustomobject] @{
            Path   = ''
            Source = 'None'
        }
    }

    return [pscustomobject] @{
        Path   = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Logs
        Source = 'DeployRoot'
    }
}

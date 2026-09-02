function Get-HDTLogDestination {
    <#
        .SYNOPSIS
            Where this run's logs are copied to - the HDTSLShare a site names,
            or the deploy root when nothing says otherwise.

        .DESCRIPTION
            THE COPY-BACK DESTINATION USED TO BE DERIVED AND NOTHING COULD
            CHANGE IT. Logs landed under <deployRoot>\Logs and nowhere else,
            which is right for a lab and wrong for most sites: the deployment
            share is frequently read-only to the account the deployment runs as,
            is frequently a replica, and is frequently not where a team keeps
            logs.

            SO HDTSLShare, THE ONE SETTING THAT MOVES IT. The name is MDT's
            SLShare carried over under HDT's prefix, because an administrator
            searches for the name they already know - the same reason the Skip
            properties kept theirs.

            IT IS THE FOLDER, NOT A PARENT OF ONE. This run's logs go to
            <SLShare>\<computer> and never <SLShare>\Logs\<computer>, and an
            engine that appended 'Logs' would put a site's deployment logs
            somewhere nobody named. The per-computer folder underneath is
            Copy-HDTLog's business, exactly as it is for the deploy root.

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

            AND A DISC IS NOT A PLACE TO WRITE LOGS TO. Under
            HDTDeploymentMethod = MEDIA the deploy root is read-only content, so
            the derived destination is refused and the answer says MEDIA was
            why. A machine that happens to have a NIC is still deploying from a
            disc - reaching for a share nobody named would not be a fallback, it
            would be a guess.

            THE MACHINE STILL KEEPS ITS OWN COPY. The WinPE leg writes its log
            to <osvolume>\HDT\Logs before the restart, which needs no network
            and is the copy an administrator actually reads. Nothing here
            touches that.

            AND THE MEDIA CHECK SITS AFTER HDTSLShare, DELIBERATELY. An
            administrator who names a log share is asking for one in so many
            words, and that answer is right whatever the machine booted from.
            Only the DERIVED destination is removed.

        .PARAMETER WorkspaceRoot
            The resolved deploy root. Empty is not an error.

        .PARAMETER Variable
            The resolved variables. HDTSLShare and HDTDeploymentMethod are read
            and nothing else.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Source
            ('HDTSLShare', 'Media', 'DeployRoot' or 'None') and Skipped.

            Skipped carries the destination a share deployment would have used
            and is empty on every answer but 'Media', so a caller can say WHY
            nothing was copied rather than only that nothing was.

        .EXAMPLE
            $workspaceRoot = 'C:\HDTLab\Share'
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            Get-HDTLogDestination -WorkspaceRoot $workspaceRoot -Variable $resolved.Variable

        .EXAMPLE
            Add-HDTRule -Line $line -Name 'Log server' -Set @{ HDTSLShare = '\\logs-01\HDTLogs' }

            What a site writes once in rules.yaml.

        .EXAMPLE
            Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' -Variable @{ HDTDeploymentMethod = 'MEDIA' }

            Path '', Source 'Media', Skipped 'D:\Deploy\Logs' - a deployment
            from a disc, whose deploy root cannot be written to. Setting
            HDTSLShare gives it somewhere it can go.
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
            Path    = $share
            Source  = 'HDTSLShare'
            Skipped = ''
        }
    }

    # A DISC IS NOT A PLACE TO WRITE LOGS TO, AND A NETWORK IS NOT A REASON TO
    # FIND ONE. The deploy root below is right for a share and wrong for media:
    # it is read-only content, and a machine that happens to have a NIC is still
    # deploying from a disc - reaching for a share nobody named is not a
    # fallback, it is a guess.
    #
    # AFTER HDTSLShare, DELIBERATELY. An administrator who names a log share is
    # asking for one in so many words, and that answer is right whatever the
    # machine booted from. This only removes the DERIVED destination.
    #
    # THE MACHINE STILL KEEPS ITS OWN COPY. The WinPE leg writes its log to
    # <osvolume>\HDT\Logs before the restart, which needs no network and is the
    # copy an administrator actually reads. Nothing here touches that.
    #
    # AND IT REPORTS WHAT IT DID NOT USE, because "no log destination" on its
    # own reads like a failure to resolve one and sends the reader looking for a
    # share that is working perfectly well. Skipped carries the path the share
    # deployment would have had, so the caller can say WHY in one line.
    #
    # -eq 'MEDIA' AND NOT -ne 'UNC'. An absent value, an empty string, or a
    # state.json written before this existed must all keep the old behaviour; a
    # negative test would turn every one of those into a silent skip.
    $method = ''
    if ($null -ne $Variable -and $Variable.Contains('HDTDeploymentMethod')) {
        $method = ([string] $Variable['HDTDeploymentMethod']).Trim()
    }

    if ($method -eq 'MEDIA') {
        $skipped = ''
        if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
            $skipped = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Logs
        }

        return [pscustomobject] @{
            Path    = ''
            Source  = 'Media'
            Skipped = $skipped
        }
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        # '\Logs' is a path on whatever drive this process happens to be
        # standing on, which in WinPE is the RAM disk that is about to go.
        return [pscustomobject] @{
            Path    = ''
            Source  = 'None'
            Skipped = ''
        }
    }

    return [pscustomobject] @{
        Path    = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Logs
        Source  = 'DeployRoot'
        Skipped = ''
    }
}

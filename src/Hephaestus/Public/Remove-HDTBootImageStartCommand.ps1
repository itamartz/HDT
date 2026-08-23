function Remove-HDTBootImageStartCommand {
    <#
        .SYNOPSIS
            Stops the booted image running a command, leaving every other line of
            workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to stop a tool being launched in
            WinPE, and the one anything with a Remove button has to run.

            THE CONTENT IT STARTED IS NOT REMOVED WITH IT. startCommand and
            extraContent are separate lists on purpose: a tool that is still in
            the image but no longer launched is a deliberate state - it is how a
            diagnostic tool is left available for a technician to start by hand.
            Run Remove-HDTBootImageContent to take the files out as well.

            THE KEY GOES WITH THE LAST COMMAND. `startCommand:` with nothing under
            it parses as a null, and the engine refuses a workspace whose
            startCommand is not a list. If that empties the bootImage block, the
            block goes too.

            A COMMAND THAT IS NOT THERE IS AN ERROR. The commands are matched
            exactly, as written - the value goes into startnet.cmd verbatim, so
            two spellings that differ by a space are two different commands.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Command
            The command to stop running, exactly as the document declares it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the command removed.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Remove-HDTBootImageStartCommand -Line $line -Command 'X:\HDT\Tools\VNC\winvnc.exe -service'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            Stops the boot image running something at start.

        .EXAMPLE
            @($line | Where-Object { $_ -match 'winvnc' }).Count

            Zero. The order of whatever else startnet runs is unchanged, which is the
            point of splicing rather than rewriting.

        .LINK
            Add-HDTBootImageStartCommand
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Command
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $declared = @($workspace.BootImage.StartCommand)

    $at = [array]::IndexOf([string[]] @($declared), [string] $Command)

    if ($at -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Command -Category ObjectNotFound `
                    -Message ("this boot image does not run '{0}'. A removal that quietly did nothing would look exactly like one that worked. It runs: {1}" -f
                        $Command, (@($declared) -join ' | '))))
    }

    if (-not $PSCmdlet.ShouldProcess($Command, 'Stop running this in WinPE')) {
        return [string[]] @($Line)
    }

    $result = [string[]] @(Remove-HDTWorkspaceItem -Line $Line -Path @('bootImage', 'startCommand') -Position $at)

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}

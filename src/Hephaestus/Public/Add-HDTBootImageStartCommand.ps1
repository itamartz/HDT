function Add-HDTBootImageStartCommand {
    <#
        .SYNOPSIS
            Declares a command the booted image runs before the deployment,
            leaving every other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to make a tool RUN in WinPE, and
            the one anything with a Start This button has to run.

            THIS IS THE OTHER HALF OF Add-HDTBootImageContent. Copying BGInfo or
            a VNC server into the image starts nothing: WinPE runs startnet.cmd,
            which brings the network up and then launches the deployment. Content
            that is never launched looks exactly like an image that was never
            changed, and that is the failure this exists to prevent.

            WHERE IT RUNS IS THE POINT. Every command declared here is written
            into startnet.cmd AFTER wpeinit, so a tool that needs a network has
            one, and BEFORE the entry command, because the entry command is the
            deployment and it does not return. Anything queued after it would
            never start.

            THE ORDER IS AN INSTRUCTION, NOT LAYOUT, which is why -First exists
            rather than a plain append. cmd.exe runs these one after another and
            waits for each; a tool that has to stay up while the deployment runs
            is launched with `start`, and that decision belongs to the
            administrator who knows the tool rather than to this command.

            THE DEFAULT IS THE END, the one position that cannot change when
            anything already declared runs.

            IT SPLICES LINES AND NEVER PARSES AND RE-EMITS, and it builds the
            bootImage block when there is none - which is the usual case, because
            New-HDTWorkspace deliberately writes no boot image settings at all.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Command
            The command line, exactly as cmd.exe should see it. Paths inside the
            image are on X:, which is the WinPE RAM disk and the one drive letter
            WinPE guarantees.

        .PARAMETER First
            Run this before everything already declared.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the command added.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            Add-HDTBootImageStartCommand -Line $line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe X:\HDT\Tools\BGInfo\hdt.bgi /timer:0 /nolicprompt'

            The machine's own details on the WinPE desktop, before the
            deployment starts.

        .EXAMPLE
            Add-HDTBootImageStartCommand -Line $line -Command 'start "" X:\HDT\Tools\VNC\winvnc.exe' -First

            A VNC server, started first and left running - `start` because
            cmd.exe waits for anything else.

        .LINK
            Add-HDTBootImageContent

        .LINK
            Remove-HDTBootImageStartCommand
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Command,

        [Parameter()]
        [switch] $First
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Command `
                    -Message 'a start command names something to run. Give the command line exactly as cmd.exe should see it.'))
    }

    if ($Command.IndexOfAny([char[]] @("`r", "`n")) -ge 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Command `
                    -Message 'a start command is one command on one line. A line break here becomes a second command inside startnet.cmd that nobody reading the workspace document would see.'))
    }

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line

    foreach ($current in @($workspace.BootImage.StartCommand)) {
        if ([string] $current -eq $Command) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Command `
                        -Message ("this boot image already runs '{0}'. Running the same command twice is not a thing to ask for by accident." -f $Command)))
        }
    }

    $action = 'Run in WinPE, after the commands already declared'
    if ($First) { $action = 'Run in WinPE, before the commands already declared' }

    if (-not $PSCmdlet.ShouldProcess($Command, $action)) {
        return [string[]] @($Line)
    }

    $text = [string[]] @('- {0}' -f (ConvertTo-HDTRuleScalarText -Value $Command))

    $block = Get-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'startCommand')

    if ($null -ne $block) {
        $result = [string[]] @(Add-HDTWorkspaceItem -Line $Line -Block $block -Text $text -First:$First)
    } else {
        $written = New-Object -TypeName System.Collections.ArrayList
        [void] $written.Add('startCommand:')
        foreach ($current in $text) { [void] $written.Add('  ' + $current) }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'startCommand') `
                -Text ([string[]] @($written)))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}

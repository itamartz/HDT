function Add-HDTBootImageContent {
    <#
        .SYNOPSIS
            Declares a folder or file to be copied into the boot image, leaving
            every other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to put something of their own
            inside the WinPE image, and the one anything with an Add Content
            button has to run - if the command cannot do it, the window cannot do
            it either.

            THIS IS ONE FEATURE, NOT FOUR. A BGInfo build, a VNC server, a vendor
            PowerShell module and a background image are all the same thing: a
            source on the share and a destination inside the image. Every one of
            them is this command, and adding a fifth needs no new code.

            COPYING IS HALF OF IT. Nothing in WinPE starts what lands in the
            image; startnet.cmd runs wpeinit and then the deployment. Run
            Add-HDTBootImageStartCommand for the other half, or the tool is in the
            image and nobody ever sees it.

            THE DESTINATION IS A PATH INSIDE THE IMAGE, rooted at the image and
            not at the machine building it, which is why it must begin with a
            separator. A '..' in it is refused HERE rather than fifteen minutes
            into a build with a WIM mounted - the destination is resolved against
            the mount folder, so one that climbs out of it writes onto the build
            host's own disk.

            THE SOURCE IS RELATIVE TO THE WORKSPACE ROOT unless it is rooted, so
            content committed alongside the share travels with it.

            IT SPLICES LINES AND NEVER PARSES AND RE-EMITS. workspace.yaml is
            created with a comment header explaining deployRoot and the engine
            defaults, and an administrator adds their own notes from there on; a
            parser yields a dictionary and a dictionary has no comments in it.
            Only the lines this entry occupies are new.

            IT BUILDS THE bootImage BLOCK WHEN THERE IS NONE, which is the usual
            case: New-HDTWorkspace deliberately writes no boot image settings at
            all.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share, so an edit can be composed, reviewed and abandoned
            without a file ever changing.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Source
            What to copy, relative to the workspace root unless it is rooted.

        .PARAMETER Destination
            Where it lands inside the image - a path rooted at the image, for
            example \HDT\Tools\BGInfo.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the entry added.

        .EXAMPLE
            Add-HDTBootImageContent -Line $line -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'

        .EXAMPLE
            $line = [System.IO.File]::ReadAllText($path) -split "`r?`n"
            $line = Add-HDTBootImageContent -Line $line -Source 'Tools\VNC' -Destination '\HDT\Tools\VNC'
            $line = Add-HDTBootImageStartCommand -Line $line -Command 'X:\HDT\Tools\VNC\winvnc.exe -service'
            Save-HDTWorkspaceDocument -Path $path -Line $line

            Both halves: the server is copied in, and something starts it.

        .LINK
            Add-HDTBootImageStartCommand

        .LINK
            Save-HDTWorkspaceDocument
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
        [string] $Source,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- what is being asked for ---------------------------------------------

    if ([string]::IsNullOrWhiteSpace($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Source `
                    -Message 'a content entry names what to copy. Give a path relative to the workspace root, such as Tools\BGInfo.'))
    }

    if (-not $Destination.StartsWith('\')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Destination `
                    -Message ("the destination '{0}' does not start with a separator, and a destination is a path inside the image - it is rooted at the image, not at the machine building it. Write it as \HDT\Tools\BGInfo." -f $Destination)))
    }

    if ($Destination -like '*..*') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Destination `
                    -Message ("the destination '{0}' contains '..', which escapes the image and writes onto the machine building it. Name a path under the image root." -f $Destination)))
    }

    # -- what is already there ------------------------------------------------

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line

    foreach ($entry in @($workspace.BootImage.ExtraContent)) {
        if (([string] $entry.Source) -eq $Source -and ([string] $entry.Destination) -eq $Destination) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Destination `
                        -Message ("this document already copies '{0}' to '{1}'. Copying the same content twice is not a thing to ask for by accident; a second source landing on the same destination is allowed, and merges into it." -f $Source, $Destination)))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, ("Copy '{0}' into the boot image" -f $Source))) {
        return [string[]] @($Line)
    }

    # -- the entry ------------------------------------------------------------

    $text = [string[]] @(
        ('- source: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Source))
        ('  destination: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Destination))
    )

    $block = Get-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'extraContent')

    if ($null -ne $block) {
        $result = [string[]] @(Add-HDTWorkspaceItem -Line $Line -Block $block -Text $text)
    } else {
        # THE KEY, THE BLOCK ABOVE IT, OR BOTH. A new sequence is written with
        # its entries indented under the key, which is the shape every
        # hand-written sample in this repository uses.
        $written = New-Object -TypeName System.Collections.ArrayList
        [void] $written.Add('extraContent:')
        foreach ($current in $text) { [void] $written.Add('  ' + $current) }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'extraContent') `
                -Text ([string[]] @($written)))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}

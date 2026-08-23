function Save-HDTWorkspaceDocument {
    <#
        .SYNOPSIS
            Writes an edited workspace document back to the share, after checking
            the engine can still read it.

        .DESCRIPTION
            The Save an administrator runs after editing workspace.yaml, and the
            one anything with a Save button has to run.

            THIS IS THE ONLY WORKSPACE COMMAND THAT TOUCHES THE SHARE. Every
            Add, Set and Remove composes lines in memory, so an edit can be built
            up, looked at and abandoned without a file changing. That is also what
            makes this the right place for the last check.

            IT PARSES BEFORE IT WRITES, USING THE ENGINE'S OWN READER. A splice
            that produced something Import-HDTWorkspaceDocument cannot read must
            fail here, with the file on the share still intact. workspace.yaml is
            the first document read by every deployment and every boot image
            build; a broken one stops both at the first step.

            IT KEEPS THE FILE'S OWN LINE ENDINGS. A save that rewrote every ending
            would show up as a diff touching every line, which is the git-review
            problem the whole splice design exists to avoid, arriving by a
            different route. The existing file decides; a new one gets CRLF,
            because these documents live on Windows shares and are read in WinPE.

            THE SHARE IS WRITTEN THROUGH AN IFileSystem like everything else, so
            this is provable under Pester without a share.

        .PARAMETER Path
            The workspace.yaml to write.

        .PARAMETER Line
            The edited document, as lines.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Saved, Path and Id.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

        .EXAMPLE
            $path = 'C:\HDTLab\Share\workspace.yaml'
            $line = [System.IO.File]::ReadAllText($path) -split "`r?`n"
            $line = Add-HDTBootImageContent -Line $line -Source 'Tools\BGInfo' -Destination '\HDT\Tools\BGInfo'
            $line = Add-HDTBootImageStartCommand -Line $line -Command 'X:\HDT\Tools\BGInfo\bginfo.exe /timer:0'
            Save-HDTWorkspaceDocument -Path $path -Line $line

        .LINK
            Import-HDTWorkspaceDocument

        .LINK
            Update-HDTBootImage
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # -- the file's own line endings ------------------------------------------

    $newLine = "`r`n"

    if ($FileSystem.TestPath($Path)) {
        $existing = [string] $FileSystem.ReadAllText($Path)

        # A lone LF anywhere means the file is not CRLF; a CR always paired with
        # an LF means it is.
        if ($existing -match "[^`r]`n" -or $existing -match "^`n") {
            $newLine = "`n"
        }
    }

    $text = ($Line -join $newLine)

    # -- the engine has to be able to read it ---------------------------------

    # PARSED FROM AN IN-MEMORY COPY, at the real path so any message names the
    # file the administrator is editing. Nothing is written unless this returns.
    $check = New-HDTFileSystemFromText -Path $Path -Text $text

    $document = Import-HDTWorkspaceDocument -Path $Path -FileSystem $check

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the workspace document')) {
        return [pscustomobject] @{
            Saved = $false
            Path  = $Path
            Id    = [string] $document.Id
        }
    }

    $FileSystem.WriteAllText($Path, $text)

    return [pscustomobject] @{
        Saved = $true
        Path  = $Path
        Id    = [string] $document.Id
    }
}

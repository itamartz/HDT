function Save-HDTRuleDocument {
    <#
        .SYNOPSIS
            Writes an edited rules document back to the share, after checking the
            engine can still read it.

        .DESCRIPTION
            The Save an administrator runs after editing rules.yaml, and the one
            anything with a Save button has to run.

            THIS IS THE ONLY RULES COMMAND THAT TOUCHES THE SHARE. Add, Set and
            Remove all compose lines in memory, so an edit can be built up,
            looked at and abandoned without a file changing. That is also what
            makes this the right place for the last check.

            IT PARSES BEFORE IT WRITES, USING THE ENGINE'S OWN READER. A splice
            that produced something Import-HDTRuleDocument cannot read must fail
            here, with the file on the share still intact. The alternative is a
            rules file that every deployment from this share then fails on, and
            rules.yaml is read before anything else happens - a broken one stops
            the deployment at the first screen.

            IT KEEPS THE FILE'S OWN LINE ENDINGS. A save that rewrote every
            ending would show up as a diff touching every line, which is the
            git-review problem the whole splice design exists to avoid, arriving
            by a different route. The existing file decides; a new one gets CRLF,
            because these documents live on Windows shares and are read in WinPE.

            THE SHARE IS WRITTEN THROUGH AN IFileSystem like everything else, so
            this is provable under Pester without a share.

        .PARAMETER Path
            The rules.yaml to write.

        .PARAMETER Line
            The edited document, as lines.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Saved, Path and
            RuleCount.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\rules.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            Save-HDTRuleDocument -Path 'X:\Deploy\rules.yaml' -Line $line

        .EXAMPLE
            $line = [System.IO.File]::ReadAllText($path) -split "`r?`n"
            $line = Add-HDTRule -Line $line -Name 'Fallback naming' -Set @{ HDTComputerName = 'PC-%HDTSerialNumber%' }
            Save-HDTRuleDocument -Path $path -Line $line
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

    # -- the file's own line endings ---------------------------------------

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

    # -- the engine has to be able to read it ------------------------------

    # PARSED FROM AN IN-MEMORY COPY, at the real path so any message names the
    # file the administrator is editing. Nothing is written unless this returns.
    $check = New-HDTFileSystemFromText -Path $Path -Text $text

    $document = Import-HDTRuleDocument -Path $Path -FileSystem $check

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the rules')) {
        return [pscustomobject] @{
            Saved     = $false
            Path      = $Path
            RuleCount = @($document.Rule).Count
        }
    }

    $FileSystem.WriteAllText($Path, $text)

    return [pscustomobject] @{
        Saved     = $true
        Path      = $Path
        RuleCount = @($document.Rule).Count
    }
}

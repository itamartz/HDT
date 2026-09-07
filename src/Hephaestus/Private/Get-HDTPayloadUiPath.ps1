function Get-HDTPayloadUiPath {
    <#
        .SYNOPSIS
            The XAML a staged engine payload declares, rebased off the WinPE RAM
            disk and onto a root that exists on the machine about to run it.

        .DESCRIPTION
            SIX SCREENS SHIPPED BROKEN AT ONCE, AND THE SEVENTH WOULD HAVE.
            Start-HDTDeployment.ps1 takes every window it draws as a parameter -
            WizardShellPath, WizardThemePath, ProgressXamlPath, FailureXamlPath,
            WelcomeXamlPath, BootStatusXamlPath - each defaulted to X:\HDT\UI\.
            That default is exactly right on the leg it was written for:
            Update-HDTBootImage stages src\Hephaestus\UI\ to \HDT\UI inside the
            image, WinPE boots with its system drive at X:, and the letter is
            fixed because the RAM disk's letter always is.

            IT IS ALSO THE ONE THING A REFRESH CANNOT INHERIT. The full-OS
            launcher runs the SAME file on a machine that never booted a WIM, so
            X: is not a drive at all, and every one of those windows had no file
            to load - the wizard, the progress board, the failure screen, the
            welcome screen and the boot status panel, silently, on the leg that
            has an administrator standing in front of it.

            AND THE SET IS READ, NEVER LISTED. The defect was not six wrong
            values; it was that the set of screens lived in the payload's param
            block and a caller kept a second copy of it - CLAUDE.md rule 8's
            "a copy loop naming files one by one is a second source of truth and
            the two will disagree". So this parses the param block of the very
            file it is about to hand over to, and rebases whatever it finds. A
            seventh screen added to the payload tomorrow is answered by this
            function on the day it is added, with nothing else edited.

            WHAT IT MATCHES AND WHAT IT DELIBERATELY DOES NOT. Only a default
            rooted at X:\HDT\UI\ with a single leaf under it. BootstrapPath and
            ModuleRoot are X:-rooted too and are answered elsewhere and
            differently - one is a document the run writes onto the machine, the
            other is the share - so sweeping them in would put the engine in the
            wrong folder. A future default somewhere else under X: is NOT matched
            either, and that is on purpose: the contract test compares this
            function's answer against every X:-rooted default the payload has, so
            an unmatched one fails the gate rather than being quietly rebased to
            a folder it was never in.

            THE PAYLOAD IS READ THROUGH IFileSystem, so a fake can hand it any
            param block at all - which is what lets the "a screen nobody wrote
            down" test be written.

        .PARAMETER PayloadPath
            The engine entry point about to be run - <share>\Modules\Hephaestus\
            Payload\Start-HDTDeployment.ps1 for a Refresh. Its param block is the
            source of truth for which screens exist.

        .PARAMETER UiRoot
            The folder the screens are to be read from on this machine. For a
            Refresh that is the UI\ folder of the engine already staged on the
            share, beside the payload itself.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one; a test passes
            New-HDTFakeFileSystem.

        .INPUTS
            None. This function does not accept pipeline input.

        .OUTPUTS
            System.Collections.Hashtable. Parameter name to rebased path, ready
            to splat onto the payload. Empty for a payload that declares none -
            an older share is still allowed to start a Refresh.

        .EXAMPLE
            Get-HDTPayloadUiPath -PayloadPath 'Q:\Share\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1' `
                -UiRoot 'Q:\Share\Modules\Hephaestus\UI'

            @{ WizardShellPath = 'Q:\Share\Modules\Hephaestus\UI\HDTWizardShell.xaml'; ... }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $PayloadPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $UiRoot,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $map = @{}

    # WHERE THE BOOT IMAGE PUTS THEM, and the only prefix this rebases.
    # Update-HDTBootImage stages src\Hephaestus\UI\ to \HDT\UI inside the image,
    # and WinPE boots with its system drive at X: - so this is the literal every
    # screen in the payload is defaulted to, named once here rather than spelled
    # again per parameter.
    $ramDiskUiRoot = 'X:\HDT\UI'

    # AN OLDER SHARE IS NOT AN ERROR. The engine staged on a share is whatever
    # somebody copied there, and a launcher that threw here would refuse to start
    # a Refresh that would otherwise have run - with console output instead of
    # windows, which Start-HDTProgressDisplay already degrades to and says so.
    if (-not $FileSystem.TestPath($PayloadPath)) {
        Write-Verbose ("Get-HDTPayloadUiPath: '{0}' does not exist, so no screen is rebased." -f $PayloadPath)
        return $map
    }

    $text = [string] $FileSystem.ReadAllText($PayloadPath)

    # ParseInput RATHER THAN ParseFile, because the text came through the adapter
    # and the adapter is what a fake replaces. ParseFile would read the disk
    # again and the fake would never be consulted.
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $null)

    if ($null -eq $ast.ParamBlock) {
        Write-Verbose ("Get-HDTPayloadUiPath: '{0}' declares no param block, so no screen is rebased." -f $PayloadPath)
        return $map
    }

    foreach ($parameter in @($ast.ParamBlock.Parameters)) {

        if ($null -eq $parameter.DefaultValue) { continue }

        $default = ([string] $parameter.DefaultValue.Extent.Text).Trim("'`"")

        # X:\HDT\UI\<one leaf>, MATCHED WITHOUT A REGEX. That pattern needs an
        # escaped backslash either side of a character class, which is the kind
        # of line that is wrong in one character and still parses - it was, and
        # it silently matched nothing at all. -like and [IO.Path] say the same
        # thing and either work or do not. Both comparisons are case-insensitive
        # because a param block is somebody's typing.
        if ($default -notlike ($ramDiskUiRoot + '\*')) { continue }

        $leaf = [string] [System.IO.Path]::GetFileName($default)
        if ([string]::IsNullOrWhiteSpace($leaf)) { continue }

        # AND IT MUST BE THAT FOLDER ITSELF, not a tree beneath it. A default one
        # level deeper is deliberately left unmatched: the contract test compares
        # this answer against every X:-rooted default the payload has, so an
        # unmatched one fails the gate instead of being quietly rebased into a
        # folder it was never in. See the description.
        $directory = [string] [System.IO.Path]::GetDirectoryName($default)
        if (-not $directory.Equals($ramDiskUiRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $name = [string] $parameter.Name.VariablePath.UserPath

        # [IO.Path]::Combine, NEVER Join-Path. The share is routinely a UNC path
        # or a drive this session has not mounted, and the provider-aware cmdlets
        # resolve it - the DriveNotFound trap CLAUDE.md rule 8 names. It is also
        # what makes this line provable against a fake at all.
        $map[$name] = [System.IO.Path]::Combine($UiRoot, $leaf)

        Write-Verbose ("Get-HDTPayloadUiPath: -{0} '{1}' is on the WinPE RAM disk and is answered with '{2}'." -f
            $name, $default, $map[$name])
    }

    return $map
}

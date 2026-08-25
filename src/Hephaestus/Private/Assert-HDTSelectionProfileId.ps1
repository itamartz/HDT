function Assert-HDTSelectionProfileId {
    <#
        .SYNOPSIS
            Refuses an id or an include path an editor must not write.

        .DESCRIPTION
            THE SAME RULES THE VALIDATOR APPLIES, APPLIED BEFORE THE WRITE. A
            console that writes a document and then reports it unreadable has
            left a broken file on the share and taken an administrator's edit
            with it, so New- and Set- check what they are about to splice rather
            than discovering it on the next load.

            IT TAKES THE CALLER'S $PSCmdlet so the terminating error comes from
            the command an administrator actually typed. A refusal reported
            against a private helper names a function that is not in their
            session and cannot be looked up.

            THE ID PATTERN AND THE RESERVED LIST are read from the same two
            places Assert-HDTSelectionProfileDocument reads them from, so an
            editor and the loader cannot come to disagree about what a legal
            profile is.

        .PARAMETER Id
            The profile id to check.

        .PARAMETER Include
            The include paths to check. Omitted, none are checked - which is what
            Set- passes when it is only renaming.

        .PARAMETER Root
            The deployment share, when the caller can see one. Supplied, EVERY
            include must be a folder that is actually there.

        .PARAMETER FileSystem
            The IFileSystem to check -Root with.

        .PARAMETER Cmdlet
            The calling command's $PSCmdlet, so the error is thrown as its own.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTSelectionProfileId -Id 'boot-critical' -Include 'Drivers\WinPE\Dell WinPE 11 x64' -Cmdlet $PSCmdlet
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Include = @(),

        [Parameter()]
        [AllowEmptyString()]
        [string] $Root = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem = $null,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Cmdlet
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is not a legal profile id. An id starts with a letter or a digit and carries only letters, digits, dot, dash and underscore." -f $Id)))
    }

    $reserved = @(Get-HDTSelectionProfileBuiltIn | ForEach-Object { [string] $_.Id })

    if ($reserved -contains $Id) {
        $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is a built-in profile and has no lines in any document. The built-in ids are {1}." -f $Id, ($reserved -join ', '))))
    }

    $check = $FileSystem
    if (($null -eq $check) -and (-not [string]::IsNullOrWhiteSpace($Root))) { $check = New-HDTFileSystem }

    foreach ($current in @($Include)) {
        $failure = Get-HDTSelectionProfilePathFailure -Include ([string] $current)

        if (-not [string]::IsNullOrEmpty($failure)) {
            $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current `
                        -Message ("'{0}' cannot be included: {1}" -f $current, $failure)))
        }

        # A FOLDER THAT IS NOT THERE IS NOT A CHOICE. The console's tree offers
        # only folders the share actually has, so a profile written through the
        # window cannot name one that does not exist - and a command that let
        # somebody type one anyway would put a boot image on a bench with a
        # vendor's drivers silently absent.
        #
        # ONLY WHEN A SHARE WAS NAMED. A profile is legitimately authored on a
        # workstation against a UNC path nobody has mounted; with no -Root there
        # is nothing to check against and the document's own reader reports a
        # missing folder later, on the tab and in the build's warning.
        if ($null -eq $check) { continue }

        $full = [System.IO.Path]::Combine($Root, ([string] $current).TrimStart('\', '/'))

        if (-not $check.TestPath($full)) {
            $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $current `
                        -Path $full -Category ObjectNotFound `
                        -Message ("'{0}' is not a folder on this share, so it cannot be included. A profile names folders that exist; import the drivers first, or tick a folder in the console's profile tree." -f $current)))
        }
    }
}

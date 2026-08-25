function New-HDTSelectionProfile {
    <#
        .SYNOPSIS
            Adds a selection profile to a document, leaving every other line
            byte-identical.

        .DESCRIPTION
            The command behind the console's New button, and the one an
            administrator types to give a mixed floor one boot image: a profile
            naming the Dell WinPE pack and the HP WinPE pack together is what
            'drivers: <folder>' could never say.

            IT SPLICES, IT DOES NOT RE-SERIALISE. Parsing the document and
            writing it back would lose every comment in it, and
            Control\selection-profiles.yaml is a file people explain their fleet
            in.

            AN EMPTY -Line MEANS THERE IS NO DOCUMENT YET, and it writes a whole
            one. New-HDTWorkspace deliberately creates no
            selection-profiles.yaml - a share with no authored profile uses the
            built-ins - so the first profile anybody adds has to be able to
            create the file it goes in. Refusing here would mean hand-writing a
            document before the console could write one.

            THE INCLUDE PATHS ARE CHECKED AT THE POINT THEY ARE TYPED, not only
            when the document is next loaded. A console that writes a document
            and then reports it unreadable has left a broken file on the share -
            and a traversal is the one mistake here that ends up inside a WIM
            transferred to every machine that PXE boots.

            AND WITH -Root, A FOLDER THAT IS NOT THERE IS REFUSED OUTRIGHT. The
            console's tree offers only folders the share actually has, so a
            profile written through the window cannot name one that does not
            exist; this is what stops the command line being the weaker door.
            Without -Root there is nothing to check against - a profile is
            legitimately authored against a UNC path nobody has mounted - and
            the missing folder is then reported by the tab and by the build.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTSelectionProfileDocument
            is what touches the share.

        .PARAMETER Line
            The document, already split into lines. Empty for a share that has
            none.

        .PARAMETER Id
            What workspace.yaml and a sequence step will name this profile by.

        .PARAMETER Name
            What the console's picker shows.

        .PARAMETER Include
            The share-relative folders, in the order they should be injected.
            Omitted, the profile includes nothing yet.

        .PARAMETER Root
            The deployment share. Supplied, every include must be a folder that
            is actually on it.

        .PARAMETER FileSystem
            The IFileSystem to check -Root with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the profile in it.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\Control\selection-profiles.yaml'))
            $line = New-HDTSelectionProfile -Line $line -Id 'boot-critical' -Name 'Boot critical - Dell and HP' -Include 'Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64'
            Save-HDTSelectionProfileDocument -Path 'C:\HDTLab\Share\Control\selection-profiles.yaml' -Line $line

            One boot image that sees a Dell disk and an HP network card.

        .EXAMPLE
            $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'dell-winpe' -Name 'Dell WinPE 11 x64'

            The first profile on a share that has no document, with its folders
            still to be picked.

        .LINK
            Set-HDTSelectionProfile

        .LINK
            Save-HDTSelectionProfileDocument
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
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 3)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Include = @(),

        # THE SHARE, WHEN THE CALLER CAN SEE ONE. Supplied, every include must be
        # a folder that is actually there - which is what stops a profile naming
        # a vendor pack nobody has imported. The console always supplies it,
        # because its tree only offers folders the share has.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Root = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string[]] @($Line)

    Assert-HDTSelectionProfileId -Id $Id -Include $Include -Root $Root -FileSystem $FileSystem -Cmdlet $PSCmdlet

    $map = Get-HDTSelectionProfileLineMap -Line $text

    if (@($map.Entry | Where-Object { $_.Id -eq $Id }).Count -gt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("this document already declares a profile with the id '{0}'. Use Set-HDTSelectionProfile to change it." -f $Id)))
    }

    if (-not $PSCmdlet.ShouldProcess($Id, 'Add this selection profile')) {
        return [string[]] $text
    }

    # -- a share with no document at all --------------------------------------

    if ($map.ListIndex -lt 0) {
        $header = [string[]] @(
            '# Selection profiles - the named sets of share folders a boot image,'
            '# a task sequence driver step and standalone media point at.'
            'schemaVersion: 1'
            'profiles:'
        )

        # A document that had OTHER content but no profiles: key is a document
        # somebody is part way through writing. Its lines are kept and the list
        # is added under them.
        if (@($text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            $header = [string[]] @($text + @('profiles:'))
        }

        return [string[]] @($header + (ConvertTo-HDTSelectionProfileLine -Id $Id -Name $Name `
                    -Include $Include -Indent 2))
    }

    $entryLine = ConvertTo-HDTSelectionProfileLine -Id $Id -Name $Name -Include $Include -Indent $map.Indent

    # 'profiles: []' has to become 'profiles:' before anything can be nested
    # under it, or the entry below would be a second value for the same key.
    $result = New-Object -TypeName System.Collections.ArrayList
    $inserted = $false

    for ($i = 0; $i -lt $text.Count; $i++) {
        if (($i -eq $map.ListIndex) -and $map.ListInline) {
            [void] $result.Add(($text[$i] -replace '^(\s*profiles\s*:).*$', '$1'))
        } else {
            [void] $result.Add($text[$i])
        }

        if ($i -eq ($map.InsertAt - 1)) {
            foreach ($current in $entryLine) { [void] $result.Add($current) }
            $inserted = $true
        }
    }

    # A document whose last line IS the insertion point has already had the entry
    # added by the loop; this is only for one that ends before it - 'profiles:'
    # as the final line, with nothing after it to iterate onto.
    if (-not $inserted) {
        foreach ($current in $entryLine) { [void] $result.Add($current) }
    }

    return [string[]] @($result)
}

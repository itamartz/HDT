function Get-HDTConsoleFieldBrowse {
    <#
        .SYNOPSIS
            Which dialog a browsing field opens, and what it is seeded with.

        .DESCRIPTION
            THE ONE PLACE A BROWSE KIND BECOMES A DIALOG. New-HDTConsoleField
            lets a row DECLARE that its value is picked off the disk; this says
            what that declaration means. Keeping the two apart is what makes the
            decision testable: the click handler in New-HDTConsoleView is an
            adapter over a modal dialog and no Pester test can open one, so a
            handler that also decided the title, the filter and the seed would
            be deciding it where nothing can read it.

            IT IS PURE, AND STAYS PURE. No WPF type is touched here and the disk
            is never consulted - the folder a path names may not exist yet, and
            asking whether it does would make this untestable against a fake.
            [System.IO.Path] and never Split-Path, for the same reason
            Get-HDTWorkspacePath uses [IO.Path]::Combine: Split-Path resolves
            the drive and throws on one nothing has mounted.

            A SAVE DIALOG AND NOT AN OPEN ONE, for the ISO. Update-HDTMediaContent
            is what CREATES the file the Output box names, so the path a
            technician wants to give it is a path to a file that does not exist -
            and OpenFileDialog's CheckFileExists would refuse the one legal
            answer. New-HDTConsoleHost's New Media dialog made exactly this
            decision for exactly this key, with the reasoning written above its
            own picker; this is the other door to the same box and it gets the
            same control. BrowseForFolder, the driver import's precedent, picks
            a FOLDER that exists and is wrong on both counts.

            AND IT SEEDS FROM THE ROW AND NOWHERE ELSE. New-HDTMedia owns the
            Media\<id>\HDT_<id>.iso default; a picker that proposed it would
            turn "left empty on purpose" into a path somebody never chose. An
            empty value seeds nothing, and so does a value that is not rooted -
            a share-relative path is resolved by the command, not by a dialog
            that would have to guess which share.

        .PARAMETER Kind
            What the field declared it picks. The same closed set
            New-HDTConsoleField's -Browse accepts, and the contract asserts this
            command answers every member of it.

        .PARAMETER Current
            What the row holds now, which is the only thing the dialog is seeded
            from. May be empty.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Dialog, Title,
            Filter, FileName and Directory.

        .EXAMPLE
            Get-HDTConsoleFieldBrowse -Kind 'IsoFile' -Current 'C:\ws\Media\HYDRA\HDT_HYDRA.iso'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('IsoFile')]
        [string] $Kind,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Current = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fileName = ''
    $directory = ''

    # ROOTED OR NOTHING. A relative path in the document is share-relative, and
    # which share is not a question a file dialog can answer - so it is left
    # unseeded rather than seeded wrongly, and the picker opens where Windows
    # last left it.
    if (-not [string]::IsNullOrWhiteSpace($Current) -and [System.IO.Path]::IsPathRooted($Current)) {
        $fileName = [string] [System.IO.Path]::GetFileName($Current)
        $directory = [string] [System.IO.Path]::GetDirectoryName($Current)
    }

    switch ($Kind) {

        'IsoFile' {
            return [pscustomobject] @{
                Dialog    = 'Save'
                Title     = 'Choose where the ISO is written'
                Filter    = 'ISO image (*.iso)|*.iso|All files (*.*)|*.*'
                FileName  = $fileName
                Directory = $directory
            }
        }

        # THE DAY THE SET GROWS AND THIS DOES NOT, the failure names itself
        # rather than returning $null into a handler that would then read a
        # property off nothing. The contract sweep is what makes this
        # unreachable; this is what it looks like when it is not.
        default {
            throw (New-Object System.ArgumentException (
                    "'{0}' is a browse kind no dialog has been decided for. Get-HDTConsoleFieldBrowse is the one place that decision lives." -f $Kind))
        }
    }
}

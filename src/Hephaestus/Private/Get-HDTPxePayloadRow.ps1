function Get-HDTPxePayloadRow {
    <#
        .SYNOPSIS
            The declared table of files a non-WDS PXE payload contains.

        .DESCRIPTION
            DESIGN 6.1's list, as data rather than as prose: bootmgr,
            bootmgfw.efi, boot.sdi, the BCD, the fonts, the boot WIM and its
            manifest.

            IT IS PURE, AND IT IS THE ONLY COPY OF THE LIST. New-HDTPxePayload
            stages exactly these rows and -ListRequired hands them straight back,
            so the tests check completeness against the command's own
            declaration rather than against a second list that could drift from
            it. That is the whole reason this is a separate function.

            TWO VOCABULARIES MEET HERE, and conflating them is the mistake this
            comment exists to prevent. The ADK calls the 64-bit target amd64 and
            lays its media out under
            'Windows Preinstallation Environment\amd64\Media'; the PXE tree
            convention - the one WDS itself uses, and the one a TFTP root is
            expected to have - calls it x64 and puts the files under Boot\x64.
            So -Architecture is the ADK's word and the destination folder is the
            PXE tree's.

            TWO RENAMES ARE PART OF THE TABLE, not accidents:

              bootmgr      -> bootmgr.exe    the BIOS boot manager, which a TFTP
                                             root serves under the .exe name
              bootmgr.efi  -> bootmgfw.efi   the UEFI boot manager, which the
                                             firmware asks for by that name

            wdsmgfw.efi IS OPTIONAL. It is EFI\Boot\bootx64.efi under another
            name, and a site's stack may want either; this command does not know
            which, so its absence does not make the payload incomplete.

        .PARAMETER Architecture
            amd64 (default) or arm64, in the ADK's vocabulary.

        .PARAMETER BootImageName
            The boot image base name, HDTPE_x64 by default.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per row: Destination
            (relative to the payload root), Source (relative to its origin),
            Origin (AdkMedia or Workspace), Required, Kind (File or Directory).

        .EXAMPLE
            Get-HDTPxePayloadRow -Architecture amd64 -BootImageName 'HDTPE_x64'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootImageName = 'HDTPE_x64'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The PXE tree's word for the ADK's amd64. See the help.
    $folder = 'x64'
    if ($Architecture -eq 'arm64') { $folder = 'arm64' }

    $boot = [System.IO.Path]::Combine('Boot', $folder)

    $row = New-Object -TypeName System.Collections.ArrayList

    $add = {
        param([string] $Destination, [string] $Source, [string] $Origin, [bool] $Required, [string] $Kind)

        [void] $row.Add([pscustomobject] @{
                Destination = $Destination
                Source      = $Source
                Origin      = $Origin
                Required    = $Required
                Kind        = $Kind
            })
    }

    & $add ([System.IO.Path]::Combine($boot, 'bootmgr.exe')) 'bootmgr' 'AdkMedia' $true 'File'
    & $add ([System.IO.Path]::Combine($boot, 'wdsmgfw.efi')) ([System.IO.Path]::Combine('EFI', 'Boot', 'bootx64.efi')) 'AdkMedia' $false 'File'
    & $add ([System.IO.Path]::Combine($boot, 'bootmgfw.efi')) 'bootmgr.efi' 'AdkMedia' $true 'File'
    & $add ([System.IO.Path]::Combine($boot, 'boot.sdi')) ([System.IO.Path]::Combine('Boot', 'boot.sdi')) 'AdkMedia' $true 'File'
    & $add ([System.IO.Path]::Combine($boot, 'BCD')) ([System.IO.Path]::Combine('Boot', 'BCD')) 'AdkMedia' $true 'File'
    & $add ([System.IO.Path]::Combine($boot, 'Fonts')) ([System.IO.Path]::Combine('Boot', 'Fonts')) 'AdkMedia' $true 'Directory'
    & $add ([System.IO.Path]::Combine($boot, 'Images', ('{0}.wim' -f $BootImageName))) ([System.IO.Path]::Combine('Boot', ('{0}.wim' -f $BootImageName))) 'Workspace' $true 'File'
    & $add ([System.IO.Path]::Combine($boot, ('{0}.manifest.json' -f $BootImageName))) ([System.IO.Path]::Combine('Boot', ('{0}.manifest.json' -f $BootImageName))) 'Workspace' $true 'File'

    return [pscustomobject[]] @($row)
}

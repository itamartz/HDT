function Import-HDTDriverArchive {
    <#
        .SYNOPSIS
            Expands a vendor driver archive straight into the driver store.

        .DESCRIPTION
            The half of Import-HDTDriver that handles what vendors actually
            ship: Dell's .cab, HP's self-extracting SoftPaq .exe.

            IT EXPANDS INTO THE DESTINATION, NOT INTO A TEMP FOLDER. A temp
            expansion would mean copying the whole tree a second time - a driver
            pack is hundreds of megabytes - and would leave a directory to clean
            up on every failure path. The cost of expanding in place is that a
            FAILED expansion leaves the folder behind, so a failed expansion
            removes it: this command created it in this run, which is the only
            thing in this module allowed to delete on the share.

            IT CHECKS AFTERWARDS, BECAUSE AN ARCHIVE CANNOT BE COUNTED BEFORE IT
            IS OPEN. A cab that expands to no .inf is a cab that was not a driver
            pack - a firmware bundle, a diagnostic tool - and leaving that in the
            store would be exactly the silent-empty-folder failure the .inf count
            exists to prevent.

            THE EXIT CODE IS NOT TRUSTED ON ITS OWN. HP SoftPaqs return non-zero
            for reasons that are not failures, and expand.exe returns zero having
            copied one file when '-F:*' is missing. What decides is whether .inf
            files are on disk afterwards.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            Where to put them, relative to Drivers\.

        .PARAMETER Source
            What the administrator chose - a folder or the archive itself. Used
            for messages.

        .PARAMETER Kind
            Cab, Exe or Zip, as Get-HDTDriverSourceKind decided.

        .PARAMETER Archive
            The file to expand.

        .PARAMETER FileSystem
            The IFileSystem to write with.

        .PARAMETER Process
            The IProcessService to run the expander with.

        .PARAMETER Cmdlet
            The calling command's $PSCmdlet, so a refusal is thrown as its own
            and ShouldProcess answers to the caller's -WhatIf.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FullPath,
            Source and DriverCount.

        .EXAMPLE
            Import-HDTDriverArchive -Root 'C:\S' -Path 'WinPE\Dell' -Source 'D:\p' -Kind 'Cab' -Archive 'D:\p\dell.cab' -FileSystem $fs -Process $p -Cmdlet $PSCmdlet

        .LINK
            Get-HDTDriverExpandCommand
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Source,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Kind,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Archive,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [object] $FileSystem,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [object] $Process,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [object] $Cmdlet
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Kind -eq 'Empty') {
        $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category InvalidData `
                    -Message ("'{0}' holds no drivers and nothing that can be expanded into any. Point at an extracted driver folder, a vendor .cab, or a self-extracting .exe." -f $Source)))
    }

    $folder = New-HDTDriverFolder -Root $Root -Path $Path -FileSystem $FileSystem -Confirm:$false `
        -WhatIf:$WhatIfPreference

    $full = [string] $folder.FullPath

    $run = Get-HDTDriverExpandCommand -Kind $Kind -Archive $Archive -Destination $full

    if (-not $Cmdlet.ShouldProcess($full, ("Expand '{0}' into the driver store" -f
                [System.IO.Path]::GetFileName($Archive)))) {

        return [pscustomobject] @{ Path = $Path; FullPath = $full; Source = $Source; DriverCount = 0 }
    }

    # A KIND WITH NO PROGRAM BEHIND IT IS REFUSED, NOT GUESSED AT. .zip is
    # recognised so the message can name it, but expanding one would need an
    # IFileSystem method that does not exist - and inventing one here, in the
    # engine, to open an archive is how a file-system service grows a zip
    # library. Windows' own Explorer or Expand-Archive does it in one step.
    if ([string]::IsNullOrWhiteSpace($run.FilePath)) {
        $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Archive `
                    -Category InvalidData `
                    -Message ("'{0}' is a .zip, and HDT expands only .cab and self-extracting .exe packs. Expand it and import the folder." -f
                        [System.IO.Path]::GetFileName($Archive))))
    }

    # TEN MINUTES. A SoftPaq extracting three hundred megabytes onto a share is
    # slow, and a timeout firing mid-expansion leaves a half tree that looks
    # like a driver folder.
    [void] $Process.Start([string] $run.FilePath, [string] $run.Argument, $full, 600000)

    # WHAT IS ON DISK DECIDES, NOT THE EXIT CODE. HP SoftPaqs return non-zero for
    # reasons that are not failures, and expand.exe returns zero having copied
    # one file when -F:* is missing.
    $infCount = Measure-HDTDriverInf -Path $full -FileSystem $FileSystem

    if ($infCount -eq 0) {
        # THIS COMMAND MADE THE FOLDER IN THIS RUN, so this command removes it.
        # Leaving it is the silent-empty-folder failure the count exists to
        # prevent: a profile ticks it and a boot image injects nothing.
        try { $FileSystem.RemoveItem($full, $true) } catch {
            Write-Verbose ("the folder could not be cleaned up after a failed expansion: {0}" -f
                [string] $_.Exception.Message)
        }

        $Cmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Archive `
                    -Category InvalidData `
                    -Message ("'{0}' expanded to no .inf files, so it is not a driver pack. Nothing was left on the share." -f
                        [System.IO.Path]::GetFileName($Archive))))
    }

    return [pscustomobject] @{
        Path        = $Path
        FullPath    = $full
        Source      = $Source
        DriverCount = $infCount
    }
}

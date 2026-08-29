function Copy-HDTDriverPackage {
    <#
        .SYNOPSIS
            Copies one driver package onto the deployed machine.

        .DESCRIPTION
            Copies a driver folder - the .inf and every file beside and below
            it - to a folder on the applied OS volume, and answers with how many
            files it moved. ApplyDrivers stages each matched package this way
            and the answer file's DriverPaths points Windows at the result, so
            the drivers install at first boot from the machine's own disk.

            IT COPIES INSTEAD OF INJECTING, AND THE DIFFERENCE IS MEASURED. The
            step used to call Add-WindowsDriver once per driver; every call
            opens the offline image, adds one package and commits it. On a
            Latitude 5490 that was 82 drivers in 649 seconds, a median of nine
            seconds each - almost all of it the servicing session rather than
            the driver. A file copy of the same packages is seconds, and it is
            what MDT's ZTIDrivers has always done.

            THE WHOLE FOLDER, BECAUSE THAT IS WHAT A DRIVER IS. An .inf names
            the .sys, .cat and .dll files beside it and in its architecture
            subfolders. Copying the .inf alone stages something Windows cannot
            install and reports success for it.

            IT WALKS RATHER THAN RECURSES, because IFileSystem.CopyItem takes
            one file and GetChildItem does not recurse - the same breadth-first
            walk Copy-HDTLog uses to mirror a log tree, and for the same reason:
            a directory is told apart from a file by asking for its length.

        .PARAMETER Source
            The package folder on the share.

        .PARAMETER Destination
            Where it lands on the OS volume.

        .PARAMETER FileSystem
            An IFileSystem.

        .PARAMETER OnProgress
            Called after each file with Source, Done, Total and Percent. Omitted,
            the copy is silent - which is what it was on the deployment that made
            this necessary: 48 seconds staging a Dell pack, one log line, written
            at the end.

            A CALLBACK RATHER THAN A LOG WRITE. This command has no log context
            and should not grow one; the step decides what the record is called
            and how often to write it, which is DESIGN 11.1's single source of
            truth for what a deployment is doing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Source,
            Destination, FileCount, InfCount and ByteCount.

        .EXAMPLE
            Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' -Destination 'W:\Drivers\Win11\Dell\Net'

            Source      : Z:\Deploy\Drivers\Win11\Dell\Net
            Destination : W:\Drivers\Win11\Dell\Net
            FileCount   : 4
            InfCount    : 1
            ByteCount   : 28

            THE .inf COUNT IS THE ONE THAT MAPS TO DEVICES. The Latitude 5490
            pack on the lab share is 126 .inf files, 1302 files and 3.72 GB, and
            a log that reports only the 1302 is reporting .sys, .cat, .dll and
            the vendor's documentation.

        .EXAMPLE
            $package = 'Z:\Deploy\Drivers\Win11\Dell Inc.\Latitude 5490'
            $target = 'W:\Drivers\Win11\Dell Inc.\Latitude 5490'
            Copy-HDTDriverPackage -Source $package -Destination $target -FileSystem (New-HDTFileSystem) `
                -OnProgress { param($P) Write-Verbose ('{0}%' -f $P.Percent) } -Verbose

            The same copy, saying how far through it is. The denominator comes
            from a walk taken before the first file moves, so the percentage is
            counted rather than guessed from elapsed time.

        .EXAMPLE
            $staged = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem (New-HDTFileSystem)

            if ($staged.FileCount -eq 0) { 'nothing was staged' }

            A package that copied nothing will not install, and the count is
            what says so.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        # NOT MANDATORY - DESIGN 13.2.1. An injected service defaults to the real
        # adapter so a plain Import-Module session can call this; making it
        # mandatory would mean every caller had to build one to copy a folder.
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        # WHAT SOMEBODY SEES WHILE THIS RUNS, and until now that was nothing.
        # Staging the Latitude 5490 pack took 48 seconds on a real deployment and
        # wrote one log line, at the end. Worse than a still bar: the progress
        # card's elapsed clock is derived from the FIRST AND LAST record in the
        # log, so a step that says nothing stops the clock for the whole
        # deployment.
        #
        # A CALLBACK RATHER THAN A LOG WRITE, because this command has no log
        # context and should not grow one - the STEP owns what a record is called
        # and at what stride it is written (DESIGN 11.1: one source of truth).
        # This only says how far along it is.
        [Parameter()]
        [AllowNull()]
        [scriptblock] $OnProgress
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category ObjectNotFound `
                    -Message 'the driver package is not on the share, so nothing would be staged and the machine would deploy without it.'))
    }

    $root = $Destination.TrimEnd('\', '/')
    $FileSystem.CreateDirectory($root)

    # WALKED FIRST, THEN COPIED, AND THE WALK IS WHY THE PERCENTAGE CAN BE
    # HONEST. Discovering files as it copied meant the denominator was unknown
    # until the end, so the only progress available would have been elapsed time
    # dressed up as a fraction. A walk is directory metadata - 1302 stats against
    # 48 seconds of actual copying - and it buys an exact total, the .inf count
    # and the byte count in the same pass.
    $file = @(Get-HDTDriverPackageFile -Path $Source -FileSystem $FileSystem)

    $total = $file.Count
    $infCount = @($file | Where-Object { $_.IsInf }).Count
    $byteCount = [long] 0
    foreach ($one in $file) { $byteCount += [long] $one.Length }

    $fileCount = 0

    foreach ($one in $file) {
        $FileSystem.CopyItem($one.FullPath, ('{0}\{1}' -f $root, $one.RelativePath))
        $fileCount++

        if ($null -eq $OnProgress) { continue }

        # THE DENOMINATOR IS THE WALK'S, so this cannot exceed 100 - and a
        # package that walked to nothing never gets here at all.
        $percent = 100
        if ($total -gt 0) {
            $percent = [int] [System.Math]::Floor(($fileCount / $total) * 100)
        }

        & $OnProgress ([pscustomobject] @{
                Source  = $Source
                Done    = [int] $fileCount
                Total   = [int] $total
                Percent = [int] $percent
            })
    }

    return [pscustomobject] @{
        Source      = $Source
        Destination = $root
        FileCount   = $fileCount
        # THE .inf COUNT IS THE ONE THAT MAPS TO DEVICES. 1302 files is .sys,
        # .cat, .dll and documentation; 126 .inf files is what Windows reads.
        InfCount    = [int] $infCount
        ByteCount   = [long] $byteCount
    }
}

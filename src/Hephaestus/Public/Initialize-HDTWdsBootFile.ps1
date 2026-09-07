function Initialize-HDTWdsBootFile {
    <#
        .SYNOPSIS
            Stages the UEFI network boot program that WDS on Windows Server 2025
            creates a directory for and then does not put anything in.

        .DESCRIPTION
            THE DEFECT, observed on this lab's HDT-WDS-01 on 2026-09-02 and found
            the only way it can be found - by watching a VM fail:

              * wdsutil /initialize-server on Server 2025 creates
                <RemoteInstall>\Boot\x64uefi\ and puts EXACTLY ONE FILE in it:
                default.bcd. There is no network boot program in it at all;
              * a Generation 2 client broadcasts and WDS ANSWERS. The server logs
                event 4096, "The following client booted from PXE", with the
                client's MAC and address. By every server-side measure it worked;
              * the client prints "Start PXE over IPv4." and about five seconds
                later the firmware reports "A boot image was not found";
              * and wdsutil /get-server /show:config REPORTS "Boot files
                installed: x64uefi - Yes" THE WHOLE TIME.

            EVERY DIAGNOSTIC ON THE SERVER SAYS THE SERVER IS FINE, which is why
            this is a command with a comment this long rather than a line in
            somebody's runbook. A missing NBP is indistinguishable from a server
            that never answered, and the server's own account of itself is the
            part that misleads.

            WHY. WDS serves a UEFI x64 client out of <RemoteInstall>\Boot\x64uefi,
            NOT out of Boot\x64 - which holds the BIOS boot programs, pxeboot.com
            and wdsnbp.com. The client is told to fetch a file TFTP does not have.

            NOTHING IS DOWNLOADED. The files are already on the machine, one
            directory away, in WDS's own source tree at
            %SystemRoot%\System32\RemInst\boot\<arch>. This copies what the role
            already installed into the place the role failed to put it.

            ON THE NAME, because the documentation and the machine disagree: the
            UEFI NBP is wdsmgfw.efi, and Boot\x64 on Server 2025 ALSO contains
            BOOTMGFW.EFI, which is a different file - 1,095,072 bytes against
            2,759,624. Both are staged so that a client asking for either name is
            served.

            IT IS ADDITIVE AND IDEMPOTENT, BECAUSE A RESUME MUST NOT UNDO A
            SERVER. The engine checkpoints across reboots and can re-enter a
            step; a file already in place is left exactly as it is and reported
            in AlreadyPresent rather than overwritten, so a server somebody has
            since customised survives a resume.

            THE MISSING NBP IS A REFUSAL, NOT A WARNING. A source tree holding
            everything except wdsmgfw.efi stages four files and reports success
            by every other measure, and leaves a server that answers a client and
            then cannot serve it. That is the exact failure this command exists
            for, so it ends in a terminating error naming both halves of the
            contradiction.

            EVERY PATH GOES THROUGH IFileSystem AND THE SOURCE ROOT THROUGH
            IEnvironmentProvider, so the whole of this runs under Pester on a
            machine with no WDS role - which is every machine in this repository.

        .PARAMETER RemoteInstallPath
            The WDS RemoteInstall tree, as wdsutil /initialize-server took it in
            /reminst:. Boot\<arch>\ underneath it is what a PXE client is served
            from.

        .PARAMETER Architecture
            x64 (default), x86 or arm64, in WDS's vocabulary.

            x64 and x86 stage into BOTH Boot\<arch>uefi and Boot\<arch>: the
            first is what a UEFI client is served from, the second is where a
            client that resolves the NBP by name against the architecture-neutral
            path then finds it too. arm64 stages into Boot\arm64 alone, because
            WDS lists x86, x64, arm64, arm, x86uefi and x64uefi and there is no
            arm64uefi - arm64 is UEFI only, so Boot\arm64 IS its UEFI tree.
            Inventing a directory WDS never reads would stage files nothing
            serves.

        .PARAMETER SourcePath
            The WDS source tree to copy from. Defaults to
            <SystemRoot>\System32\RemInst\boot\<arch>, read through the injected
            environment.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Environment
            An IEnvironmentProvider, for SystemRoot. Defaults to the real
            adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with RemoteInstallPath,
            Architecture, SourcePath, Directory, Staged, AlreadyPresent, Skipped,
            NetworkBootProgram and Complete.

        .EXAMPLE
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall'

            Stages the x64 boot files and proves wdsmgfw.efi landed in
            Boot\x64uefi. Run it on the WDS server, after
            wdsutil /initialize-server.

        .EXAMPLE
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -WhatIf

            What it would stage, copying nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $RemoteInstallPath,

        [Parameter()]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string] $Architecture = 'x64',

        [Parameter()]
        [AllowEmptyString()]
        [string] $SourcePath = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Environment) { $Environment = New-HDTEnvironmentProvider }

    # THE DECLARED SET, IN ONE PLACE. wdsmgfw.efi is the one whose absence
    # produces the five-second failure in the help; the other three are staged
    # because a client may ask for any of them by name and a server that has
    # three of four fails for a reason nothing reports.
    $bootFile = @('wdsmgfw.efi', 'bootmgfw.efi', 'bootmgr.exe', 'abortpxe.com')

    # THE UEFI DIRECTORY FIRST IN EVERY LIST, because it is the one a UEFI client
    # is actually served from and therefore the one NetworkBootProgram names.
    $directory = @(('{0}uefi' -f $Architecture), $Architecture)
    if ($Architecture -eq 'arm64') { $directory = @('arm64') }

    # =====================================================================
    # 1. WHERE THE FILES COME FROM
    # =====================================================================

    $source = $SourcePath
    if ([string]::IsNullOrWhiteSpace($source)) {
        $systemRoot = [string] $Environment.GetVariable('SystemRoot')

        # [System.IO.Path]::Combine, not Join-Path: Join-Path resolves the drive
        # qualifier through the PowerShell provider and throws for a path this
        # session cannot see, which is every path in a test (CLAUDE.md rule 8).
        $source = [System.IO.Path]::Combine($systemRoot, 'System32', 'RemInst', 'boot', $Architecture)
    }

    if (-not $FileSystem.TestPath($source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $source -Category ObjectNotFound `
                    -Message ("the WDS boot file source is not there, so the UEFI network boot program cannot be staged and no Generation 2 or UEFI machine will PXE boot from this server, however healthy the server reports itself to be. That directory is laid down by the WDS role itself: install it with Install-WindowsFeature WDS -IncludeManagementTools, and run this on the WDS server rather than from a workstation.")))
    }

    # =====================================================================
    # 2. STAGE - ADDITIVELY
    # =====================================================================

    $staged = New-Object -TypeName System.Collections.ArrayList
    $present = New-Object -TypeName System.Collections.ArrayList
    $skipped = New-Object -TypeName System.Collections.ArrayList

    $nbp = [System.IO.Path]::Combine($RemoteInstallPath, 'Boot', $directory[0], 'wdsmgfw.efi')

    $description = 'Stage {0} WDS boot file(s) into {1}' -f $bootFile.Count, ((@($directory) | ForEach-Object { 'Boot\' + $_ }) -join ', ')

    if (-not $PSCmdlet.ShouldProcess($RemoteInstallPath, $description)) {
        return [pscustomobject] @{
            RemoteInstallPath  = $RemoteInstallPath
            Architecture       = $Architecture
            SourcePath         = $source
            Directory          = [string[]] @($directory)
            Staged             = [string[]] @()
            AlreadyPresent     = [string[]] @()
            Skipped            = [string[]] @()
            NetworkBootProgram = $nbp
            Complete           = $false
        }
    }

    foreach ($dir in $directory) {

        $target = [System.IO.Path]::Combine($RemoteInstallPath, 'Boot', $dir)
        $FileSystem.CreateDirectory($target)

        foreach ($name in $bootFile) {

            $from = [System.IO.Path]::Combine($source, $name)
            $to = [System.IO.Path]::Combine($target, $name)

            if (-not $FileSystem.TestPath($from)) {
                # NAMED, NOT SWALLOWED. A file the role did not install is a fact
                # about this server, and an administrator reading the log later
                # needs it to explain a client that asked for that name.
                Write-Information ("'{0}' is not in the WDS source tree at '{1}'; skipped. A client that asks for it by name will not be served, which is worth knowing before it does." -f $name, $source)
                [void] $skipped.Add($to)
                continue
            }

            if ($FileSystem.TestPath($to)) {
                Write-Information ("'{0}' is already in '{1}'; left exactly as it stands, because a resume must not overwrite a server somebody has customised." -f $name, $target)
                [void] $present.Add($to)
                continue
            }

            $FileSystem.CopyItem($from, $to)
            Write-Information ("staged '{0}' -> '{1}'." -f $from, $to)
            [void] $staged.Add($to)
        }

        # THE IMAGE FOLDER, because WDS looks for one under each architecture and
        # an absent directory is another silent nothing.
        $FileSystem.CreateDirectory([System.IO.Path]::Combine($target, 'Images'))
    }

    # =====================================================================
    # 3. PROVED, NOT ASSUMED
    # =====================================================================
    #
    # The single file whose absence produces the failure in the help, asserted
    # rather than left to the copy loop's own reporting.

    if (-not $FileSystem.TestPath($nbp)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $nbp -Category ObjectNotFound `
                    -Message ("the UEFI network boot program wdsmgfw.efi is still not present after staging, so a UEFI client cannot PXE boot from this server. Watch for the contradiction rather than trusting the server: it will ANSWER the client's broadcast and log event 4096, 'The following client booted from PXE', and wdsutil /get-server /show:config will go on reporting 'Boot files installed: {0} - Yes' - while the client prints 'Start PXE over IPv4.' and the firmware reports 'A boot image was not found' about five seconds later. Check that '{1}' contains wdsmgfw.efi; it is laid down by the WDS role and is not downloaded from anywhere." -f
                        $directory[0], $source)))
    }

    Write-Information ("The UEFI network boot program is staged and verified: '{0}'." -f $nbp)

    return [pscustomobject] @{
        RemoteInstallPath  = $RemoteInstallPath
        Architecture       = $Architecture
        SourcePath         = $source
        Directory          = [string[]] @($directory)
        Staged             = [string[]] @($staged)
        AlreadyPresent     = [string[]] @($present)
        Skipped            = [string[]] @($skipped)
        NetworkBootProgram = $nbp

        # Complete is "the network boot program is there". A skipped
        # abortpxe.com cannot make it false - it is BIOS-era and absent on an
        # arm64 tree - and nothing here says a machine will boot.
        Complete           = $true
    }
}

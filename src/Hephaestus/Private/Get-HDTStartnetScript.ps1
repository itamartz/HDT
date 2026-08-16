function Get-HDTStartnetScript {
    <#
        .SYNOPSIS
            The exact text Update-HDTBootImage writes to
            <mount>\Windows\System32\startnet.cmd.

        .DESCRIPTION
            THE ONLY THING BETWEEN "A MACHINE BOOTED OUR IMAGE" AND "A MACHINE
            RAN OUR ENGINE". WinPE runs startnet.cmd when it finishes booting;
            everything HDT does on that machine follows from these five lines.

            It is a pure function, separate from the fifteen-minute build, so the
            bytes can be asserted in milliseconds - and
            tests/integration/BootImage.Integration.Tests.ps1 reads the same text
            back out of a MOUNTED IMAGE and compares it line by line. One
            function, two witnesses.

            The five lines, and why each is there:

              @echo off
                  WinPE echoes commands otherwise, and the first screen a
                  technician sees should be HDT's, not cmd's.

              rem Written by Update-HDTBootImage...
                  Somebody will open this file inside a mounted image at three
                  in the morning. It should say where it came from and that
                  editing it there is pointless - the next build overwrites it.

              set HDT_LAUNCHED_BY=startnet
                  The field Start-HDTDeployment.ps1 records into RESULT.json.
                  05-05 asserts it to prove NOBODY TYPED THE COMMAND: phase 04's
                  E2E had to type a line at the WinPE prompt because no
                  startnet.cmd existed, and a run that still needed that would
                  look identical in every other respect.

              wpeinit
                  BEFORE PowerShell, always. wpeinit is what brings networking
                  up; a share connect before it fails on a machine that was
                  going to work.

              powershell.exe -NoProfile -ExecutionPolicy Bypass -File
                  X:\HDT\Start-HDTDeployment.ps1

            X: IS WRITTEN LITERALLY, AND IT IS THE ONLY DRIVE LETTER ALLOWED
            HERE. The RAM disk is the one letter WinPE guarantees - a lab test
            recorded WinPE giving the content disk C: while the RAM disk was X:.
            Any other letter here would be a guess about a machine that has not
            booted yet. Where the CONTENT is, is bootstrap.json's business and
            Resolve-HDTDeployRoot's; this file only has to reach the engine.

            THERE IS NO DRIVE SCAN AND NO for LOOP. The phase-04 harness types
            'for %d in (C D E F G H) ...' at the prompt because a human was
            typing it with no bootstrap document to read. Inheriting that line
            here would carry a workaround into the thing that made it
            unnecessary.

            CRLF, and ASCII with no BOM when it is written. cmd.exe reading a
            byte order mark as a command is a class of failure that produces no
            useful message at all, so Update-HDTBootImage writes this through
            IFileSystem.WriteAllText, which is BOM-free on both engines
            (tests/helpers/README.md F11).

            THE START COMMANDS GO BETWEEN wpeinit AND THE ENTRY COMMAND, and
            both halves of that are load-bearing. AFTER wpeinit, because a tool
            started before it has no network - which is the whole reason a VNC
            server or a BGInfo background is in the image at all. BEFORE the
            entry command, because the entry command is the deployment and it
            does not return; anything queued after it never runs.

            Each one is written verbatim on its own line, in the order it was
            given. cmd.exe runs them synchronously, so a tool that has to stay up
            is launched with `start` by the administrator who declared it -
            deciding that here would be deciding it for every image.

        .PARAMETER Command
            The last line, for a caller that wants a different entry point -
            standalone media, a diagnostic image. The default is the engine.
            wpeinit and the environment variable are kept whatever this says: a
            different entry point is still a WinPE boot.

        .PARAMETER StartCommand
            Commands to run after wpeinit and before the entry command, in
            order. Empty produces the same five lines as before.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - five CRLF-terminated lines, plus one per start
            command.

        .EXAMPLE
            Get-HDTStartnetScript

        .EXAMPLE
            Get-HDTStartnetScript -Command 'powershell.exe -NoProfile -File X:\HDT\Start-HDTDiagnostic.ps1'

        .EXAMPLE
            Get-HDTStartnetScript -StartCommand @('X:\HDT\Tools\BGInfo\bginfo.exe X:\HDT\Tools\BGInfo\hdt.bgi /timer:0 /nolicprompt')

            A boot image that shows the machine's own details on the desktop
            before the deployment starts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $StartCommand = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $line = New-Object -TypeName System.Collections.ArrayList

    [void] $line.Add('@echo off')
    [void] $line.Add('rem Written by Update-HDTBootImage. Do not edit inside the image; edit HDT.')
    [void] $line.Add('set HDT_LAUNCHED_BY=startnet')
    [void] $line.Add('wpeinit')

    # After wpeinit and before the entry command. A blank entry is skipped rather
    # than written: a blank line in a .cmd is harmless, and this text is compared
    # byte for byte against a mounted image.
    foreach ($current in @($StartCommand)) {
        if ([string]::IsNullOrWhiteSpace([string] $current)) { continue }

        [void] $line.Add([string] $current)
    }

    [void] $line.Add($Command)

    # Joined with CRLF and terminated with one, so every line ends the way
    # cmd.exe expects. -join alone would leave the last line unterminated.
    return ((@($line) -join "`r`n") + "`r`n")
}

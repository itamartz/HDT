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

            THE TIME ZONE IS NOT SET HERE, AND MUST NOT BE PUT BACK. This
            file carried `tzutil /s "<id>"` for a release. tzutil.exe IS NOT IN
            WinPE - captured proof in
            tests/fixtures/winpe/winpe-command-amd64.json, and confirmed at a
            real WinPE prompt - so cmd.exe printed "is not recognized", startnet
            ran straight on to the next line, and every deployment stayed on the
            image's baked-in Pacific Standard Time with nothing failing anywhere.
            It read as an engine whose UtcNow was eleven hours out while `time`
            at the prompt was correct: the hardware clock was right and the ZONE
            had never moved. w32tm is absent too, so it is not the fix either.

            The zone is now written INTO THE IMAGE at build time -
            IBootImageService.SetTimeZone, which is
            dism /Image:<mount> /Set-TimeZone: - so there is no runtime command
            left that can go missing. tests/contract/StartnetCommand.Contract.Tests.ps1
            asserts that every command this function emits is one WinPE has, and
            it is the reason a fourth guess would fail at the gate instead of at
            a bench.

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

            A BATCH FILE IS EMITTED WITH `call`, AND WITHOUT IT THE DEPLOYMENT
            NEVER STARTS. cmd.exe does not return from one batch file to
            another: a bare `X:\Tools\run.cmd` on a line here TRANSFERS control,
            and the entry command below it is never reached. The machine sits
            wherever run.cmd left it - booted, initialised, tools running - and
            looks exactly like a deployment that hung.

            It is done here rather than where the command is authored so that a
            hand-edited workspace.yaml gets it too. What the administrator typed
            is what the document keeps; `call` is a fact about cmd.exe and
            belongs with the code that writes cmd.

            ALREADY-CALLED AND ALREADY-STARTED LINES ARE LEFT ALONE. `start`
            returns immediately by design - it is what an administrator writes
            for a tool that has to stay up - and doubling `call` would be
            rewriting an instruction that was already right.

        .PARAMETER UnattendPath
            A WinPE answer file inside the image, passed to wpeinit as
            -unattend:. Empty means the plain wpeinit line.

            IT IS AN ARGUMENT ON THE LINE THAT ALREADY EXISTS, not a line of its
            own, because wpeinit is what processes it: Display, EnableFirewall,
            EnableNetwork, LogPath, PageFile, Restart, RunSynchronous and
            RunAsynchronous are the settings it accepts. The firewall in
            particular has no other supported switch - `wpeutil disablefirewall`
            is a manual command at a prompt, not something an image is built
            with.

        .PARAMETER CertificateScript
            A PowerShell script inside the image that imports the boot image's
            certificates, run BEFORE wpeinit. Empty writes no line at all.

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
        [string[]] $StartCommand = @(),

        [Parameter()]
        [AllowEmptyString()]
        [string] $UnattendPath = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $CertificateScript = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $line = New-Object -TypeName System.Collections.ArrayList

    [void] $line.Add('@echo off')
    [void] $line.Add('rem Written by Update-HDTBootImage. Do not edit inside the image; edit HDT.')
    [void] $line.Add('set HDT_LAUNCHED_BY=startnet')

    # BEFORE wpeinit, AND THAT IS THE WHOLE POINT OF THE LINE. wpeinit is what
    # brings the network up; a machine certificate imported after it has missed
    # the authentication it was carried for, and a root CA imported after it has
    # missed whatever wpeinit's own answer file reached for. Everything else in
    # this file goes after wpeinit for the opposite reason.
    #
    # PowerShell RUNS FINE HERE. It is an application, not a service - what
    # wpeinit initialises is devices and networking, neither of which an
    # X509Store needs.
    if (-not [string]::IsNullOrWhiteSpace($CertificateScript)) {
        [void] $line.Add('powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}' -f $CertificateScript)
    }

    # QUOTED ONLY WHEN IT HAS TO BE. cmd.exe splits on the space, so a path with
    # one in it reaches wpeinit as two arguments and the answer file is silently
    # not processed - which looks exactly like an answer file that did nothing.
    # Quoting unconditionally would be safe too, but the unquoted form is what
    # every Microsoft example shows and what an administrator compares against.
    $wpeinit = 'wpeinit'
    if (-not [string]::IsNullOrWhiteSpace($UnattendPath)) {
        $unattendText = [string] $UnattendPath
        if ($unattendText.Contains(' ')) { $unattendText = '"{0}"' -f $unattendText }

        $wpeinit = 'wpeinit -unattend:{0}' -f $unattendText
    }

    [void] $line.Add($wpeinit)

    # After wpeinit and before the entry command. A blank entry is skipped rather
    # than written: a blank line in a .cmd is harmless, and this text is compared
    # byte for byte against a mounted image.
    foreach ($current in @($StartCommand)) {
        if ([string]::IsNullOrWhiteSpace([string] $current)) { continue }

        # THE `call` RULE LIVES IN ONE PLACE. The WinPE window shows the same
        # answer, so a second copy here would be a second copy to get wrong.
        $effective = ConvertTo-HDTStartnetCommandLine -Command ([string] $current)

        # ANNOUNCED BEFORE IT IS RUN, AND A REAL BOOT IS WHY. An image carrying
        # a firewall command, a VNC server and a BGInfo showed a console with
        # ONE line on it - "The command completed successfully" - which came
        # from the firewall command. The VNC server two lines later never
        # returned and held the whole deployment, and the screen was still
        # naming the last thing that PRINTED rather than the thing that was
        # stuck. With this, the last line on screen is the command that is
        # actually running.
        #
        # IT ANNOUNCES THE LINE THAT WILL RUN, call AND ALL, so the console can
        # be read top to bottom against the file.
        #
        # ESCAPED, BECAUSE AN ECHO IS STILL A COMMAND. `echo run.exe > log.txt`
        # writes a file instead of printing, and %PATH% in an echo prints the
        # variable rather than the text - so a line meant to inform would act.
        # The caret goes first: escaping it after the others would escape the
        # carets this very line just added.
        $announce = $effective -replace '\^', '^^'
        $announce = $announce -replace '&', '^&'
        $announce = $announce -replace '<', '^<'
        $announce = $announce -replace '>', '^>'
        $announce = $announce -replace '\|', '^|'
        $announce = $announce -replace '%', '%%'

        [void] $line.Add(('echo about to run the command: {0}' -f $announce))
        [void] $line.Add($effective)
    }

    [void] $line.Add($Command)

    # Joined with CRLF and terminated with one, so every line ends the way
    # cmd.exe expects. -join alone would leave the last line unterminated.
    return ((@($line) -join "`r`n") + "`r`n")
}

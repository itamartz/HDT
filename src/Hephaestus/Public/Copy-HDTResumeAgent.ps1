function Copy-HDTResumeAgent {
    <#
        .SYNOPSIS
            Stages the engine and the resume payload onto the volume the machine
            is about to boot from.

        .DESCRIPTION
            THE HALF OF DESIGN 4.5.1 THAT WAS MISSING. The engine is "launched at
            logon by a RunOnce entry pointing at C:\HDT\Start-HDTResume.ps1" -
            and until this command existed, nothing ever put that file, or the
            module it imports, on the disk. Both were staged into the BOOT IMAGE
            at X:\HDT\, which is a RAM disk that ceases to exist at the restart.

            THE FAILURE THIS ENDS DID NOT LOOK LIKE A FAILURE. WinPE deployed
            Windows, the machine restarted, Windows autologged on - and then sat
            at a desktop with nothing to run. Every step in a FullOS group was
            dead, which on the shipped client template is the whole State Restore
            group, which is where applications install. A deployment that
            installs no software and reports success is worse than one that
            stops, because nobody goes looking.

            IT COPIES THE IMAGE'S OWN TREE, not a fresh one from the build host.
            The engine that resumes has to be the engine that started - a machine
            halfway through a task sequence is the worst possible place to change
            versions - and X:\HDT\Modules is by construction the copy the boot
            image was built with. This is also why it takes no -ModulePath: there
            is nothing to choose.

            WHAT TRAVELS, AND WHAT DOES NOT:

              Start-HDTResume.ps1     what RunOnce launches
              Modules\                the engine, and powershell-yaml, without
                                      which it can read no document at all
              bootstrap.json          the deploy root and the account that opens
                                      it, so the full-OS leg can reach the share
                                      that holds Applications\

              Start-HDTDeployment.ps1 NOT staged - it is what startnet.cmd runs,
                                      and a copy on the deployed machine would be
                                      a second answer to "what starts a
                                      deployment", and the one nothing launches
              UI\HDTFailure.xaml    the Deployment Summary
              UI\HDTProgress.xaml   the status board this leg runs behind
                                      The wizard, the progress window and the theme
                                      belong to WinPE, before this disk had a
                                      partition table; the summary is drawn AFTER
                                      the reboot, so it has to be here

            AN EMPTY STAGE IS REFUSED, LOUDLY, and that is the whole point of the
            check: failing here means failing in WinPE, where the log is still
            being written and a technician is still watching. Succeeding into a
            desktop nobody is looking at is how this went unnoticed for five
            milestones.

            NOTHING HERE IS DELETED. The teardown (DESIGN 4.5.4) removes what
            this wrote, on the machine, at the end of the run.

        .PARAMETER TargetVolume
            The volume the operating system was applied to - the DRIVE LETTER
            HDTOSVolume carries. 'W', 'W:' and 'W:\' all mean the same volume
            and all stage to W:\HDT; anything that is not one letter is refused
            rather than turned into a relative path. On the booted machine the
            same folder is C:\HDT.

        .PARAMETER Source
            The boot image's own payload folder. X: is the only letter a WinPE
            payload may assume (SPIKES S9.1), and this is the one place it is
            assumed.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FileCount and
            Item.

        .EXAMPLE
            Copy-HDTResumeAgent -TargetVolume 'W:'

            Stages W:\HDT\ from X:\HDT\, which becomes C:\HDT\ when the machine boots.
            X:\ is WinPE's RAM disk; nothing on it survives the restart, engine
            included.

        .EXAMPLE
            $answer = Copy-HDTResumeAgent -TargetVolume 'W:'
            @($answer.Copied).Count

            How many files went across. The sequence resumes by running what this put
            there, so a short copy is a deployment that stops at the reboot.

        .LINK
            Set-HDTAutoLogon

        .LINK
            Invoke-HDTTaskSequence
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetVolume,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Source = 'X:\HDT',

        # THE SHARE THE MACHINE ACTUALLY REACHED. bootstrap.json is baked into
        # the boot image, so it carries whatever deploy root was true when the
        # image was made - and a technician who corrects the share at the
        # Welcome screen fixes the WinPE leg only. The full-OS leg then asked
        # for the dead address again, could not map MDT's drive letter, and
        # every step needing content failed.
        #
        # EMPTY MEANS COPY IT AS IT IS, which is what a deployment that never
        # corrected anything wants.
        [Parameter()]
        [AllowEmptyString()]
        [string] $DeployRoot = '',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source -Category ObjectNotFound `
                    -Message ("'{0}' is not there, so there is no engine to stage onto the deployed machine. This folder is what Update-HDTBootImage writes into the boot image; a machine running a payload from somewhere else must name it with -Source." -f $Source)))
    }

    $payload = [System.IO.Path]::Combine($Source, 'Start-HDTResume.ps1')

    if (-not $FileSystem.TestPath($payload)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $payload -Category ObjectNotFound `
                    -Message ("'{0}' is not in this boot image, so the deployed machine would autologon with nothing to run and every step after the restart would be silently skipped. Rebuild the boot image with a version of Update-HDTBootImage that stages the resume payload." -f $payload)))
    }

    # A VOLUME IS A LETTER, AND HDTOSVolume CARRIES JUST THE LETTER - 'W', not
    # 'W:' and not 'W:\'. That is the convention every volume variable in this
    # engine follows, and Invoke-HDTApplyImageStep normalises exactly this way
    # before it builds a path from one.
    #
    # THE FIRST VERSION OF THIS TRIMMED SEPARATORS AND NOTHING ELSE, so the real
    # value composed 'W\HDT' - a RELATIVE path. On a live deployment 408 files
    # went onto the RAM disk, died with it, and the machine booted, autologged on
    # and had nothing to run. The unit tests were green throughout, because they
    # were written against 'W:' and 'W:\': two spellings the engine never
    # produces.
    $letter = ([string] $TargetVolume).Trim().TrimEnd('\', '/').TrimEnd(':')

    # ANYTHING THAT IS NOT ONE LETTER IS REFUSED RATHER THAN MADE RELATIVE. A
    # relative destination is the failure this command exists to prevent,
    # reached from the other end - files written somewhere nobody will look, and
    # a machine that boots into nothing.
    if ($letter -notmatch '^[A-Za-z]$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $TargetVolume -Category InvalidArgument `
                    -Message ("'{0}' is not a drive letter, so there is nowhere to stage the engine. HDTOSVolume carries the letter the partition step published; a value that is not one letter would compose a relative path and put the deployed machine's engine somewhere nothing will look for it." -f $TargetVolume)))
    }

    $destination = '{0}:\HDT' -f $letter.ToUpperInvariant()

    if (-not $PSCmdlet.ShouldProcess($destination, ("Stage the engine and the resume payload from '{0}'" -f $Source))) {
        return [pscustomobject] @{
            Path      = [string] $destination
            FileCount = 0
            Item      = [pscustomobject[]] @()
        }
    }

    $FileSystem.CreateDirectory($destination)

    $item = New-Object -TypeName System.Collections.ArrayList
    $count = 0

    # The module tree first, so a machine that dies mid-stage has no payload
    # standing over a missing engine - the one ordering that turns a failed
    # stage into a RunOnce entry that throws on Import-Module.
    $modules = [System.IO.Path]::Combine($Source, 'Modules')

    if ($FileSystem.TestPath($modules)) {
        $moduleCount = Copy-HDTContentTree -Source $modules `
            -Destination ([System.IO.Path]::Combine($destination, 'Modules')) -FileSystem $FileSystem

        $count += $moduleCount

        [void] $item.Add([pscustomobject] @{
                Name      = 'Modules'
                Source    = [string] $modules
                FileCount = [int] $moduleCount
            })
    }

    # bootstrap.json is optional: an image built for the Local provider has no
    # share to reach, and a full-OS leg of steps that need no content is a
    # legitimate deployment.
    # Remove-HDTAgentTree.ps1 IS STAGED INSIDE THE FOLDER IT DELETES, and that
    # is deliberate rather than careless: it is copied out to %TEMP% and started
    # detached at the moment the cleanup runs, so it has to have travelled onto
    # the machine first. PSD stages PSDFinal.ps1 into MININT the same way.
    foreach ($leaf in @('Start-HDTResume.ps1', 'Remove-HDTAgentTree.ps1', 'bootstrap.json')) {
        $from = [System.IO.Path]::Combine($Source, $leaf)

        if (-not $FileSystem.TestPath($from)) { continue }

        $target = [System.IO.Path]::Combine($destination, $leaf)

        # ONE VALUE REPLACED, THE REST OF THE DOCUMENT AS IT WAS. The account,
        # the provider and the content marker are the image's; only the address
        # is something this run learned.
        #
        # SPLICED ON THE KEY, NOT RE-SERIALISED. Rewriting the JSON would drop
        # any key this engine does not know about - an image built by a newer
        # HDT and staged by an older one - and would reformat a file somebody
        # may have to read at a WinPE prompt.
        if ($leaf -eq 'bootstrap.json' -and -not [string]::IsNullOrWhiteSpace($DeployRoot)) {
            $text = [string] $FileSystem.ReadAllText($from)

            $escaped = $DeployRoot.Replace('\', '\\')
            $rewritten = [regex]::Replace($text,
                '("deployRoot"\s*:\s*)"(?:[^"\\]|\\.)*"',
                ('$1"' + $escaped.Replace('$', '$$') + '"'), 1)

            $FileSystem.WriteAllText($target, $rewritten)
            $count++

            [void] $item.Add([pscustomobject] @{
                    Name      = [string] $leaf
                    Source    = [string] $from
                    FileCount = 1
                })

            continue
        }

        $FileSystem.CopyItem($from, $target)
        $count++

        [void] $item.Add([pscustomobject] @{
                Name      = [string] $leaf
                Source    = [string] $from
                FileCount = 1
            })
    }

    # -- the screens the full-OS leg draws ----------------------------------
    #
    # TWO FILES OUT OF UI\, AND ONLY THE TWO THAT ARE SHOWN AFTER THE REBOOT.
    # Update-HDTBootImage keeps UI\ out of the module tree deliberately and
    # stages the whole folder to X:\HDT\UI\ for the wizard, which runs in WinPE
    # and never runs again. These two are drawn once Windows is up, so they have
    # to travel with the engine onto the disk.
    #
    # NEITHER WAS STAGED, AND EACH FAILED QUIETLY IN ITS OWN WAY. The summary's
    # default path pointed into the staged module's own UI\ folder, which does
    # not exist, so a deployment that SUCCEEDED end to end finished in silence.
    # The board was worse: the full-OS leg opened no window at all, so a machine
    # installed its applications with nothing on screen and the first anybody
    # knew of them was appwiz.cpl afterwards.
    #
    # OPTIONAL, LIKE bootstrap.json. An older boot image has neither file, and a
    # machine that cannot draw a screen must still finish its sequence -
    # Start-HDTProgressDisplay degrades to console lines and says why.
    foreach ($screen in @('HDTFailure.xaml', 'HDTProgress.xaml')) {

        $screenSource = [System.IO.Path]::Combine($Source, 'UI', $screen)
        if (-not $FileSystem.TestPath($screenSource)) { continue }

        $screenFolder = [System.IO.Path]::Combine($destination, 'UI')
        $FileSystem.CreateDirectory($screenFolder)
        $FileSystem.CopyItem($screenSource, [System.IO.Path]::Combine($screenFolder, $screen))
        $count++

        [void] $item.Add([pscustomobject] @{
                Name      = 'UI\{0}' -f $screen
                Source    = [string] $screenSource
                FileCount = 1
            })
    }

    return [pscustomobject] @{
        Path      = [string] $destination
        FileCount = [int] $count
        Item      = [pscustomobject[]] @($item)
    }
}

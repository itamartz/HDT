# HOW AN ADMINISTRATOR STARTS A REFRESH.
#
# M9 built the whole of a Refresh and left no door into it. The engine derives
# FullOS the moment its system drive is not X: (Get-HDTDeploymentPhase), and
# Start-HDTDeployment.ps1 has been ready to be started on that leg since M9 -
# but nothing in the product starts it there. DESIGN documented the WinPE entry
# point and only the WinPE entry point: startnet.cmd running
# X:\HDT\Start-HDTDeployment.ps1. There was no full-OS equivalent of MDT's
# \\share\Scripts\LiteTouch.vbs, no launcher on any share, and no section
# describing one. 09-VERIFICATION.md raised it as the gap that blocks
# tests/e2e/Refresh.E2E.Tests.ps1 from being written at all.
#
# MDT'S SHAPE, FOLLOWED. LiteTouch.vbs is a THIN launcher that lives on the
# share and does four things: it works out where it was launched FROM
# (oFSO.GetParentFolderName(WScript.ScriptFullName)), checks the machine can do
# this at all (ZTIPrereq.vbs), then hands every argument to LiteTouch.wsf, which
# is the heavy lifting. HDT's heavy lifting already exists and is already
# full-OS-aware, so the launcher has exactly LiteTouch.vbs's job and no more.
#
# AND THE DECISION LIVES HERE RATHER THAN IN THE SCRIPT. A .ps1 sitting on a
# share cannot be unit tested - it runs on a machine, against a real filesystem,
# once. So every branch it would have taken is this function's, against a fake:
# where the share is, whether this leg may launch one, which provider reaches
# the content, what bootstrap document the engine is handed. The launcher reads
# the environment and calls this. Same split as Get-HDTDeploymentPhase, and for
# the same reason (CLAUDE.md rule 5).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # A SHARE ON A DRIVE THIS SESSION HAS NOT MOUNTED, DELIBERATELY. Q: does not
    # exist here, so any line that reached Join-Path instead of
    # [IO.Path]::Combine would throw DriveNotFound and the function would not be
    # testable at all - the trap CLAUDE.md rule 8 names and Get-HDTWorkspacePath
    # already carries.
    $script:newShare = {
        param([string] $Root = 'Q:\Share', [hashtable] $Extra = @{}, [string[]] $Without = @())

        $file = @{
            ([System.IO.Path]::Combine($Root, 'rules.yaml'))     = "schemaVersion: 1`nrules: []`n"
            ([System.IO.Path]::Combine($Root, 'workspace.yaml')) = "schemaVersion: 1`nid: HDT-LAB`nname: HDT lab`n"
            ([System.IO.Path]::Combine($Root, 'Modules', 'Hephaestus', 'Hephaestus.psd1')) = '@{ ModuleVersion = ''0.0.0'' }'
            ([System.IO.Path]::Combine($Root, 'Modules', 'Hephaestus', 'Payload', 'Start-HDTDeployment.ps1')) = '# the engine entry point'
        }

        foreach ($key in $Extra.Keys) { $file[$key] = $Extra[$key] }

        # A SHARE MISSING ONE THING, BUILT WITHOUT IT rather than built and then
        # broken. A fake that recorded a RemoveItem would put an operation in the
        # log that the launcher never performed.
        foreach ($gone in @($Without)) { [void] $file.Remove([System.IO.Path]::Combine($Root, $gone)) }

        New-HDTFakeFileSystem -File $file
    }

    $script:planFor = {
        param([object] $FileSystem, [string] $Root = 'Q:\Share', [string] $SystemDrive = 'C:', [bool] $IsElevated = $true, [string] $SequenceId = '')

        Get-HDTRefreshLaunchPlan -ScriptRoot ([System.IO.Path]::Combine($Root, 'Scripts')) `
            -SystemDrive $SystemDrive -IsElevated $IsElevated -SequenceId $SequenceId -FileSystem $FileSystem
    }
}

Describe 'Get-HDTRefreshLaunchPlan' {

    Context 'where the engine is read from' {

        # DESIGN 3 CALLS Modules\ "engine payload STAGED TO CLIENTS", and until
        # 2026-09-10 the plan read it in place on the share instead. That works
        # for every .ps1 in it and fails for the one .dll: powershell-yaml loads
        # YamlDotNet through [Reflection.Assembly]::LoadFile(), and .NET
        # Framework refuses an assembly on a UNC path unless loadFromRemoteSources
        # is switched on in a .config on the machine being deployed.
        #
        # PROVEN ON HDT-M9-Refresh. The launcher now stages Modules\ to
        # <system drive>\HDT\Modules before it imports anything - it has to, or
        # it cannot read a YAML document to build this plan - and the plan has
        # to agree with it, or the payload it hands over to imports from the
        # share and dies on the same line one layer down. That is exactly what
        # happened: "phase FullOS, deployment type REFRESH" printed, and then
        # the payload threw on powershell-yaml.psm1:39.

        It 'reads the engine off the share when nothing was staged' {
            # EVERY EXISTING CALLER, UNCHANGED. WinPE stages its own copy into
            # the boot image and passes none.
            $plan = & $script:planFor (& $script:newShare)

            $plan.ModuleRoot | Should -Be 'Q:\Share\Modules'
        }

        It 'reads the engine from the staged copy when the launcher names one' {
            $fileSystem = & $script:newShare -Extra @{
                ([System.IO.Path]::Combine('C:\HDT\Modules', 'Hephaestus', 'Payload', 'Start-HDTDeployment.ps1')) = '# the staged engine'
            }

            $plan = Get-HDTRefreshLaunchPlan -ScriptRoot ([System.IO.Path]::Combine('Q:\Share', 'Scripts')) `
                -SystemDrive 'C:' -IsElevated $true -ModuleRoot 'C:\HDT\Modules' -FileSystem $fileSystem

            $plan.ModuleRoot | Should -Be 'C:\HDT\Modules'
            $plan.PayloadPath | Should -Be 'C:\HDT\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1'
            $plan.UiRoot | Should -Be 'C:\HDT\Modules\Hephaestus\UI'
        }

        It 'refuses by the staged path when the staging did not happen' {
            # THE MESSAGE HAS TO NAME THE PATH THAT IS ACTUALLY EMPTY. A refusal
            # naming the share would send an administrator to look at a folder
            # that is present and correct.
            $fileSystem = & $script:newShare

            { Get-HDTRefreshLaunchPlan -ScriptRoot ([System.IO.Path]::Combine('Q:\Share', 'Scripts')) `
                    -SystemDrive 'C:' -IsElevated $true -ModuleRoot 'C:\HDT\Modules' -FileSystem $fileSystem } |
                Should -Throw -ExpectedMessage '*C:\HDT\Modules*'
        }
    }

    Context 'where the share is' {

        It 'is the folder the launcher was launched from, one level up' {
            # MDT'S RULE AND THE ONLY ONE THAT WORKS. LiteTouch.vbs derives the
            # share from WScript.ScriptFullName's parent because the admin
            # reached it by opening \\server\Share\Scripts\ - so the path they
            # used is the path that works from this machine, which a deployRoot
            # written into a document months ago may not be.
            $plan = & $script:planFor (& $script:newShare)

            $plan.Root | Should -Be 'Q:\Share'
        }

        It 'refuses a launcher that is not sitting in a share, and says where it must sit' {
            # A .ps1 COPIED TO THE DESKTOP. It is the obvious thing to do with a
            # script and it cannot work: the launcher's location IS the share,
            # so a copy somewhere else has no idea what it is deploying. The
            # refusal names the layout rather than the missing file.
            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\Elsewhere\Scripts\Start-HDTRefresh.ps1' = '# a copy' }

            { & $script:planFor $fileSystem 'Q:\Elsewhere' } |
                Should -Throw -ExpectedMessage '*rules.yaml*'
        }

        It 'refuses a share with no workspace.yaml' {
            $fileSystem = & $script:newShare 'Q:\Share' @{} @('workspace.yaml')

            { & $script:planFor $fileSystem } | Should -Throw -ExpectedMessage '*workspace.yaml*'
        }
    }

    Context 'which leg this is' {

        It 'derives FullOS, and does not take it as a parameter' {
            # THE WHOLE POINT OF THE LAUNCHER. A Refresh is REFRESH because the
            # run STARTED in the full OS (DESIGN 3.2), and that is derived from
            # the system drive by Get-HDTDeploymentPhase - never declared. A
            # launcher that passed -Phase would be a launcher that could lie.
            $plan = & $script:planFor (& $script:newShare)

            $plan.Phase | Should -Be 'FullOS'
            $plan.DeploymentType | Should -Be 'REFRESH'
        }

        It 'agrees with the two commands that own the answer' {
            # NOT A SECOND COPY OF THE MAPPING. Get-HDTDeploymentType's own
            # comment says two things need it and they must not disagree; a
            # third would be a third.
            $plan = & $script:planFor (& $script:newShare) 'Q:\Share' 'D:'

            $plan.Phase | Should -Be (Get-HDTDeploymentPhase -SystemDrive 'D:')
            $plan.DeploymentType | Should -Be 'REFRESH'
        }

        It 'refuses to run in WinPE, and names the entry point that already does' {
            # startnet.cmd ALREADY RUNS THE ENGINE THERE. A machine that booted
            # the image and then ran this off the share would mint a second run
            # beside the one already going. The refusal is not a safety net; it
            # is the sentence that tells the technician nothing was needed.
            { & $script:planFor (& $script:newShare) 'Q:\Share' 'X:' } |
                Should -Throw -ExpectedMessage '*startnet.cmd*'
        }
    }

    Context 'whether this session may do it' {

        It 'refuses an unelevated session' {
            # MDT CHECKS THE SAME THING IN THE SAME PLACE - LiteTouch.wsf writes
            # a file into %SystemRoot% to find out. A Refresh suspends BitLocker,
            # writes a boot entry with bcdedit and empties a volume; every one of
            # those fails halfway through as a standard user, which is worse than
            # not starting.
            { & $script:planFor (& $script:newShare) 'Q:\Share' 'C:' $false } |
                Should -Throw -ExpectedMessage '*administrator*'
        }

        It 'refuses before it looks at the share, so an unelevated run is told the real reason' {
            # ORDER MATTERS IN A REFUSAL. A standard user very often cannot READ
            # the share either, so a launcher that checked the share first would
            # tell them rules.yaml was missing - and they would go and look for a
            # file that is there.
            $fileSystem = New-HDTFakeFileSystem -File @{}

            { & $script:planFor $fileSystem 'Q:\Nothing' 'C:' $false } |
                Should -Throw -ExpectedMessage '*administrator*'
        }
    }

    Context 'the engine it hands over to' {

        It 'points at the copy staged on the share' {
            # DESIGN 3's layout calls Modules\ "engine payload staged to
            # clients", and this is the client. The machine being refreshed has
            # nothing installed on it - that is the whole situation - so the
            # engine has to come off the share the launcher is already reading.
            $plan = & $script:planFor (& $script:newShare)

            $plan.ModuleRoot | Should -Be 'Q:\Share\Modules'
            $plan.PayloadPath | Should -Be 'Q:\Share\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1'
        }

        It 'hands over to Start-HDTDeployment and not to a second entry point' {
            # THE FILE startnet.cmd RUNS, AND THE SAME ONE. It already derives
            # the phase, already scans for a run in progress with -Phase, already
            # opens the wizard and already calls Invoke-HDTTaskSequence once. A
            # second full-OS entry point would be a second answer to "which one
            # is running" - the words DESIGN uses about the boot image staging
            # the payload once.
            $plan = & $script:planFor (& $script:newShare)

            [System.IO.Path]::GetFileName($plan.PayloadPath) | Should -Be 'Start-HDTDeployment.ps1'
        }

        It 'refuses a share with no engine staged on it, and names the folder' {
            $fileSystem = & $script:newShare 'Q:\Share' @{} @('Modules\Hephaestus\Payload\Start-HDTDeployment.ps1')

            { & $script:planFor $fileSystem } | Should -Throw -ExpectedMessage '*Modules*'
        }
    }

    Context 'the bootstrap document it writes' {

        BeforeAll {
            $script:fs = & $script:newShare
            $script:plan = & $script:planFor $script:fs
        }

        It 'names the share it was launched from as the deployRoot' {
            $script:plan.Bootstrap['deployRoot'] | Should -Be 'Q:\Share'
        }

        It 'carries the workspace id out of the share''s own workspace.yaml' {
            # NOT INVENTED AND NOT PASSED IN. The id is carried into log and
            # artifact names, so a launcher that made one up would produce a run
            # nobody could find beside the share's other runs.
            $script:plan.Bootstrap['workspaceId'] | Should -Be 'HDT-LAB'
        }

        It 'is Local, because the session that launched it already reaches the share' {
            # THE PROVIDER IS ABOUT AUTHENTICATION, NOT ABOUT UNC. Smb means
            # "connect to this share with these credentials first", which is what
            # a machine that just booted a WIM has to do. An administrator who
            # opened \\server\Share and double-clicked the launcher has already
            # done it; their token is on the connection. Get-HDTBootstrapConfiguration
            # refuses an Smb document with no credential and no prompt for exactly
            # that reason - it is describing a boot image that can neither
            # authenticate nor ask anybody, and this is neither.
            $script:plan.Bootstrap['provider'] | Should -Be 'Local'
        }

        It 'leaves sequenceId empty when nobody named one' {
            # EMPTY IS LEGAL AND IT IS THE ORDINARY CASE: the sequence then comes
            # from the wizard or the rules, which is where "which task sequence
            # does this machine get" is answered everywhere else.
            $script:plan.Bootstrap['sequenceId'] | Should -Be ''
        }

        It 'carries a sequence id through when one was named' {
            $named = & $script:planFor (& $script:newShare) 'Q:\Share' 'C:' $true 'REFRESH'

            $named.Bootstrap['sequenceId'] | Should -Be 'REFRESH'
        }

        It 'is read back by the engine''s own reader without a single complaint' {
            # THE TEST THAT MATTERS, and the one the wizard template test taught:
            # a document this function writes, parsed by the command that reads
            # bootstrap.json on every machine. Anything this gets wrong about the
            # shape fails here rather than on somebody's laptop with the volume
            # already emptied.
            $written = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('hdt-refresh-{0}.json' -f [guid]::NewGuid()))

            try {
                [System.IO.File]::WriteAllText($written, $script:plan.BootstrapText)

                $read = Get-HDTBootstrapConfiguration -Path $written

                $read.Provider | Should -Be 'Local'
                $read.DeployRoot | Should -Be 'Q:\Share'
                $read.WorkspaceId | Should -Be 'HDT-LAB'
                $read.ContentMarker | Should -Be 'rules.yaml'
            } finally {
                # A file this test created, removed by the code that made it.
                if (Test-Path -LiteralPath $written) { Remove-Item -LiteralPath $written -Force }
            }
        }

        It 'lands beside the run''s own state and logs, on the machine being refreshed' {
            # <SystemDrive>\HDT\ IS ALREADY THE RUN'S DIRECTORY in the full OS -
            # Get-HDTLogPath puts the logs there, refresh.yaml stages the WinPE
            # to <volume>\HDT\Boot and CleanVolume keeps the folder standing for
            # exactly that reason. The bootstrap belongs with them, not in a temp
            # folder that says nothing about which run wrote it.
            $script:plan.BootstrapPath | Should -Be 'C:\HDT\bootstrap.json'
        }

        It 'writes it where the machine is, not where C: is' {
            $elsewhere = & $script:planFor (& $script:newShare) 'Q:\Share' 'D:'

            $elsewhere.BootstrapPath | Should -Be 'D:\HDT\bootstrap.json'
        }
    }

    Context 'the windows this leg draws' {

        # THE DEFECT THIS CONTEXT WAS WRITTEN FOR. Start-HDTDeployment.ps1 takes
        # its XAML as parameters defaulted to X:\HDT\UI\ - right in WinPE, where
        # the boot image staged them onto the RAM disk, and meaningless on a
        # machine that never booted one. The launcher passed -BootstrapPath and
        # -ModuleRoot and nothing else, so a full-OS Refresh inherited every one
        # of them and the wizard, the progress board, the failure screen, the
        # welcome screen and the boot status panel all had no file to load.
        #
        # THE SHARE IS WHERE THEY COME FROM, and specifically the UI\ folder of
        # the engine already staged in Modules\ - the same tree -ModuleRoot
        # already points at, and the same tree this launcher has already refused
        # to run without. Nothing new is staged and nothing is copied: the
        # screens are the ones that shipped with the engine that is about to run,
        # so they cannot disagree with it.
        #
        # AND THE SET IS NOT WRITTEN DOWN HERE. Get-HDTPayloadUiPath reads the
        # param block of the payload the plan is about to invoke, so a seventh
        # screen added to it is rebased without anybody editing this function.

        BeforeAll {
            # A STAGED PAYLOAD THAT DECLARES A SCREEN THIS REPOSITORY HAS NEVER
            # HEARD OF, so "the set was discovered" and "the set was copied out
            # again" cannot both pass.
            $script:stagedPayload = @'
[CmdletBinding()]
param(
    [Parameter()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [string] $ModuleRoot = 'X:\HDT\Modules',

    [Parameter()]
    [string] $WizardShellPath = 'X:\HDT\UI\HDTWizardShell.xaml',

    [Parameter()]
    [string] $FailureXamlPath = 'X:\HDT\UI\HDTFailure.xaml',

    [Parameter()]
    [string] $ChecklistXamlPath = 'X:\HDT\UI\HDTChecklist.xaml'
)
'@

            $script:uiShare = {
                & $script:newShare 'Q:\Share' @{
                    ([System.IO.Path]::Combine('Q:\Share', 'Modules', 'Hephaestus', 'Payload', 'Start-HDTDeployment.ps1')) = $script:stagedPayload
                }
            }
        }

        It 'reads them out of the engine already staged on the share' {
            $plan = & $script:planFor (& $script:uiShare)

            $plan.UiRoot | Should -Be 'Q:\Share\Modules\Hephaestus\UI'
        }

        It 'answers every screen the staged payload declares, including one no list here names' {
            $plan = & $script:planFor (& $script:uiShare)

            @($plan.UiArgument.Keys) | Sort-Object |
                Should -Be @('ChecklistXamlPath', 'FailureXamlPath', 'WizardShellPath')
        }

        It 'points each of them at a file on the share' {
            $plan = & $script:planFor (& $script:uiShare)

            $plan.UiArgument['WizardShellPath'] | Should -Be 'Q:\Share\Modules\Hephaestus\UI\HDTWizardShell.xaml'
            $plan.UiArgument['FailureXamlPath'] | Should -Be 'Q:\Share\Modules\Hephaestus\UI\HDTFailure.xaml'
        }

        It 'leaves not one of them on the WinPE RAM disk' {
            # THE ASSERTION THE WHOLE CONTEXT EXISTS FOR, and it is written
            # against the SET rather than against six names: whatever the payload
            # declares, none of it may still be rooted on X: once the plan has
            # answered it.
            $plan = & $script:planFor (& $script:uiShare)

            @($plan.UiArgument.Values | Where-Object { $_ -match '^[Xx]:' }) | Should -BeNullOrEmpty
        }

        It 'does not rebase the two the launcher answers itself' {
            # BootstrapPath IS A DOCUMENT THIS RUN WRITES ONTO THE MACHINE and
            # ModuleRoot IS THE SHARE. Both are already passed explicitly and
            # neither is a screen; sweeping them into UI\ would put the engine in
            # the wrong folder and the bootstrap somewhere nothing reads.
            $plan = & $script:planFor (& $script:uiShare)

            $plan.UiArgument.ContainsKey('BootstrapPath') | Should -BeFalse
            $plan.UiArgument.ContainsKey('ModuleRoot') | Should -BeFalse
        }

        It 'starts a Refresh off a share whose engine predates the screens' {
            # AN OLDER SHARE, and it must still launch. The stub payload the rest
            # of this file uses declares no parameters at all, which is exactly
            # that machine.
            $plan = & $script:planFor (& $script:newShare)

            @($plan.UiArgument.Keys).Count | Should -Be 0
            $plan.PayloadPath | Should -Be 'Q:\Share\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1'
        }
    }
}

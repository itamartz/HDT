# A NEW SHARE COMES WITH A WAY TO START A REFRESH, the way MDT's does.
#
# Deployment Workbench's New Deployment Share puts LiteTouch.vbs in Scripts\, and
# that file is how every MDT Refresh has ever been started: an administrator on a
# machine that is already running Windows opens \\server\Share$\Scripts\ and runs
# it. HDT had the whole of a Refresh and no such file - M9's engine derives
# FullOS correctly and nothing in the product reaches it.
#
# AND THE SET IS WHAT IS TESTED HERE, NOT THE FILE THIS COMMIT ADDS.
# CLAUDE.md rule 8: "a test that names your new thing passes for it and fails
# nobody after it". So the tests below walk Get-HDTWorkspaceSeed - the one place
# that says which template folders a share is seeded from - and then walk the
# folders themselves. A seed row added tomorrow, or a file dropped into
# Templates\Launcher, is covered without this file being touched. A copy loop
# naming files one by one would be the second source of truth rule 8 forbids.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:templateRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates'
    $script:launcherRoot = Join-Path -Path $script:templateRoot -ChildPath 'Launcher'

    $script:seed = @(InModuleScope -ModuleName 'Hephaestus' { Get-HDTWorkspaceSeed })
}

Describe 'the launcher a share is created with' {

    Context 'what the module ships' {

        It 'ships a Launcher template folder' {
            Test-Path -LiteralPath $script:launcherRoot | Should -BeTrue
        }

        It 'ships the double-clickable half' {
            # A .ps1 IS NOT DOUBLE-CLICKABLE AND THAT IS THE WHOLE REASON THIS
            # FILE EXISTS. Windows opens one in an editor; the administrator who
            # browsed to \\server\Share\Scripts\ gets Notepad instead of a
            # deployment. MDT never had that problem - .vbs runs on a
            # double-click - so the .cmd is what puts HDT's launcher in
            # LiteTouch.vbs's position rather than one step behind it.
            Test-Path -LiteralPath (Join-Path -Path $script:launcherRoot -ChildPath 'Start-HDTRefresh.cmd') |
                Should -BeTrue
        }

        It 'ships the launcher itself' {
            Test-Path -LiteralPath (Join-Path -Path $script:launcherRoot -ChildPath 'Start-HDTRefresh.ps1') |
                Should -BeTrue
        }
    }

    Context 'the .cmd, which is five lines and no more' {

        BeforeAll {
            $script:cmdPath = Join-Path -Path $script:launcherRoot -ChildPath 'Start-HDTRefresh.cmd'
            $script:cmdBytes = [System.IO.File]::ReadAllBytes($script:cmdPath)
            $script:cmdText = [System.IO.File]::ReadAllText($script:cmdPath)
        }

        It 'records who launched it, the way startnet.cmd does' {
            # THE FIELD Start-HDTDeployment RECORDS INTO RESULT.json. startnet.cmd
            # sets HDT_LAUNCHED_BY=startnet and 05-05 reads it to prove the
            # machine deployed ITSELF rather than somebody typing a command. The
            # Refresh E2E needs the identical proof and gets it from the identical
            # mechanism - and a different value, because the two runs are not the
            # same run and a log that could not tell them apart would be worse
            # than one that said nothing.
            $script:cmdText | Should -BeLike '*set HDT_LAUNCHED_BY=refresh*'
        }

        It 'finds its own .ps1 relative to itself, never by a written-down path' {
            # %~dp0 IS MDT'S GetParentFolderName(WScript.ScriptFullName). The
            # share is wherever the administrator reached it from, which is not
            # necessarily the path any document on it names - a share published
            # under two names, a DFS path, a drive mapped to it. A hard-coded
            # path here would work on the machine it was written on.
            $script:cmdText | Should -BeLike '*%~dp0Start-HDTRefresh.ps1*'
        }

        It 'passes the administrator''s arguments through' {
            # LiteTouch.vbs BUILDS sArgString FROM WScript.Arguments AND HANDS IT
            # ON. -SequenceId is the one that matters: an administrator who knows
            # which sequence this machine gets should not have to answer a wizard
            # page to say so.
            $script:cmdText | Should -BeLike '*%`**'
        }

        It 'bypasses the execution policy, because a share is a remote path' {
            # A .ps1 READ OFF A UNC PATH IS BLOCKED BY RemoteSigned, which is the
            # default and is what OSDTEST01 runs. Without this the launcher fails
            # with a security message on a machine whose configuration is
            # correct.
            $script:cmdText | Should -BeLike '*-ExecutionPolicy Bypass*'
        }

        It 'is CRLF, and every line ends' {
            # cmd.exe's OWN RULE, and startnet.cmd carries the same one. A file
            # with LF endings runs, mostly, and fails in ways that name nothing.
            $script:cmdText.Split("`n").Count | Should -BeGreaterThan 1
            ($script:cmdText -split "`r`n").Count | Should -Be ($script:cmdText.Split("`n")).Count
            $script:cmdText.EndsWith("`r`n") | Should -BeTrue
        }

        It 'has no byte order mark' {
            # cmd.exe READING A BOM AS A COMMAND produces no useful message at
            # all - the same class of failure Get-HDTStartnetScript's notes
            # record, and the reason startnet.cmd is written ASCII.
            @($script:cmdBytes[0], $script:cmdBytes[1], $script:cmdBytes[2]) |
                Should -Not -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'is ASCII throughout' {
            @($script:cmdBytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }

    Context 'the .ps1, which contains no deployment logic' {

        BeforeAll {
            $script:launcherPath = Join-Path -Path $script:launcherRoot -ChildPath 'Start-HDTRefresh.ps1'

            $token = $null
            $parseError = $null
            $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:launcherPath, [ref] $token, [ref] $parseError)
            $script:parseError = $parseError

            $script:calls = @($script:ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | ForEach-Object { [string] $_.GetCommandName() } | Where-Object { $_ })
        }

        It 'parses' {
            @($script:parseError).Count | Should -Be 0
        }

        It 'makes no decision of its own - the plan does' {
            # THE SAME CLAIM StartHDTDeploymentPayload.Tests.ps1 MAKES ABOUT THE
            # WinPE ENTRY POINT, for the same reason. A launcher that worked out
            # for itself which volume to wipe, or which provider to use, would be
            # a launcher nothing could test: it runs once, on a machine, against
            # a real filesystem. Every branch belongs in Get-HDTRefreshLaunchPlan
            # where a fake can drive it.
            $script:calls | Should -Contain 'Get-HDTRefreshLaunchPlan'
            @($script:calls | Where-Object { $_ -eq 'Get-HDTRefreshLaunchPlan' }).Count | Should -Be 1
        }

        It 'touches no disk, no image and no partition' {
            # IT IS A DOOR, NOT A DEPLOYMENT. If this file could partition, the
            # claim "a Refresh is the sequence, run by the engine" would be a lie
            # that still produced a refreshed machine, and nobody would notice.
            $forbidden = @('Get-Disk', 'New-Partition', 'Set-Partition', 'Clear-Disk',
                'Format-Volume', 'Initialize-Disk', 'Remove-Partition',
                'Expand-WindowsImage', 'Apply-WindowsImage', 'Mount-WindowsImage',
                'bcdedit', 'diskpart', 'dism')

            $hit = @($script:calls | Where-Object { $forbidden -contains $_ })

            $hit | Should -BeNullOrEmpty -Because ('the launcher called: {0}' -f ($hit -join ', '))
        }

        It 'hands off to the entry point exactly once' {
            # ONE HANDOVER. Start-HDTDeployment.ps1 is the file startnet.cmd runs
            # and it already derives the phase, scans for a run in progress, opens
            # the wizard and calls Invoke-HDTTaskSequence once. Calling it twice,
            # or calling something else as well, would be a second answer to
            # "which one is running".
            $invocations = @($script:ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | Where-Object {
                    ([string] $_.Extent.Text) -like '*PayloadPath*'
                })

            $invocations.Count | Should -Be 1
        }

        It 'hands over the screens the plan resolved, and never a list of its own' {
            # SIX WINDOWS SHIPPED WITH NO FILE TO LOAD. Start-HDTDeployment.ps1
            # defaults every XAML it draws to X:\HDT\UI\ - right in WinPE, where
            # the boot image staged them onto the RAM disk - and this launcher
            # passed -BootstrapPath and -ModuleRoot and nothing else. So a
            # Refresh, on a machine with no X: at all, inherited the lot: no
            # wizard, no progress board, no failure screen, no welcome screen and
            # no boot status panel.
            #
            # THE FIX HAS TO BE A SPLAT AND NOT SIX MORE ARGUMENTS. The set of
            # screens lives in the payload's param block; a launcher naming them
            # one by one is the second source of truth CLAUDE.md rule 8 refuses,
            # and it is exactly what let six of them be wrong at once. So this
            # asserts the shape: whatever Get-HDTPayloadUiPath found is splatted
            # onto the handover, and the file names no .xaml anywhere.
            $handover = @($script:ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | Where-Object { ([string] $_.Extent.Text) -like '*PayloadPath*' })[0]

            ([string] $handover.Extent.Text) | Should -BeLike '*@uiArgument*'

            $text = [System.IO.File]::ReadAllText($script:launcherPath)
            $code = ($text -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            $code | Should -Not -BeLike '*.xaml*' -Because (
                'the launcher must carry no list of screens - the payload it runs is the one place they are named')
        }

        It 'reads the environment through the adapter, never through $env:' {
            # CLAUDE.md RULE 5. The system drive is what makes this run a REFRESH;
            # read through New-HDTEnvironmentProvider it can be faked, read
            # through $env: it cannot, and the phase is the one value that
            # unlocks ApplyImage on a resumed leg.
            $text = [System.IO.File]::ReadAllText($script:launcherPath)
            $code = ($text -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            $code | Should -Not -BeLike '*$env:SystemDrive*'
            $script:calls | Should -Contain 'New-HDTEnvironmentProvider'
        }
    }

    Context 'what a new share gets - the whole seed set, not one folder' {

        BeforeAll {
            $script:fileSystem = New-HDTFakeFileSystem
            [void] (New-HDTWorkspace -Path 'C:\ws' -Id 'HDT-NEW' -FileSystem $script:fileSystem -Confirm:$false)
        }

        It 'declares at least the wizard and the launcher' {
            # THE ROW COUNT IS NOT ASSERTED, THE MEMBERS ARE. A third seed folder
            # added tomorrow should not fail this; a launcher quietly dropped from
            # the table must.
            @($script:seed | ForEach-Object { $_.Template }) | Should -Contain 'Wizard'
            @($script:seed | ForEach-Object { $_.Template }) | Should -Contain 'Launcher'
        }

        It 'seeds every file of every folder the seed table names' {
            # THE SET TEST. It walks the table and then the directory, so neither
            # a new row nor a new file needs this test edited - and a file that
            # stops being copied fails here rather than on a share six months
            # from now.
            foreach ($row in $script:seed) {
                $source = Join-Path -Path $script:templateRoot -ChildPath ([string] $row.Template)

                Test-Path -LiteralPath $source |
                    Should -BeTrue -Because ('the seed table names Templates\{0}' -f $row.Template)

                $target = Get-HDTWorkspacePath -Root 'C:\ws' -Kind ([string] $row.Kind) -ChildPath ([string[]] @($row.ChildPath | Where-Object { $_ }))

                foreach ($file in @(Get-ChildItem -LiteralPath $source -File)) {
                    $landed = [System.IO.Path]::Combine($target, $file.Name)

                    $script:fileSystem.TestPath($landed) |
                        Should -BeTrue -Because ('{0} is in Templates\{1} and the share must get it' -f $file.Name, $row.Template)
                }
            }
        }

        It 'puts the launcher in Scripts\, where MDT puts LiteTouch.vbs' {
            $script:fileSystem.TestPath('C:\ws\Scripts\Start-HDTRefresh.cmd') | Should -BeTrue
            $script:fileSystem.TestPath('C:\ws\Scripts\Start-HDTRefresh.ps1') | Should -BeTrue
        }

        It 'still puts the wizard in Scripts\UI, because the table did not move it' {
            # THE REGRESSION THIS COMMIT COULD HAVE CAUSED. The wizard's seeding
            # was a hand-written block; turning it into a table row is exactly the
            # change that silently relocates it.
            $script:fileSystem.TestPath('C:\ws\Scripts\UI\wizard.yaml') | Should -BeTrue
        }

        It 'reports what it seeded' {
            $result = New-HDTWorkspace -Path 'C:\ws3' -Id 'HDT-NEW' -FileSystem (New-HDTFakeFileSystem) -Confirm:$false

            @($result.WizardPage) | Should -Not -BeNullOrEmpty
            @($result.Launcher) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a share that already has one' {

        It 'is left alone, because that file is somebody''s edits' {
            # DESIGN 11.2, AND THE COROLLARY CLAUDE.md RECORDS: an existing share
            # keeps its own copy and is never written over. A site that pinned its
            # launcher to a particular sequence, or added a line to the .cmd, has
            # done so on purpose.
            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\ws2\Scripts\Start-HDTRefresh.cmd' = "@echo off`r`nrem ours`r`n"
            }

            [void] (New-HDTWorkspace -Path 'C:\ws2' -Id 'HDT-NEW' -FileSystem $fileSystem -Confirm:$false)

            [string] $fileSystem.ReadAllText('C:\ws2\Scripts\Start-HDTRefresh.cmd') | Should -BeLike '*rem ours*'
        }
    }
}

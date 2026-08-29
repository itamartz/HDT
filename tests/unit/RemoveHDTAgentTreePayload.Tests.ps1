# src/Hephaestus/Payload/Remove-HDTAgentTree.ps1 - the detached deleter.
#
# WHY THERE IS A SECOND PROCESS AT ALL. C:\HDT cannot be deleted from inside the
# leg that is running out of it. Start-HDTResume.ps1 prepends C:\HDT\Modules to
# PSModulePath, ConvertFrom-HDTYaml imports powershell-yaml from there, and
# powershell-yaml LoadFile()s YamlDotNet.dll - which Windows PowerShell 5.1
# cannot unload for the life of the process. A recursive delete from inside
# therefore throws part way and leaves a HALF-DELETED tree, which is worse than
# the folder it was trying to remove.
#
# SO THE PARENT IS KILLED FIRST, AND ONLY THEN IS THE TREE REMOVED. That is
# PSD's mechanism (PSDStart.ps1:1005 copies PSDFinal.ps1 out to $env:TEMP,
# :1033 starts it with -ParentPID; PSDFinal.ps1:30 stops that process before
# :53-62 removes the tree) and MDT's before it. See NOTICE.md.
#
# AND THE FINISH ACTION COMES WITH IT (PSDFinal.ps1:71-84). The parent is dead
# by the time the tree goes, so the parent cannot be the thing that restarts the
# machine - it would have to do it BEFORE the delete, and the machine would go
# down with C:\HDT still on it.
#
# IT IS DRIVEN THROUGH THREE INJECTED SCRIPT BLOCKS so all of that is provable
# from a desk. Their defaults are the real Stop-Process / Remove-Item / shutdown
# calls and are branch-free; everything that DECIDES anything is here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:deleterPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Remove-HDTAgentTree.ps1'

    # A REAL DIRECTORY, because the guard's last question is "does this hold a
    # staged agent?" and that one cannot be answered against a fake: this script
    # runs with no module loaded and therefore has no injected IFileSystem. What
    # it has instead is a guard that reaches Test-Path once.
    $script:newTree = {
        $root = Join-Path -Path $TestDrive -ChildPath ('HDT-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void] (New-Item -Path $root -ItemType Directory -Force)
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Start-HDTResume.ps1') -Value '# the agent' -Encoding UTF8

        return $root
    }

    # The ordered operation list, exactly as the engine's own benchmark test
    # asserts one.
    $script:newProbe = {
        param([bool] $RemoveThrows)

        $log = [System.Collections.ArrayList]::new()
        $fails = $RemoveThrows

        return [pscustomobject] @{
            Log        = $log
            StopParent = { param($ProcessId) [void] $log.Add(('StopParent({0})' -f $ProcessId)) }.GetNewClosure()
            RemoveTree = {
                param($Path)
                [void] $log.Add(('RemoveTree({0})' -f $Path))
                if ($fails) { throw [System.IO.IOException]::new('the file is in use by another process') }
            }.GetNewClosure()
            Finish     = { param($Action, $DelaySecond) [void] $log.Add(('Finish({0},{1})' -f $Action, $DelaySecond)) }.GetNewClosure()
        }
    }
}

Describe 'Remove-HDTAgentTree.ps1' {

    It 'is shipped as a payload script, beside the agent it deletes' {
        Test-Path -LiteralPath $script:deleterPath -PathType Leaf | Should -BeTrue
    }

    It 'supports ShouldProcess, because it is the one genuinely destructive thing here' {
        (Get-Command -Name $script:deleterPath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    Context 'the order, which is the whole reason it exists' {

        It 'stops the parent, then removes the tree, then finishes' {
            $root = & $script:newTree
            $probe = & $script:newProbe $false

            & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'Restart' -DelaySecond 5 `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false

            @($probe.Log) | Should -Be @(
                'StopParent(4242)'
                ('RemoveTree({0})' -f $root)
                'Finish(Restart,5)'
            )
        }

        It 'still removes the tree when the parent has already gone' {
            # A leg that exited on its own between the handoff and this process
            # starting. Stop-Process on a PID nobody owns must not become the
            # reason C:\HDT survives.
            $root = & $script:newTree
            $log = [System.Collections.ArrayList]::new()

            & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'None' `
                -StopParent { throw [System.ArgumentException]::new('Cannot find a process with the process identifier 4242.') } `
                -RemoveTree { param($Path) [void] $log.Add(('RemoveTree({0})' -f $Path)) } `
                -Finish { param($Action, $DelaySecond) [void] $log.Add('Finish') } -Confirm:$false

            @($log) | Should -Be @(('RemoveTree({0})' -f $root), 'Finish')
        }
    }

    # A MACHINE LEFT ON IS THE SECOND FAILURE, NOT THE FIRST. If the delete
    # throws, the technician's bench still expects the machine to restart - and
    # a deployment that succeeded is not allowed to end with somebody walking
    # over to a desktop that never powered down.
    Context 'when the delete fails' {

        It 'still performs the finish action' {
            $root = & $script:newTree
            $probe = & $script:newProbe $true

            & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'Shutdown' -DelaySecond 0 `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false

            @($probe.Log)[-1] | Should -Be 'Finish(Shutdown,0)'
        }

        It 'does not throw the failure out at a process nobody is reading' {
            $root = & $script:newTree
            $probe = & $script:newProbe $true

            { & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'None' `
                    -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false } |
                Should -Not -Throw
        }
    }

    # THE REFUSAL, AND IT IS THE MOST IMPORTANT TEST IN THIS FILE. This script
    # runs detached, elevated, with a path handed to it on a command line. A
    # value that arrived wrong - empty, a drive root, the parent of the thing
    # that was meant - must stop it dead rather than be deleted recursively.
    # CLAUDE.md's protected-path rule is absolute and this is where it is kept.
    Context 'what it refuses to delete' {

        It 'refuses a target that is not the staging root' -ForEach @(
            @{ Case = 'nothing at all'; Path = '' }
            @{ Case = 'whitespace'; Path = '   ' }
            @{ Case = 'a drive root'; Path = 'C:\' }
            @{ Case = 'a bare drive'; Path = 'C:' }
            @{ Case = 'another drive root'; Path = 'D:\' }
            @{ Case = 'a relative path'; Path = 'HDT' }
            @{ Case = 'a relative path with a separator'; Path = '..\HDT' }
            @{ Case = 'a UNC share root'; Path = '\\server\share' }
            @{ Case = 'the Windows directory'; Path = 'C:\Windows' }
            @{ Case = 'a user profile'; Path = 'C:\Users\someone' }
        ) {
            $probe = & $script:newProbe $false

            { & $script:deleterPath -Path $PSItem.Path -ParentProcessId 4242 -FinishAction 'None' `
                    -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false } |
                Should -Throw -ExpectedMessage '*HDTCleanupRefused*'

            @($probe.Log) | Should -BeNullOrEmpty
        }

        It 'refuses the parent of the staging root, which is where a path bug lands' {
            $root = & $script:newTree
            $probe = & $script:newProbe $false

            { & $script:deleterPath -Path (Split-Path -Parent $root) -ParentProcessId 4242 -FinishAction 'None' `
                    -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false } |
                Should -Throw -ExpectedMessage '*HDTCleanupRefused*'

            Test-Path -LiteralPath $root | Should -BeTrue
        }

        It 'refuses a folder that exists but holds no staged agent' {
            $notOurs = Join-Path -Path $TestDrive -ChildPath 'someone-elses-HDT'
            [void] (New-Item -Path $notOurs -ItemType Directory -Force)
            Set-Content -LiteralPath (Join-Path -Path $notOurs -ChildPath 'notes.txt') -Value 'mine' -Encoding UTF8

            $probe = & $script:newProbe $false

            { & $script:deleterPath -Path $notOurs -ParentProcessId 4242 -FinishAction 'None' `
                    -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false } |
                Should -Throw -ExpectedMessage '*HDTCleanupRefused*'

            Test-Path -LiteralPath (Join-Path -Path $notOurs -ChildPath 'notes.txt') | Should -BeTrue
        }

        It 'refuses before it kills anything, so a bad path cannot take the leg down with it' {
            $probe = & $script:newProbe $false

            { & $script:deleterPath -Path 'C:\' -ParentProcessId 4242 -FinishAction 'None' `
                    -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false } |
                Should -Throw

            @($probe.Log) | Should -Not -Contain 'StopParent(4242)'
        }
    }

    Context 'under -WhatIf' {

        It 'names the tree and removes nothing' {
            $root = & $script:newTree
            $probe = & $script:newProbe $false

            & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'Restart' `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -WhatIf

            @($probe.Log) | Should -BeNullOrEmpty
            Test-Path -LiteralPath $root | Should -BeTrue
        }
    }
}

# THE COMMAND LINE, RUN RATHER THAN READ - AND IT CAUGHT A LIVE DEFECT.
#
# Every other test in this file invokes the deleter as a PowerShell command,
# which binds parameters the way the PARSER does. The deployed machine does not:
# it starts a whole new powershell.exe, and that is a different binder.
#
# powershell.exe -File PASSES EVERY ARGUMENT AFTER THE SCRIPT AS A LITERAL
# STRING. '-Confirm:$false' arrived as the six characters $false, which cannot
# convert to a SwitchParameter, and the deleter died on argument binding with
# exit 1 without running a line. The unit tests were green throughout - they
# asserted the string, and a string cannot fail to bind - so C:\HDT would have
# survived on every machine HDT deployed, which is the whole defect this work
# exists to fix, reintroduced one layer down.
#
# SO THE ASSERTION IS THAT THE FOLDER IS GONE, and the command line under test
# is the one Start-HDTAgentRemoval actually builds rather than one this file
# writes out again. A second copy of that string is a second thing to be wrong.
Describe 'the command line a deployed machine really runs' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    }

    It 'binds its parameters and removes the tree' {
        # A REAL TREE AND A REAL %TEMP%, both under TestDrive - Pester deletes
        # it, and nothing here names a path outside it.
        $root = Join-Path -Path $TestDrive -ChildPath 'HDT'
        $temp = Join-Path -Path $TestDrive -ChildPath 'Temp'
        [void] (New-Item -Path $root -ItemType Directory -Force)
        [void] (New-Item -Path (Join-Path -Path $root -ChildPath 'Modules') -ItemType Directory -Force)
        [void] (New-Item -Path $temp -ItemType Directory -Force)

        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Start-HDTResume.ps1') -Value '# agent' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Modules\held.txt') -Value 'x' -Encoding UTF8
        Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Remove-HDTAgentTree.ps1') `
            -Destination $root

        # THE REAL FILESYSTEM, so the deleter is really copied out; a FAKE
        # process service, so this test never starts one and never restarts
        # this machine. The command line it would have run is what is executed
        # below, under this test's control.
        $handoff = InModuleScope -ModuleName 'Hephaestus' -Parameters @{
            Root        = $root
            Environment = (New-HDTFakeEnvironmentProvider -Variable @{ TEMP = $temp; SystemRoot = $env:SystemRoot })
            Process     = (New-HDTFakeProcessService)
        } -ScriptBlock {
            param($Root, $Environment, $Process)

            Start-HDTAgentRemoval -Path $Root -FinishAction 'None' -DelaySecond 0 -ProcessId 0 `
                -FileSystem (New-HDTFileSystem) -Process $Process -Environment $Environment
        }

        [bool] $handoff.Started | Should -BeTrue
        Test-Path -LiteralPath $handoff.ScriptPath | Should -BeTrue

        # ParentProcessId 0 in the line above means nothing is killed, so this
        # can be waited on. Everything else about it is what ships.
        $run = Start-Process -FilePath $handoff.Shell -ArgumentList $handoff.Argument `
            -PassThru -Wait -WindowStyle Hidden

        [int] $run.ExitCode | Should -Be 0 -Because 'a non-zero exit here is the deleter failing to bind its own arguments'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    Context 'the staged driver folder, which PSD removes and this did not' {

        # 4.2 GB LEFT ON EVERY MACHINE. ApplyDrivers stages driver packages to
        # <os volume>\Drivers so the answer file's DriverPaths can inject them
        # offline; on a real Latitude that folder was 1,452 files and 4.2 GB, and
        # it was still there after the deployment finished. It has no purpose
        # once Windows has installed from it.
        #
        # PSD REMOVES IT IN THE SAME BREATH AS MININT. PSDFinal.ps1:53-62 walks
        # the fixed volumes removing "MININT","Drivers" - HDT's MININT is C:\HDT,
        # and this script already removes that, so the driver folder belongs on
        # the same pass and for the same reason: the machine is finished with it.
        #
        # IT GOES AFTER THE AGENT AND BEFORE THE FINISH ACTION, so a restart
        # cannot happen with half a driver store deleted.

        BeforeAll {
            # IN A BeforeAll, NOT THE Context BODY. A Context body runs during
            # DISCOVERY, where $TestDrive does not exist yet and the assignment
            # does not survive to the run phase - the helper comes back null and
            # every It fails on '&' rather than on the thing it tests.
            $script:newDriverFolder = {
                param([string] $Leaf)

                $path = Join-Path -Path $TestDrive -ChildPath $Leaf
                [void] (New-Item -Path $path -ItemType Directory -Force)
                Set-Content -LiteralPath (Join-Path -Path $path -ChildPath 'net.inf') -Value '; a driver' -Encoding UTF8

                return $path
            }
        }

        It 'removes it after the agent tree and before the finish action' {
            $root = & $script:newTree
            $drivers = & $script:newDriverFolder 'Drivers'
            $probe = & $script:newProbe $false

            & $script:deleterPath -Path $root -DriverPath $drivers -ParentProcessId 4242 `
                -FinishAction 'Restart' -DelaySecond 5 `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false

            @($probe.Log) | Should -Be @(
                'StopParent(4242)'
                ('RemoveTree({0})' -f $root)
                ('RemoveTree({0})' -f $drivers)
                'Finish(Restart,5)'
            )
        }

        It 'does nothing extra when no driver folder is named' {
            $root = & $script:newTree
            $probe = & $script:newProbe $false

            & $script:deleterPath -Path $root -ParentProcessId 4242 -FinishAction 'Restart' -DelaySecond 5 `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false

            @($probe.Log) | Should -Be @(
                'StopParent(4242)'
                ('RemoveTree({0})' -f $root)
                'Finish(Restart,5)'
            )
        }

        It 'refuses a folder that is not called Drivers' {
            # THE GUARD IS THE POINT. This runs detached, elevated, with
            # -Recurse -Force and nobody reading its output, so the one thing it
            # must never do is take a path somebody got wrong. A caller that
            # passed the OS volume, or C:\Windows, gets nothing removed.
            $root = & $script:newTree
            $notDrivers = & $script:newDriverFolder 'NotDrivers'
            $probe = & $script:newProbe $false

            & $script:deleterPath -Path $root -DriverPath $notDrivers -ParentProcessId 4242 `
                -FinishAction 'Restart' -DelaySecond 5 `
                -StopParent $probe.StopParent -RemoveTree $probe.RemoveTree -Finish $probe.Finish -Confirm:$false

            @($probe.Log) | Should -Not -Contain ('RemoveTree({0})' -f $notDrivers)
            Test-Path -LiteralPath $notDrivers | Should -BeTrue
        }

        It 'still finishes when the driver folder will not go' {
            # Same rule the agent tree runs under: nobody is reading this
            # process's output, so a throw here would silently cost the machine
            # its restart as well as its cleanup.
            $root = & $script:newTree
            $drivers = & $script:newDriverFolder 'Drivers'

            $log = [System.Collections.ArrayList]::new()
            $remove = {
                param($Path)
                [void] $log.Add(('RemoveTree({0})' -f $Path))
                if ($Path -like '*Drivers') { throw [System.IO.IOException]::new('the file is in use by another process') }
            }.GetNewClosure()

            & $script:deleterPath -Path $root -DriverPath $drivers -ParentProcessId 0 -FinishAction 'Restart' -DelaySecond 5 `
                -StopParent { param($ProcessId) } -RemoveTree $remove `
                -Finish { param($Action, $DelaySecond) [void] $log.Add(('Finish({0},{1})' -f $Action, $DelaySecond)) }.GetNewClosure() `
                -Confirm:$false

            @($log) | Should -Contain 'Finish(Restart,5)'
        }
    }
}

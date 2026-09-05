# The WindowsUpdate step, DESIGN 10.1. Online patching in the full OS, through
# IUpdateSessionService, with the multi-pass loop that is the entire point.
#
# MULTIPLE PASSES ARE THE POINT. Installing one update supersedes or reveals
# another, so the step searches, installs, reboots if it has to and searches
# AGAIN, until a pass finds nothing applicable or maxPasses is reached. A
# single-pass Windows Update step is the classic MDT mistake that leaves
# machines half-patched, and PSD's own PSDWindowsUpdate.ps1 is single-pass.
#
# NOTHING HERE REACHES A WINDOWS UPDATE AGENT. Every assertion runs against
# New-HDTFakeUpdateSessionService (08-01-02), which mutates its seeded state the
# way the agent does - a successful install stops coming back from the next
# search - so the loop's TERMINATION is proved rather than assumed. No update is
# searched for, downloaded or installed by this file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The phase's real staging: the 2026-08 cumulative update for Windows 11
    # 24H2 x64 and the matching .NET cumulative. KBArticleId carries the bare
    # number, which is what the agent returns.
    $script:cuRow = @{
        UpdateId     = '11111111-1111-1111-1111-111111111111'
        Title        = '2026-08 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5121003)'
        KBArticleId  = @('5121003')
        Category     = @('Security Updates', 'Windows 11')
        IsDownloaded = $false
        EulaAccepted = $false
        SizeByte     = [long] 15032385536
    }

    $script:netRow = @{
        UpdateId     = '22222222-2222-2222-2222-222222222222'
        Title        = '2026-08 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11 (KB5120710)'
        KBArticleId  = @('5120710')
        Category     = @('Security Updates')
        IsDownloaded = $true
        EulaAccepted = $true
        SizeByte     = [long] 83886080
    }

    $script:previewRow = @{
        UpdateId     = '33333333-3333-3333-3333-333333333333'
        Title        = '2026-09 Preview Cumulative Update for Windows 11 (KB5122222)'
        KBArticleId  = @('5122222')
        Category     = @('Update Rollups')
        IsDownloaded = $true
        EulaAccepted = $true
        SizeByte     = [long] 104857600
    }

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'WindowsUpdate'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $bag
        }
    }

    $script:newContext = {
        param($UpdateSession, [System.Collections.IDictionary] $Variable)

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 6, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 1000

        $argument = @{
            FileSystem = $script:fileSystem
            Clock      = $script:clock
        }
        if ($null -ne $UpdateSession) { $argument['UpdateSession'] = $UpdateSession }

        $catalog = New-HDTServiceCatalog @argument

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level 'Info'

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
            -Variable $bag -Service $catalog -Log $log
        $context.SetStep(1, 'Windows Update', 'WindowsUpdate', 'C:\HDT\Logs\Steps\001-WindowsUpdate.log')

        return $context
    }

    $script:jsonlRecord = {
        param($FileSystem)

        $text = ''
        if ($FileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $FileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }

    # The arguments of one recorded operation, flattened for an assertion.
    $script:operationArgument = {
        param($Service, [string] $Operation)

        return @($Service.Operations | Where-Object { $_.Operation -eq $Operation } |
                ForEach-Object { @($_.Arguments) })
    }
}

Describe 'Invoke-HDTWindowsUpdateStep' {

    Context 'the service' {

        It 'asks the catalog for the UpdateSession service' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Contain 'SearchUpdate'
        }

        It 'fails naming the service when the run was started without one' {
            $context = & $script:newContext $null
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
            [string] $result.Message | Should -BeLike '*UpdateSession*'
        }
    }

    Context 'the server' {

        It 'points the client at the server the step names' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ server = 'http://wsus.contoso.local:8530' })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Contain 'SetServer'
            @(& $script:operationArgument $wua 'SetServer') | Should -Contain 'http://wsus.contoso.local:8530'
        }

        It 'expands a variable token before pointing at it' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua ([ordered] @{ HDTWSUSServer = 'http://wsus.lab.local:8530' })
            $step = & $script:newStep 'Windows Update' ([ordered] @{ server = '%HDTWSUSServer%' })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @(& $script:operationArgument $wua 'SetServer') | Should -Contain 'http://wsus.lab.local:8530'
        }

        # DESIGN 10.1: omit server for Windows Update, or for whatever the
        # machine's own policy already points at. Writing a server nobody asked
        # for would take a domain machine off its own WSUS.
        It 'does not call SetServer when the step names no server' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Not -Contain 'SetServer'
        }

        It 'does not call SetServer when the variable expands to nothing' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua ([ordered] @{ HDTWSUSServer = '' })
            $step = & $script:newStep 'Windows Update' ([ordered] @{ server = '%HDTWSUSServer%' })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Not -Contain 'SetServer'
        }

        It 'logs which server it used and where that value came from' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ server = 'http://wsus.contoso.local:8530' })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*wsus.contoso.local*' })

            $record.Count | Should -BeGreaterThan 0
        }

        It 'says in the log that it left the machine policy alone when no server was named' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*no server*' })

            $record.Count | Should -BeGreaterThan 0
        }
    }

    Context 'one pass' {

        It 'searches for updates that are not installed' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @(& $script:operationArgument $wua 'SearchUpdate') | Should -Contain 'IsInstalled = 0'
        }

        It 'accepts the EULA of every update it is going to install' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow) -RebootRequired $false
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @(& $script:operationArgument $wua 'AcceptEula') | Should -Contain $script:cuRow.UpdateId
        }

        It 'downloads an update that is not already downloaded' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Contain 'DownloadUpdate'
        }

        # A 14 GB cumulative update the agent already has is fifteen minutes
        # somebody does not have to wait through twice.
        It 'does not download an update the agent already has' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Not -Contain 'DownloadUpdate'
        }

        It 'installs each update it selected' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow, $script:netRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.installed) | Should -Contain 'KB5121003'
            @($result.Data.installed) | Should -Contain 'KB5120710'
        }

        # ONE AT A TIME, SO EACH CAN BE TIMED AND NAMED. A batch install reports
        # one aggregate result, and DESIGN 10.1 asks for per-update timing
        # precisely so a slow deployment can be explained.
        It 'installs them one at a time, so each can be timed and named' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow, $script:netRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $call = @($wua.Operations | Where-Object { $_.Operation -eq 'InstallUpdate' })

            $call.Count | Should -Be 2
            foreach ($one in $call) { @($one.Arguments[0]).Count | Should -Be 1 }
        }

        It 'completes when the first pass finds nothing applicable' {
            $wua = New-HDTFakeUpdateSessionService -Update @()
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            [string] $result.Message | Should -BeLike '*nothing applicable*'
            $result.Data.pass | Should -Be 1
        }

        It 'reports the KB, the title and the classification of every update it installed' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'update.apply' })

            $record.Count | Should -BeGreaterThan 0
            [string] $record[0].data.kb | Should -BeLike '*KB5121003*'
            [string] $record[0].data.title | Should -BeLike '*Cumulative Update*'
            [string] $record[0].data.classification | Should -BeLike '*Security Updates*'
        }
    }

    Context 'the multi-pass loop, which is the point' {

        It 'searches again after a pass that installed something' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                (, @($script:cuRow))
                (, @())
            )
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($wua.Operations | Where-Object { $_.Operation -eq 'SearchUpdate' }).Count | Should -Be 2
        }

        It 'stops when a pass returns no applicable updates' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                (, @($script:cuRow))
                (, @())
            )
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            $result.Data.pass | Should -Be 2
        }

        # THE ONE THING A SINGLE FIXED RESULT CANNOT SAY, and the reason the
        # loop exists at all.
        It 'installs an update that only appeared after the first pass was installed' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                (, @($script:cuRow))
                (, @($script:netRow))
                (, @())
            )
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            @($result.Data.installed) | Should -Be @('KB5121003', 'KB5120710')
            $result.Data.pass | Should -Be 3
        }

        It 'stops at maxPasses and says so rather than looping forever' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @( (, @($script:cuRow)) )
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 2 })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            $result.Data.pass | Should -Be 2
            [string] $result.Message | Should -BeLike '*maxPasses*'
            @($wua.Operations | Where-Object { $_.Operation -eq 'SearchUpdate' }).Count | Should -Be 2
        }

        It 'defaults maxPasses to 3' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @( (, @($script:cuRow)) )
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Data.maxPasses | Should -Be 3
            @($wua.Operations | Where-Object { $_.Operation -eq 'SearchUpdate' }).Count | Should -Be 3
        }

        It 'refuses a maxPasses below 1 at the step, naming the value' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 0 })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
            [string] $result.Message | Should -BeLike '*maxPasses*'
            [string] $result.Message | Should -BeLike '*0*'
            $wua.GetOperationName() | Should -Not -Contain 'SearchUpdate'
        }

        # A pass whose search returned updates but whose filter kept none is a
        # terminating pass: another pass would return the same set.
        It 'counts a pass that installed nothing as the terminating pass' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:previewRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ categories = @('SecurityUpdates') })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            $result.Data.pass | Should -Be 1
            @($wua.Operations | Where-Object { $_.Operation -eq 'InstallUpdate' }).Count | Should -Be 0
        }
    }

    Context 'the reboot inside the loop' {

        It 'returns RebootRequested with Reenter when a pass needs a restart' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow) `
                -InstallResult @{ '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 2; RebootRequired = $true } }
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'RebootRequested'
            $result.Reenter | Should -BeTrue
        }

        # WITHOUT THE CHECKPOINT THE STEP RESTARTS AT PASS ONE ON EVERY LEG and
        # maxPasses bounds nothing at all.
        It 'checkpoints the passes it has completed before asking for the restart' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow) `
                -InstallResult @{ '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 2; RebootRequired = $true } }
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $null = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $context.Variable.Contains('_HDTWindowsUpdatePass') | Should -BeTrue
            [int] $context.Variable['_HDTWindowsUpdatePass'] | Should -Be 1
            @($context.Variable['_HDTWindowsUpdateInstalled']) | Should -Contain 'KB5121003'
        }

        It 'resumes at the next pass on the leg after the reboot, not at pass one' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                (, @($script:netRow))
                (, @())
            )
            $context = & $script:newContext $wua ([ordered] @{
                    '_HDTWindowsUpdatePass'      = 1
                    '_HDTWindowsUpdateInstalled' = [string[]] @('KB5121003')
                })
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Data.pass | Should -Be 3
            @($result.Data.installed) | Should -Contain 'KB5121003'
            @($result.Data.installed) | Should -Contain 'KB5120710'
        }

        It 'counts the passes across legs, so maxPasses bounds the whole step' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow)
            $context = & $script:newContext $wua ([ordered] @{ '_HDTWindowsUpdatePass' = 3 })
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 3 })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            $wua.GetOperationName() | Should -Not -Contain 'InstallUpdate'
            [string] $result.Message | Should -BeLike '*maxPasses*'
        }

        # A servicing stack update that goes in first leaves a pending restart
        # without setting the batch flag, and the next search then returns stale
        # results. The install result and the machine are two different
        # questions.
        It 'asks the machine whether a restart is pending, not only the install result' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow) -RebootRequired $true
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $wua.GetOperationName() | Should -Contain 'GetRebootRequired'
            $result.Status | Should -Be 'RebootRequested'
        }

        It 'does not ask for a restart when nothing needed one' {
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                (, @($script:netRow))
                (, @())
            ) -RebootRequired $false
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            $result.Reenter | Should -BeFalse
        }
    }

    Context 'filtering' {

        It 'installs only updates in the categories the step named' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow, $script:previewRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{
                    categories = @('SecurityUpdates')
                    maxPasses  = 1
                })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.installed) | Should -Be @('KB5120710')
            @($result.Data.skippedCategory) | Should -Contain 'KB5122222'
        }

        It 'skips an excluded update and records which pattern excluded it' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow, $script:previewRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{
                    exclude   = @('*Preview*')
                    maxPasses = 1
                })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.skippedExcluded) | Should -Contain 'KB5122222'

            $record = @(& $script:jsonlRecord $script:fileSystem |
                    Where-Object { [string] $_.message -like '*excluded by *Preview**' })
            $record.Count | Should -BeGreaterThan 0
        }

        # TWO KINDS OF SKIP, NEVER ONE NUMBER. One says the administrator
        # excluded it; the other says it was not in scope. Merging them loses
        # the answer to "why did this machine not get that patch".
        It 'reports an update it skipped separately from one it installed' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow, $script:previewRow)
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{
                    categories = @('SecurityUpdates')
                    exclude    = @('KB5122222')
                    maxPasses  = 1
                })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.installed) | Should -Be @('KB5120710')
            @($result.Data.skippedExcluded) | Should -Contain 'KB5122222'
            @($result.Data.skippedCategory).Count | Should -Be 0
        }

        It 'expands a variable token in each element of a list' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow, $script:previewRow)
            $context = & $script:newContext $wua ([ordered] @{ HDTExcludePattern = '*Preview*' })
            $step = & $script:newStep 'Windows Update' ([ordered] @{
                    exclude   = @('%HDTExcludePattern%')
                    maxPasses = 1
                })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.skippedExcluded) | Should -Contain 'KB5122222'
        }
    }

    Context 'failure' {

        It 'records a failed update and goes on to the next one' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow, $script:netRow) `
                -InstallResult @{ '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 4; HResult = -2145124329 } }
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            @($result.Data.installed) | Should -Be @('KB5120710')
            @($result.Data.failed).Count | Should -Be 1
        }

        # At that point another pass would do exactly the same thing.
        It 'fails the step when every update in a pass failed' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow) `
                -InstallResult @{ '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 4; HResult = -2145124329 } }
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
        }

        It 'reports the HResult of a failed install, not only that it failed' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:cuRow) `
                -InstallResult @{ '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 4; HResult = -2145124329 } }
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            [int] @($result.Data.failed)[0].hresult | Should -Be -2145124329
            [string] @($result.Data.failed)[0].kb | Should -BeLike '*KB5121003*'
        }

        It 'fails naming the criteria when the search itself throws' {
            $wua = New-HDTFakeUpdateSessionService -FailSearch
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
            [string] $result.Message | Should -BeLike '*IsInstalled = 0*'
        }

        It 'records an update the agent threw on rather than losing the pass' {
            $wua = New-HDTFakeUpdateSessionService -Update @($script:netRow) -FailInstall
            $context = & $script:newContext $wua
            $step = & $script:newStep 'Windows Update' ([ordered] @{})

            $result = Invoke-HDTWindowsUpdateStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
            @($result.Data.failed).Count | Should -Be 1
        }
    }

    Context 'the log' {

        BeforeEach {
            $script:logWua = New-HDTFakeUpdateSessionService -Update @($script:cuRow, $script:netRow)
            $script:logContext = & $script:newContext $script:logWua
            $script:logStep = & $script:newStep 'Windows Update' ([ordered] @{ maxPasses = 1 })

            $null = Invoke-HDTWindowsUpdateStep -Step $script:logStep -Context $script:logContext

            $script:logRecord = @(& $script:jsonlRecord $script:fileSystem)
        }

        It 'logs the elapsed time of each update install' {
            $record = @($script:logRecord | Where-Object { $_.event -eq 'update.apply' })

            $record.Count | Should -Be 2
            foreach ($one in $record) { $one.data.durationMs | Should -Not -BeNullOrEmpty }
        }

        It 'logs the plan before it installs anything' {
            $planIndex = -1
            $applyIndex = -1

            for ($i = 0; $i -lt $script:logRecord.Count; $i++) {
                if ($planIndex -lt 0 -and [string] $script:logRecord[$i].message -like '*applicable*') { $planIndex = $i }
                if ($applyIndex -lt 0 -and $script:logRecord[$i].event -eq 'update.apply') { $applyIndex = $i }
            }

            $planIndex | Should -BeGreaterThan -1
            $applyIndex | Should -BeGreaterThan -1
            $planIndex | Should -BeLessThan $applyIndex
        }

        It 'logs the pass number on every line that belongs to a pass' {
            $record = @($script:logRecord | Where-Object { $_.event -eq 'update.apply' })

            foreach ($one in $record) { [int] $one.data.pass | Should -Be 1 }
        }

        # ONE RECORD PER UPDATE, NOT ONE SUMMARY FOR THE PASS. Twenty outcomes
        # an administrator has to be able to filter, which is what
        # update.apply's own comment in Write-HDTLog.ps1 says it is for.
        It 'writes one update.apply record per update, not one summary for the pass' {
            @($script:logRecord | Where-Object { $_.event -eq 'update.apply' }).Count | Should -Be 2
        }

        # native.exec is for a process the step shelled out to, and this step
        # shells out to nothing. Using it would put a COM call in the stream a
        # technician filters for command lines.
        It 'writes no native.exec record, because it shells out to nothing' {
            @($script:logRecord | Where-Object { $_.event -eq 'native.exec' }).Count | Should -Be 0
        }

        It 'writes a step.progress frame naming which update of how many, before it installs it' {
            $record = @($script:logRecord | Where-Object { $_.event -eq 'step.progress' })

            $record.Count | Should -BeGreaterOrEqual 2
            [int] $record[0].data.total | Should -Be 2
            [int] $record[0].data.done | Should -Be 0
        }

        # A STILL BAR HAS TO SAY WHAT IT IS WAITING ON. The install is a single
        # blocking InstallUpdate call, so the frame written before it is the
        # last thing the screen gets until it returns - and one update can be
        # twenty minutes.
        It 'names the update in that frame, so a still bar still says what it is waiting on' {
            $record = @($script:logRecord | Where-Object { $_.event -eq 'step.progress' })

            [string] $record[0].data.update | Should -BeLike '*KB5121003*'
            [string] $record[0].message | Should -BeLike '*1 of 2*'
        }
    }

    Context 'the step type registry' {

        It 'is discovered as the WindowsUpdate type' {
            $type = Get-HDTStepType -Name 'WindowsUpdate'

            $type | Should -Not -BeNullOrEmpty
            [string] $type.InvokeCommand | Should -Be 'Invoke-HDTWindowsUpdateStep'
        }
    }
}

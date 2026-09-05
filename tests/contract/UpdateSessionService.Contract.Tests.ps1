# The IUpdateSessionService contract (PROJECT constraint 4 / CLAUDE.md rule 5,
# DESIGN 10.1).
#
# Six methods:
#
#   SetServer(url)              -> nothing      point the agent at a WSUS
#   SearchUpdate(criteria)      -> object[]     one row per update the search matched
#   AcceptEula(updateId)        -> nothing
#   DownloadUpdate(updateId[])  -> result
#   InstallUpdate(updateId[])   -> result
#   GetRebootRequired()         -> bool         asked of the MACHINE
#
# An update row carries UpdateId, Title, KBArticleId, Category, IsDownloaded,
# EulaAccepted and SizeByte. A download or install result carries Success,
# ResultCode, HResult, RebootRequired and PerUpdate - one element per update,
# with UpdateId, ResultCode and HResult.
#
# SEARCHUPDATE IS FLAT AND UNFILTERED, for the reason IDiskService's three
# listings and IFeatureService.GetFeature() are: it returns every update the
# criteria matched, with its categories and its KB numbers, and it filters
# nothing. Deciding WHICH of them to install - the category list, the exclude
# patterns, the explicit KB numbers of DESIGN 10.1's step - is pure logic that
# can be tested, rather than an adapter argument that cannot.
#
# SETSERVER IS ON THE ADAPTER AND NOT IN THE STEP, even though pointing a client
# at WSUS is four registry values and a service restart. PSD's
# PSDWindowsUpdate.ps1 writes WUServer, WUStatusServer, AU\UseWUServer = 1 and
# AU\NoAutoUpdate = 1 under HKLM\SOFTWARE\Policies\Microsoft\Windows\
# WindowsUpdate and restarts wuauserv, and none of that is a decision - it is the
# IO that makes a ServerSelection of ssManagedServer mean anything. The STEP
# decides whether to call it; the ADAPTER does it. That is what keeps the adapter
# branch-free: it is only ever called with a URL, so it never has to ask whether
# it has one.
#
# THE REAL ROW'S BEHAVIOUR IS NEVER RUN. WUA does not exist in WinPE at all
# (DESIGN 10.1 - "WUA is unavailable in WinPE; this step is full-OS only"), so
# the real adapter cannot run everywhere; and searching, downloading or
# installing a real update on a developer's laptop is not something a test suite
# may do. The real adapter is therefore branch-free by rule 1, and every
# behavioural assertion below runs against the hand-written fake - which is
# precisely why the fake has to be worth trusting.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9).

# The environment predicate, at FILE SCOPE, evaluated at discovery. Building the
# COM object proves the agent is registered; it searches nothing.
$script:HDTWuaPresent = $false
try {
    $probe = New-Object -ComObject 'Microsoft.Update.Session'
    $script:HDTWuaPresent = $null -ne $probe
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($probe)
} catch {
    $script:HDTWuaPresent = $false
}

if (-not $script:HDTWuaPresent) {
    Write-Warning 'IUpdateSessionService: the real adapter''s machine row is skipped. The Windows Update Agent (Microsoft.Update.Session) is not registered here, and DESIGN 10.1 records that it does not exist in WinPE at all - the WindowsUpdate step is full-OS only. The fake carries every behavioural assertion.'
}

# THE FAKE'S DEFAULT SET IS THE DATA THIS CONTRACT ASSERTS ON, and it is seeded
# by New-HDTFakeUpdateSessionService rather than named here:
#
#   1111...  Security Update for Windows (KB5031354)
#            KB 5031354, Security Updates + Windows 11, not downloaded, EULA accepted
#   2222...  2026-09 Cumulative Update for Windows 11 (KB5029351)
#            KB 5029351, Critical Updates + Windows 11, downloaded, EULA NOT accepted
#
# It is not written into a $script: variable here because a discovery-time
# variable is not in scope when the Factory scriptblock RUNS - Pester evaluates
# it in the run phase, where the file-scope value is gone and the fake would be
# seeded with nothing. That failure is silent: every count assertion reads 0 and
# looks like a broken fake. FeatureService.Contract puts its literal inside the
# scriptblock for the same reason.

$script:HDTImplementation = @(
    @{
        Name    = 'FakeUpdateSessionService'
        Factory = { New-HDTFakeUpdateSessionService }
        IsReal  = $false
    }
    @{
        Name    = 'UpdateSessionService'
        Factory = { New-HDTUpdateSessionService }
        IsReal  = $true
    }
)

Describe 'IUpdateSessionService contract: <Name>' -ForEach $script:HDTImplementation {

    # The imports live in the DESCRIBE's BeforeAll, not in each Context's. A
    # Factory scriptblock was created in the discovery-time script scope, and a
    # module imported inside a Context is not visible to it - the fake comes back
    # CommandNotFound. FeatureService.Contract has the same shape for the same
    # reason.
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'the shape' {

        BeforeAll {
            $script:service = & $Factory
        }

        It 'exposes SetServer, SearchUpdate, AcceptEula, DownloadUpdate, InstallUpdate and GetRebootRequired' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            $method = @($script:service | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('SetServer', 'SearchUpdate', 'AcceptEula', 'DownloadUpdate', 'InstallUpdate', 'GetRebootRequired')) {
                $method | Should -Contain $name -Because "IUpdateSessionService requires $name"
            }
        }

        It 'exposes the operation journal every service carries' {
            $member = @($script:service | Get-Member | ForEach-Object { $_.Name })

            $member | Should -Contain 'Operations'
            $member | Should -Contain 'GetOperationName'
        }

        It 'names itself for the cross-service journal' {
            $script:service.ServiceName | Should -BeExactly 'UpdateSessionService'
        }
    }

    # THE ONE THING THE REAL ROW IS ALLOWED TO ASK A MACHINE. Reading
    # ISystemInformation.RebootRequired starts no search, downloads nothing and
    # installs nothing; it is the single WUA call this plan may make for real,
    # and it proves the adapter reaches the agent rather than only that it parses.
    # Skipped where the agent is not registered - which is every WinPE.
    Context 'the machine, through the real agent' -Skip:((-not $IsReal) -or (-not $script:HDTWuaPresent)) {

        It 'answers GetRebootRequired from the machine without searching for anything' {
            $service = & $Factory

            $service.GetRebootRequired() | Should -BeOfType ([bool])
            $service.GetOperationName() | Should -Be @('GetRebootRequired')
        }
    }

    Context 'the behaviour' -Skip:$IsReal {

        BeforeEach {
            $script:wua = & $Factory
        }

        It 'returns every update the search matched, unfiltered' {
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            $update.Count | Should -Be 2
        }

        It 'returns a title, an update id and the KB numbers for each' {
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            foreach ($row in $update) {
                $row.UpdateId | Should -Not -BeNullOrEmpty
                $row.Title | Should -Not -BeNullOrEmpty
                @($row.KBArticleId).Count | Should -BeGreaterThan 0
            }

            # WITHOUT THE KB PREFIX, the way the agent reports them. The step
            # normalises; the adapter projects.
            @($update | Where-Object { $_.UpdateId -eq '11111111-1111-1111-1111-111111111111' })[0].KBArticleId |
                Should -Be @('5031354')
        }

        It 'returns the categories each update belongs to' {
            # DESIGN 10.1's categories: filter is decided against these, in the
            # step, which is why the adapter has to hand every one of them over.
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '22222222-2222-2222-2222-222222222222' })[0].Category |
                Should -Be @('Critical Updates', 'Windows 11')
        }

        It 'returns whether an update is already downloaded' {
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '11111111-1111-1111-1111-111111111111' })[0].IsDownloaded |
                Should -BeFalse
            @($update | Where-Object { $_.UpdateId -eq '22222222-2222-2222-2222-222222222222' })[0].IsDownloaded |
                Should -BeTrue
        }

        It 'returns whether its EULA has been accepted' {
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '11111111-1111-1111-1111-111111111111' })[0].EulaAccepted |
                Should -BeTrue
            @($update | Where-Object { $_.UpdateId -eq '22222222-2222-2222-2222-222222222222' })[0].EulaAccepted |
                Should -BeFalse
        }

        It 'returns the download size of each update' {
            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '22222222-2222-2222-2222-222222222222' })[0].SizeByte |
                Should -Be 613416960
        }

        It 'records SearchUpdate with the criteria it was given' {
            $null = $script:wua.SearchUpdate('IsInstalled = 0 and Type = ''Software''')

            $script:wua.GetOperationName() | Should -Be @('SearchUpdate')
            @($script:wua.Operations)[0].Arguments[0] | Should -BeExactly 'IsInstalled = 0 and Type = ''Software'''
        }

        It 'records SetServer with the URL it was given' {
            $script:wua.SetServer('http://wsus.contoso.local:8530')

            $script:wua.GetOperationName() | Should -Be @('SetServer')
            @($script:wua.Operations)[0].Arguments[0] | Should -BeExactly 'http://wsus.contoso.local:8530'
        }

        It 'records AcceptEula with the update it was given' {
            $script:wua.AcceptEula('22222222-2222-2222-2222-222222222222')

            $script:wua.GetOperationName() | Should -Be @('AcceptEula')
            @($script:wua.Operations)[0].Arguments[0] | Should -BeExactly '22222222-2222-2222-2222-222222222222'
        }

        It 'records DownloadUpdate with the update ids it was given' {
            $null = $script:wua.DownloadUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $script:wua.GetOperationName() | Should -Be @('DownloadUpdate')
            @($script:wua.Operations)[0].Arguments[0] | Should -Be @('11111111-1111-1111-1111-111111111111')
        }

        It 'records InstallUpdate with the update ids it was given' {
            $null = $script:wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'))

            $script:wua.GetOperationName() | Should -Be @('InstallUpdate')
            @($script:wua.Operations)[0].Arguments[0] | Should -Be @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
        }

        It 'reports Success, ResultCode, HResult and RebootRequired from InstallUpdate' {
            $result = $script:wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $result.Success | Should -BeOfType ([bool])
            $result.ResultCode | Should -BeOfType ([int])
            $result.HResult | Should -BeOfType ([int])
            $result.RebootRequired | Should -BeOfType ([bool])

            # orcSucceeded. 0 NotStarted, 1 InProgress, 2 Succeeded,
            # 3 SucceededWithErrors, 4 Failed, 5 Aborted.
            $result.Success | Should -BeTrue
            $result.ResultCode | Should -Be 2
        }

        It 'reports Success, ResultCode, HResult and RebootRequired from DownloadUpdate' {
            $result = $script:wua.DownloadUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $result.Success | Should -BeTrue
            $result.ResultCode | Should -Be 2
            $result.HResult | Should -Be 0
            $result.RebootRequired | Should -BeFalse
        }

        It 'reports a per-update result code from InstallUpdate' {
            $result = $script:wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'))

            @($result.PerUpdate).Count | Should -Be 2
            @($result.PerUpdate)[0].UpdateId | Should -BeExactly '11111111-1111-1111-1111-111111111111'
            @($result.PerUpdate)[0].ResultCode | Should -Be 2
            @($result.PerUpdate)[0].HResult | Should -Be 0
        }

        It 'reports RebootRequired true when an update asked for a restart' {
            $wua = New-HDTFakeUpdateSessionService -InstallResult @{
                '22222222-2222-2222-2222-222222222222' = @{ ResultCode = 2; HResult = 0; RebootRequired = $true }
            }

            $result = $wua.InstallUpdate([string[]] @('22222222-2222-2222-2222-222222222222'))

            $result.RebootRequired | Should -BeTrue
            @($result.PerUpdate)[0].ResultCode | Should -Be 2
        }

        It 'reports GetRebootRequired from the machine, not from the last install' {
            # Two different questions. The install result says "this batch asked
            # for a restart"; the machine says "there is a restart pending from
            # anything at all, including the servicing stack update that went in
            # first". The step needs both.
            $wua = New-HDTFakeUpdateSessionService -RebootRequired $true

            $result = $wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $result.RebootRequired | Should -BeFalse
            $wua.GetRebootRequired() | Should -BeTrue
        }

        It 'returns nothing from a search that matched nothing' {
            $wua = New-HDTFakeUpdateSessionService -Update @()

            @($wua.SearchUpdate('IsInstalled = 0')).Count | Should -Be 0
        }

        It 'stops returning an update once it has been installed' {
            # THE FAKE HAS TO BEHAVE THE WAY THE AGENT DOES OR THE FAKE IS WRONG,
            # not the caller. The real criteria is IsInstalled = 0, so an update
            # that went in does not come back. A fake that kept returning it would
            # turn DESIGN 10.1's multi-pass termination test into a test of
            # maxPasses and hide an infinite loop.
            $null = $script:wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            $update.Count | Should -Be 1
            $update[0].UpdateId | Should -BeExactly '22222222-2222-2222-2222-222222222222'
        }

        It 'reveals a new update on the next pass when the test seeded one' {
            # DESIGN 10.1's whole reason for looping: installing one update can
            # supersede or reveal another. A single fixed result cannot say that.
            $wua = New-HDTFakeUpdateSessionService -UpdatePerPass @(
                , @(@{ UpdateId = 'AAAA'; Title = 'Servicing stack update' })
                , @(@{ UpdateId = 'BBBB'; Title = 'The one the SSU revealed' })
                , @()
            )

            @($wua.SearchUpdate('IsInstalled = 0'))[0].UpdateId | Should -BeExactly 'AAAA'
            @($wua.SearchUpdate('IsInstalled = 0'))[0].UpdateId | Should -BeExactly 'BBBB'
            @($wua.SearchUpdate('IsInstalled = 0')).Count | Should -Be 0
            @($wua.SearchUpdate('IsInstalled = 0')).Count | Should -Be 0
        }

        It 'fails an install the way the agent does, with an HResult and Success false' {
            $wua = New-HDTFakeUpdateSessionService -InstallResult @{
                '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 4; HResult = -2145124329 }
            }

            $result = $wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $result.Success | Should -BeFalse
            $result.ResultCode | Should -Be 4
            $result.HResult | Should -Be -2145124329
            @($result.PerUpdate)[0].HResult | Should -Be -2145124329
        }

        It 'keeps a failed install in the next search' {
            $wua = New-HDTFakeUpdateSessionService -InstallResult @{
                '11111111-1111-1111-1111-111111111111' = @{ ResultCode = 4; HResult = -2145124329 }
            }

            $null = $wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            @($wua.SearchUpdate('IsInstalled = 0')).Count | Should -Be 2
        }

        It 'throws from the search the way the agent does when it cannot reach a server' {
            $wua = New-HDTFakeUpdateSessionService -FailSearch

            { $wua.SearchUpdate('IsInstalled = 0') } | Should -Throw -ExpectedMessage '*search*'
        }

        It 'throws from the install when the agent itself failed' {
            $wua = New-HDTFakeUpdateSessionService -FailInstall

            { $wua.InstallUpdate([string[]] @('11111111-1111-1111-1111-111111111111')) } | Should -Throw
        }

        It 'marks an update downloaded once DownloadUpdate has run' {
            $null = $script:wua.DownloadUpdate([string[]] @('11111111-1111-1111-1111-111111111111'))

            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '11111111-1111-1111-1111-111111111111' })[0].IsDownloaded |
                Should -BeTrue
        }

        It 'marks a EULA accepted once AcceptEula has run' {
            $script:wua.AcceptEula('22222222-2222-2222-2222-222222222222')

            $update = @($script:wua.SearchUpdate('IsInstalled = 0'))

            @($update | Where-Object { $_.UpdateId -eq '22222222-2222-2222-2222-222222222222' })[0].EulaAccepted |
                Should -BeTrue
        }

        It 'records the operations in the order they were called' {
            $script:wua.SetServer('http://wsus.contoso.local:8530')
            $null = $script:wua.SearchUpdate('IsInstalled = 0')
            $script:wua.AcceptEula('22222222-2222-2222-2222-222222222222')
            $null = $script:wua.DownloadUpdate([string[]] @('22222222-2222-2222-2222-222222222222'))
            $null = $script:wua.InstallUpdate([string[]] @('22222222-2222-2222-2222-222222222222'))
            $null = $script:wua.GetRebootRequired()

            $script:wua.GetOperationName() | Should -Be @(
                'SetServer', 'SearchUpdate', 'AcceptEula', 'DownloadUpdate', 'InstallUpdate', 'GetRebootRequired')
        }

        It 'appends to the shared cross-service journal when it was given one' {
            $journal = [System.Collections.ArrayList]::new()
            $wua = New-HDTFakeUpdateSessionService -Journal $journal

            $wua.SetServer('http://wsus.contoso.local:8530')

            @($journal).Count | Should -Be 1
            @($journal)[0].Service | Should -BeExactly 'UpdateSessionService'
            @($journal)[0].Operation | Should -BeExactly 'SetServer'
        }
    }
}

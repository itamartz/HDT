function New-HDTUpdateSessionService {
    <#
        .SYNOPSIS
            The real IUpdateSessionService: a thin adapter over the Windows Update
            Agent COM API.

        .DESCRIPTION
            DESIGN 10.1's Microsoft.Update.Session wrapper. Rule 5 forbids engine
            logic from creating a COM object, so the WindowsUpdate step receives
            this and can be handed New-HDTFakeUpdateSessionService in a test - the
            whole reason a step that installs operating system updates can be
            proved end to end with nothing installed.

            IT IS BRANCH-FREE, WHICH IS WHY IT IS NOT UNIT TESTED (rule 1's
            adapter exception). Every decision - which of the updates found match
            the step's categories, which its exclude patterns rule out, whether to
            run another pass, whether to restart - is made by the step against the
            flat listing this returns. The adapter's whole job is to call the
            agent and project its answer.

            WUA DOES NOT EXIST IN WINPE. DESIGN 10.1: "WUA is unavailable in
            WinPE; this step is full-OS only." Nothing here imports or probes
            anything at construction time, so building the service is safe
            anywhere; the first call is what fails, with the agent's own error.

            SEARCHUPDATE IS FLAT AND UNFILTERED, for the reason
            IFeatureService.GetFeature() is: it hands over every update the
            criteria matched with its categories and its KB numbers, and filters
            nothing.

            SETSERVER IS HERE AND NOT IN THE STEP even though pointing a client at
            WSUS is four registry values and a service restart, because none of
            that is a decision - it is the IO that makes a ServerSelection of
            ssManagedServer mean anything. The step decides WHETHER to call it;
            this does it. That is what keeps the adapter branch-free: it is only
            ever called with a URL, so it never has to ask whether it has one.

            Derived from PSD's Scripts/PSDWindowsUpdate.ps1 (MIT; see NOTICE.md)
            for the mechanism only - the registry values, the COM call order and
            the one-update-at-a-time collection shape. PSD is a procedural script
            that decides as it goes; this is a projection with the deciding taken
            out of it.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every call
            is appended to it as well as to $Operations.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying SetServer,
            SearchUpdate, AcceptEula, DownloadUpdate, InstallUpdate and
            GetRebootRequired, plus Operations, GetOperationName and ServiceName.

        .EXAMPLE
            $wua = New-HDTUpdateSessionService
            $wua.GetRebootRequired()

            Whether the machine has a restart pending - from the agent's own
            ISystemInformation, so it counts a servicing stack update that went in
            before HDT ever ran. It searches nothing and installs nothing.

        .EXAMPLE
            $catalog = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock (New-HDTClock) -UpdateSession (New-HDTUpdateSessionService)
            $catalog.GetRequired('UpdateSession', 'WindowsUpdate')

            How the WindowsUpdate step is given one. A test builds the same
            catalog with New-HDTFakeUpdateSessionService instead.

        .EXAMPLE
            @($wua.GetOperationName())

            What was asked of it, which is what the step's tests assert on rather
            than installing an update.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds the service object; searching, downloading and installing are done by the caller through it, and the step that calls it declares SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'UpdateSessionService'

        # THE COM UPDATE OBJECTS THE LAST SEARCH RETURNED, by update id. The
        # interface takes ids because a step may not hold a COM object (rule 5),
        # and AcceptEula, DownloadUpdate and InstallUpdate all need the object
        # behind the id. Ordinal case-insensitive: an update id is a GUID string
        # and the agent's casing is not something to depend on.
        Update      = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # The four registry values and the service restart that make a client ask a
    # WSUS server rather than Microsoft Update. NoAutoUpdate = 1 IS DELIBERATE:
    # during a deployment the sequence drives the patching, and the automatic
    # agent starting its own download in parallel is how a build ends up with two
    # installers fighting over the same servicing stack.
    #
    # PSD writes the same six values and then restarts wuauserv so the agent
    # reads them; the restart is not optional, and neither is WUStatusServer -
    # an agent that reports to Microsoft Update while downloading from WSUS is
    # the classic half-configured client.
    $service | Add-Member -MemberType ScriptMethod -Name SetServer -Value {
        param([string] $Url)

        $this.Record('SetServer', @($Url))

        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $automatic = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

        [void] (New-Item -Path $policy -Force)
        [void] (New-ItemProperty -Path $policy -Name 'WUServer' -Value $Url -PropertyType String -Force)
        [void] (New-ItemProperty -Path $policy -Name 'WUStatusServer' -Value $Url -PropertyType String -Force)

        [void] (New-Item -Path $automatic -Force)
        [void] (New-ItemProperty -Path $automatic -Name 'UseWUServer' -Value 1 -PropertyType DWord -Force)
        [void] (New-ItemProperty -Path $automatic -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force)

        Restart-Service -Name 'wuauserv' -Force
    }

    $service | Add-Member -MemberType ScriptMethod -Name SearchUpdate -Value {
        param([string] $Criteria)

        $this.Record('SearchUpdate', @($Criteria))

        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()

        # 1 IS ssManagedServer, and it is what makes the registry values SetServer
        # wrote take effect for THIS search rather than for the next scheduled
        # scan. PSD assigns $serverSelection here and never sets it anywhere in
        # its tree - the WSUS support arrived in its version 0.0.2 and the
        # searcher was left reading an undefined variable.
        $searcher.ServerSelection = 1

        # The step passes 'IsInstalled = 0'. It is not written here because which
        # updates to ask for is the step's decision, not the adapter's.
        $result = $searcher.Search($Criteria)

        $this.Update.Clear()

        $row = @(foreach ($found in $result.Updates) {
                $this.Update[[string] $found.Identity.UpdateID] = $found

                [pscustomobject] @{
                    UpdateId     = [string] $found.Identity.UpdateID
                    Title        = [string] $found.Title

                    # KBArticleIDs is a COM string collection, and the numbers come
                    # back WITHOUT the KB prefix. They are kept as the agent gives
                    # them and the step normalises, so this stays a projection.
                    KBArticleId  = [string[]] @(@($found.KBArticleIDs) | ForEach-Object { [string] $_ })

                    # Each category is an ICategory, not a string.
                    Category     = [string[]] @(@($found.Categories) | ForEach-Object { [string] $_.Name })

                    IsDownloaded = [bool] $found.IsDownloaded
                    EulaAccepted = [bool] $found.EulaAccepted
                    SizeByte     = [long] $found.MaxDownloadSize
                }
            })

        # The unary comma is mandatory: a ScriptMethod collapses a single-element
        # array to a scalar without it, and a search that matched one update is
        # the ordinary case on a machine that is nearly current.
        return , ([object[]] $row)
    }

    $service | Add-Member -MemberType ScriptMethod -Name AcceptEula -Value {
        param([string] $UpdateId)

        $this.Record('AcceptEula', @($UpdateId))

        $this.Update[[string] $UpdateId].AcceptEula()
    }

    # A SESSION PER CALL, deliberately. The state that matters - what has been
    # downloaded, what is installed, what the EULA says - belongs to the machine
    # and to the IUpdate objects the search returned, not to the session object,
    # so a fresh one costs nothing and there is no session to have gone stale
    # across the reboot that DESIGN 10.1's loop takes in the middle.
    $service | Add-Member -MemberType ScriptMethod -Name DownloadUpdate -Value {
        param([string[]] $UpdateId)

        $this.Record('DownloadUpdate', @(, [string[]] $UpdateId))

        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'

        foreach ($id in @($UpdateId)) {
            [void] $collection.Add($this.Update[[string] $id])
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $collection
        $result = $downloader.Download()

        # GetUpdateResult is positional, and the position is the one the
        # collection was built in - which is the order of $UpdateId.
        $index = 0
        $perUpdate = @(foreach ($id in @($UpdateId)) {
                $one = $result.GetUpdateResult($index)
                $index = $index + 1

                [pscustomobject] @{
                    UpdateId   = [string] $id
                    ResultCode = [int] $one.ResultCode
                    HResult    = [int] $one.HResult
                }
            })

        return [pscustomobject] @{
            # ResultCode 2 is orcSucceeded: 0 NotStarted, 1 InProgress,
            # 2 Succeeded, 3 SucceededWithErrors, 4 Failed, 5 Aborted. Comparing
            # against a documented enum is a projection, not a decision.
            Success        = ([int] $result.ResultCode -eq 2)
            ResultCode     = [int] $result.ResultCode
            HResult        = [int] $result.HResult

            # IDownloadResult carries no RebootRequired and nothing is installed
            # yet, so the answer is always no. The property is here because the
            # step reads one result shape from both calls.
            RebootRequired = $false

            PerUpdate      = [object[]] @($perUpdate)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name InstallUpdate -Value {
        param([string[]] $UpdateId)

        $this.Record('InstallUpdate', @(, [string[]] $UpdateId))

        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'

        foreach ($id in @($UpdateId)) {
            [void] $collection.Add($this.Update[[string] $id])
        }

        # The collection takes as many as it is given; the step calls this ONE
        # UPDATE AT A TIME so it can time and log each, which is where a
        # deployment that took two hours gets explained afterwards. The signature
        # takes an array anyway, so a future caller can batch without changing it.
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $collection
        $result = $installer.Install()

        $index = 0
        $perUpdate = @(foreach ($id in @($UpdateId)) {
                $one = $result.GetUpdateResult($index)
                $index = $index + 1

                [pscustomobject] @{
                    UpdateId   = [string] $id
                    ResultCode = [int] $one.ResultCode
                    HResult    = [int] $one.HResult
                }
            })

        return [pscustomobject] @{
            Success        = ([int] $result.ResultCode -eq 2)
            ResultCode     = [int] $result.ResultCode
            HResult        = [int] $result.HResult

            # THIS BATCH asked for a restart. It is not the same question as
            # GetRebootRequired below, and the step needs both.
            RebootRequired = [bool] $result.RebootRequired

            PerUpdate      = [object[]] @($perUpdate)
        }
    }

    # THE MACHINE'S ANSWER, from ISystemInformation.RebootRequired: is there a
    # restart pending from anything at all, including the servicing stack update
    # that went in first or something that ran before the deployment did. An
    # install result only ever speaks for its own batch.
    $service | Add-Member -MemberType ScriptMethod -Name GetRebootRequired -Value {
        $this.Record('GetRebootRequired', @())

        $systemInfo = New-Object -ComObject 'Microsoft.Update.SystemInfo'

        return [bool] $systemInfo.RebootRequired
    }

    return $service
}

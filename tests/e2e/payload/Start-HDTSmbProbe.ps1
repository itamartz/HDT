<#
    .SYNOPSIS
        Answers, from inside WinPE, whether HDT can deploy over SMB.

    .DESCRIPTION
        THE GAP THIS EXISTS TO CLOSE. Every deployment this repository has ever
        run used the Local provider against a content disk. The Smb provider's
        evidence is unit refusals, an operation-list equality test and a loopback
        integration run - none of which is a machine in WinPE reaching a share
        over a network. SPIKES S6 recorded that a VM on the isolated 'HDT Lab'
        switch cannot reach a share on the host, which is why it stayed unproven;
        PROJECT.md now permits the 'HDT External' switch, where the VM gets DHCP
        from the real LAN and the host is reachable on 192.168.2.0/24. The
        host's octet is a lease and moves, so this probe is handed a share path
        rather than assuming one.

        WHY A PROBE BEFORE A DEPLOYMENT. A deployment that cannot reach the share
        fails in the first thirty seconds and shuts the machine down, and from
        outside that is indistinguishable from a dozen other failures - the RAM
        disk it would have written its answer to disappears with the machine.
        This walks THE SAME PRODUCT PATH the payload walks - the same bootstrap,
        the same Get-HDTBootstrapConfiguration, the same GetCredential(), the
        same New-HDTContentProvider and Connect() - and writes what happened to a
        disk that survives. It never partitions anything and never applies an
        image: the question here is only whether the share can be reached and
        authenticated to.

        EACH STAGE IS RECORDED SEPARATELY because each fails for its own reason
        and the fixes are different: no DHCP lease is a switch problem, a closed
        445 is a firewall problem, a guest identity is an account problem, and a
        connect that succeeds while the read fails is a share ACL problem.

        THE GUEST-FALLBACK REFUSAL IS A PASS, NOT A FAILURE. DESIGN 6.3 says HDT
        will not deploy from a share it did not authenticate to, and the provider
        throws HDTSecurityError when Windows silently falls back to guest. If
        that happens here the probe records it as the finding rather than
        treating the run as broken.

    .PARAMETER BootstrapPath
        The bootstrap document the boot image carries. X:\HDT\bootstrap.json on a
        real image; a test points it elsewhere.

    .PARAMETER ContentRoot
        The disk to write the answer to. Found by scanning for the marker folder
        the harness put there when omitted.

    .PARAMETER ModulePath
        The staged engine. X:\HDT\Modules on a real image - the image's own copy,
        which is what a real deployment loads.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTSmbProbe.ps1

        What the boot image's startnet.cmd runs. Nothing types it.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [AllowEmptyString()]
    [string] $ContentRoot = '',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ModulePath = 'X:\HDT\Modules'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$probe = [ordered] @{
    launchedBy        = [string] $env:HDT_LAUNCHED_BY
    psVersion         = [string] $PSVersionTable.PSVersion

    # -- the network -------------------------------------------------------
    ipAddress         = ''
    subnetMask        = ''
    gateway           = ''
    dhcpSecond        = 0
    hasLease          = $false

    # -- the server --------------------------------------------------------
    server            = ''
    shareName         = ''
    pingable          = $false
    port445Open       = $false
    port445Second     = 0

    # -- the product path --------------------------------------------------
    bootstrapRead     = $false
    provider          = ''
    deployRoot        = ''
    userName          = ''
    hasCredential     = $false
    connected         = $false
    guestRefused      = $false
    rulesReadable     = $false
    rulesByteCount    = 0
    resolvedRulesPath = ''

    # -- what went wrong, per stage ---------------------------------------
    networkError      = ''
    bootstrapError    = ''
    connectError      = ''
    readError         = ''
}

$say = {
    param([string] $Message)
    Write-Information ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message)
}

& $say ('SMB probe starting; launched by ''{0}''' -f $probe['launchedBy'])

# -- 1. the DHCP lease --------------------------------------------------------
#
# wpeinit has already run (startnet.cmd), but it returns before DHCP has
# necessarily answered. Waiting for a routable address is the difference between
# "the switch is wrong" and "we asked too early", and those look identical in a
# log that only records the end state.

try {
    $networkWatch = [System.Diagnostics.Stopwatch]::StartNew()

    # WMI, NOT Get-NetIPAddress. The first run of this probe died here: the
    # NetTCPIP module is not in a WinPE image built from the ADK, so
    # Get-NetIPAddress and Get-NetRoute are simply absent and the whole network
    # stage reported nothing. WinPE-WMI is one of the six REQUIRED components
    # Get-HDTBootImageComponent always injects, so Win32_NetworkAdapterConfiguration
    # is present by construction.
    while ($networkWatch.Elapsed.TotalSeconds -lt 90) {
        $configuration = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                Where-Object { $_.IPEnabled })

        $routable = @()
        foreach ($current in $configuration) {
            foreach ($candidate in @($current.IPAddress)) {
                if ($candidate -notlike '*:*' -and $candidate -notlike '127.*' -and $candidate -notlike '169.254.*') {
                    $routable += [pscustomobject] @{ Address = [string] $candidate; Configuration = $current }
                }
            }
        }

        if ($routable.Count -ge 1) {
            $probe['ipAddress'] = [string] $routable[0].Address
            $probe['hasLease'] = $true

            $mask = @($routable[0].Configuration.IPSubnet)
            if ($mask.Count -ge 1) { $probe['subnetMask'] = [string] $mask[0] }

            $router = @($routable[0].Configuration.DefaultIPGateway)
            if ($router.Count -ge 1) { $probe['gateway'] = [string] $router[0] }

            break
        }

        Start-Sleep -Seconds 3
    }

    $networkWatch.Stop()
    $probe['dhcpSecond'] = [int] $networkWatch.Elapsed.TotalSeconds
} catch {
    $probe['networkError'] = [string] $_.Exception.Message
}

& $say ('lease: {0} ({1}s), address {2} mask {3}, gateway {4}' -f
    $probe['hasLease'], $probe['dhcpSecond'], $probe['ipAddress'],
    $probe['subnetMask'], $probe['gateway'])

# -- 2. the bootstrap, and the server it names --------------------------------

$bootstrap = $null
try {
    $env:PSModulePath = '{0};{1}' -f $ModulePath, $env:PSModulePath
    Import-Module -Name 'powershell-yaml' -Force -ErrorAction SilentlyContinue
    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop

    $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem (New-HDTFileSystem)

    $probe['bootstrapRead'] = $true
    $probe['provider'] = [string] $bootstrap.Provider
    $probe['deployRoot'] = [string] $bootstrap.DeployRoot
    $probe['userName'] = [string] $bootstrap.UserName
    $probe['hasCredential'] = [bool] $bootstrap.HasCredential

    # \\server\share -> the two parts, without assuming either.
    $unc = [string] $bootstrap.DeployRoot
    if ($unc.StartsWith('\\')) {
        $part = @($unc.TrimStart('\').Split('\') | Where-Object { $_ })
        if ($part.Count -ge 1) { $probe['server'] = [string] $part[0] }
        if ($part.Count -ge 2) { $probe['shareName'] = [string] $part[1] }
    }
} catch {
    $probe['bootstrapError'] = [string] $_.Exception.Message
}

& $say ('bootstrap: provider {0}, deployRoot ''{1}'', account ''{2}''' -f
    $probe['provider'], $probe['deployRoot'], $probe['userName'])

# -- 3. is the server there, and is 445 open ----------------------------------
#
# A raw TcpClient rather than Test-NetConnection: DESIGN 5.1 records that the
# NetTCPIP module is not reliably present in WinPE, and a probe that fails
# because its own diagnostic is missing has answered nothing.

if (-not [string]::IsNullOrWhiteSpace($probe['server'])) {
    try {
        $probe['pingable'] = [bool] (Test-Connection -ComputerName $probe['server'] -Count 2 -Quiet -ErrorAction SilentlyContinue)
    } catch {
        $probe['pingable'] = $false
    }

    $portWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object -TypeName System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($probe['server'], 445, $null, $null)

        if ($async.AsyncWaitHandle.WaitOne(10000, $false) -and $client.Connected) {
            $probe['port445Open'] = $true
            $client.EndConnect($async)
        }

        $client.Close()
    } catch {
        $probe['networkError'] = ('{0} {1}' -f $probe['networkError'], [string] $_.Exception.Message).Trim()
    }
    $portWatch.Stop()
    $probe['port445Second'] = [int] $portWatch.Elapsed.TotalSeconds
}

& $say ('server {0}: ping {1}, port 445 {2}' -f $probe['server'], $probe['pingable'], $probe['port445Open'])

# -- 4. THE PRODUCT PATH: connect the way the payload connects ----------------

if ($probe['bootstrapRead'] -and $probe['provider'] -eq 'Smb') {
    $content = $null
    try {
        $credential = $bootstrap.GetCredential()

        $content = New-HDTContentProvider -Provider 'Smb' -Root ([string] $bootstrap.DeployRoot) `
            -Credential $credential -FileSystem (New-HDTFileSystem)

        [void] $content.Connect()
        $probe['connected'] = $true

        & $say 'connected'

        # -- 5. can it actually READ what it connected to ------------------
        #
        # A mapping that authenticated but cannot read is a share ACL problem,
        # and it is worth separating: DESIGN 6.3 wants the deployment account
        # read-only everywhere except Logs and Captures, and an ACL that
        # over-corrected would land exactly here.
        try {
            # THE INTERFACE, NOT A GUESS: DESIGN 6.2's IContentProvider is
            # ResolveContent / TestContent / CopyContent / Connect / Disconnect,
            # and tests/contract/ContentProvider.Contract.Tests.ps1 is what says
            # so. There is no directory-listing method on it, so the listing
            # below goes through the resolved path rather than the provider.
            $probe['rulesReadable'] = [bool] $content.TestContent('rules.yaml')

            $resolved = [string] $content.ResolveContent('rules.yaml')
            $probe['resolvedRulesPath'] = $resolved

            if ($probe['rulesReadable']) {
                # READ IT, not merely stat it. A share can answer TestPath from a
                # cached handle and still fail the first real read, and it is the
                # read the deployment depends on.
                $text = [System.IO.File]::ReadAllText($resolved)
                $probe['rulesByteCount'] = [int] $text.Length
            }
        } catch {
            $probe['readError'] = [string] $_.Exception.Message
        }
    } catch {
        $probe['connectError'] = [string] $_.Exception.Message

        # THE REFUSAL IS A FINDING, NOT A CRASH. DESIGN 6.3: HDT will not deploy
        # from a share it did not authenticate to.
        if ($probe['connectError'] -match 'HDTSecurityError' -or $probe['connectError'] -match 'guest') {
            $probe['guestRefused'] = $true
        }
    } finally {
        if ($null -ne $content) {
            try { [void] $content.Disconnect() } catch { $null = $_ }
        }
    }
}

& $say ('connected {0}, rules.yaml readable {1}, bytes {2}' -f
    $probe['connected'], $probe['rulesReadable'], $probe['rulesByteCount'])

# -- 6. write the answer somewhere that survives the machine ------------------

if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    foreach ($letter in @('C', 'D', 'E', 'F', 'G', 'H')) {
        if (Test-Path -LiteralPath ('{0}:\HDTPROBE' -f $letter)) {
            $ContentRoot = '{0}:\' -f $letter
            break
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    try {
        $json = ConvertTo-Json -InputObject $probe -Depth 4
        [System.IO.File]::WriteAllText((Join-Path -Path $ContentRoot -ChildPath 'SMBPROBE.json'), $json)
        & $say ('wrote SMBPROBE.json to {0}' -f $ContentRoot)
    } catch {
        & $say ('FAILED to write SMBPROBE.json: {0}' -f [string] $_.Exception.Message)
    }
} else {
    & $say 'FATAL: no disk carrying \HDTPROBE was found; the answer has nowhere to go.'
}

# -- 7. end the machine, so the harness knows by the VM going Off -------------

Start-Sleep -Seconds 3
& "$env:SystemRoot\System32\wpeutil.exe" shutdown
exit 0

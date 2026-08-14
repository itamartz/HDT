<#
    .SYNOPSIS
        W2's evidence: does the Welcome screen come up in WinPE, through the
        product path, with the machine's real lease in it?

    .DESCRIPTION
        .planning/WPF-FIRST.md, increment W2. W1 answered "does WPF render in
        this image at all" and answered it by loading the XAML itself. That was
        the right question then and it is the wrong one now: the whole product
        path exists, and the bug that mattered - a handler closing over a
        variable that was not in scope - lived in exactly the part W1 stepped
        around.

        SO THIS GOES THROUGH THE PRODUCT, END TO END:

            Get-HDTNetworkConfiguration   the lease, through WMI (SPIKES S14)
            Get-HDTWizardField            what belongs in every box
            Show-HDTWizard                the refusal logic and the allow-list
            New-HDTWizardHost             XamlReader, the handlers, ShowDialog

        Nothing here loads XAML, decides what a button means, or reads an
        adapter. If any of that is wrong, this probe is what says so.

        IT CLOSES THE WINDOW WITH WM_CLOSE, and that is the one thing it does
        that a technician would not. ShowDialog blocks until a human clicks and
        nobody is going to click in an unattended lab run, so a DispatcherTimer
        - ticking on the dispatcher ShowDialog is already pumping - posts
        WM_CLOSE after the dwell the screenshot needs.

        THAT CHOICE IS ALSO AN ASSERTION. WM_CLOSE is the X, which runs no
        handler at all, so the answer that comes back must be Cancel and never
        Next. If this probe ever reports 'Next', a dismissed deployment wizard
        is being read as consent to partition a disk on a real machine.

        THE CONSOLE IS HIDDEN, AND RESTORED IN A finally. WinPE boots into
        cmd.exe running startnet.cmd, and that black X:\Windows\System32> window
        sits behind everything. Hiding it is what makes the screenshot look like
        a deployment tool instead of a script. Restoring it is not optional: a
        hidden console plus a payload that then throws leaves a technician
        staring at a blank screen with nothing to read and nothing to type into.

    .PARAMETER XamlPath
        The window. X:\HDT\UI\HDTWelcome.xaml, staged by Update-HDTBootImage.

    .PARAMETER BootstrapPath
        bootstrap.json, for the share and account prefill. Absent is not an
        error - those boxes are simply left empty.

    .PARAMETER DwellSecond
        How long to leave the window on screen for the screenshot.

    .PARAMETER ContentRoot
        Where to write the answer. Found by scanning for \HDTPROBE.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $XamlPath = 'X:\HDT\UI\HDTWelcome.xaml',

    [Parameter()]
    [AllowEmptyString()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [ValidateRange(1, 600)]
    [int] $DwellSecond = 45,

    [Parameter()]
    [AllowEmptyString()]
    [string] $ContentRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$probe = [ordered] @{
    launchedBy         = [string] $env:HDT_LAUNCHED_BY
    psVersion          = [string] $PSVersionTable.PSVersion

    moduleImported     = $false
    modulePath         = ''
    xamlPresent        = $false
    xamlByteCount      = 0

    consoleHidden      = $false
    consoleRestored    = $false

    networkRead        = $false
    hasLease           = $false
    ipAddress          = ''
    subnetMask         = ''
    gateway            = ''
    dnsServer          = ''
    adapterDescription = ''

    bootstrapRead      = $false
    deployRoot         = ''

    fieldCount         = 0
    fieldName          = @()

    shown              = $false
    action             = ''
    dwellSecond        = 0

    moduleError        = ''
    networkError       = ''
    bootstrapError     = ''
    showError          = ''
}

$say = {
    param([string] $Message)
    Write-Information ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message)
}

& $say ('W2 wizard probe; launched by ''{0}''' -f $probe['launchedBy'])

$title = 'Hephaestus Deployment Toolkit'

# -- 0. the engine, off the content disk -------------------------------------

try {
    # X: FIRST, BECAUSE THAT IS WHERE Update-HDTBootImage PUT IT. The engine and
    # powershell-yaml are staged into the image at X:\HDT\Modules, and X: is the
    # RAM disk whose letter is fixed - so there is nothing to scan for. The disk
    # scan below is the fallback for an image built without them.
    foreach ($candidate in @('X:\HDT\Modules') + @('C', 'D', 'E', 'F', 'G', 'H' |
                ForEach-Object { '{0}:\HDT\Modules' -f $_ })) {

        if (Test-Path -LiteralPath $candidate) {
            $env:PSModulePath = '{0};{1}' -f $candidate, $env:PSModulePath
            $probe['modulePath'] = $candidate
            break
        }
    }

    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop
    $probe['moduleImported'] = $true
} catch {
    $probe['moduleError'] = [string] $_.Exception.Message
    & $say ('MODULE FAILED: {0}' -f $probe['moduleError'])
}

$probe['xamlPresent'] = Test-Path -LiteralPath $XamlPath -PathType Leaf
if ($probe['xamlPresent']) {
    $probe['xamlByteCount'] = [int] ([System.IO.File]::ReadAllText($XamlPath)).Length
}

& $say ('module {0}; XAML present {1} ({2} bytes)' -f
    $probe['moduleImported'], $probe['xamlPresent'], $probe['xamlByteCount'])

if ($probe['moduleImported']) {

    # -- 1. the lease, through the product command --------------------------

    $network = $null
    try {
        $network = Get-HDTNetworkConfiguration

        $probe['networkRead'] = $true
        $probe['hasLease'] = [bool] $network.HasLease
        $probe['ipAddress'] = [string] $network.IPAddress
        $probe['subnetMask'] = [string] $network.SubnetMask
        $probe['gateway'] = [string] $network.Gateway
        $probe['dnsServer'] = [string] $network.DnsServerText
        $probe['adapterDescription'] = [string] $network.AdapterDescription

        & $say ('lease: {0} / {1} via {2} ({3})' -f
            $probe['ipAddress'], $probe['subnetMask'], $probe['gateway'], $probe['adapterDescription'])
    } catch {
        $probe['networkError'] = [string] $_.Exception.Message
        & $say ('NETWORK READ FAILED: {0}' -f $probe['networkError'])
    }

    # -- 2. what the image already knows ------------------------------------

    $bootstrap = $null
    if (-not [string]::IsNullOrWhiteSpace($BootstrapPath) -and (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        try {
            $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath

            $probe['bootstrapRead'] = $true
            $probe['deployRoot'] = [string] $bootstrap.DeployRoot
        } catch {
            $probe['bootstrapError'] = [string] $_.Exception.Message
            & $say ('BOOTSTRAP FAILED: {0}' -f $probe['bootstrapError'])
        }
    }

    # -- 3. what belongs in every box ---------------------------------------

    $field = @(Get-HDTWizardField -NetworkConfiguration $network -Bootstrap $bootstrap)

    $probe['fieldCount'] = @($field).Count
    $probe['fieldName'] = @($field | ForEach-Object { [string] $_.Name })

    & $say ('{0} field(s): {1}' -f $probe['fieldCount'], (($probe['fieldName']) -join ', '))

    # -- 4. show it, and close it again -------------------------------------

    if ($probe['xamlPresent']) {

        # PostMessage, because the window belongs to the host and this script
        # never sees it. WM_CLOSE is the X, which is the dismissal
        # Show-HDTWizard is required to read as Cancel.
        if (-not ([System.Management.Automation.PSTypeName]'HDTProbe.Window').Type) {
            Add-Type -Namespace 'HDTProbe' -Name 'Window' -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@
        }

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # THE CONSOLE GOES AWAY HERE AND COMES BACK IN THE finally. See the
        # header: hidden is a presentation choice, not a place to get stuck.
        try {
            $probe['consoleHidden'] = [bool] (Hide-HDTShellWindow)
            & $say ('console hidden: {0}' -f $probe['consoleHidden'])

            # Ticks on the dispatcher ShowDialog is already pumping, so no
            # second thread is involved and nothing has to be marshalled.
            $closer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
            $closer.Interval = [TimeSpan]::FromSeconds($DwellSecond)
            $closer.Add_Tick({
                    $closer.Stop()

                    # THE PROCESS'S OWN WINDOW FIRST. The console is hidden by
                    # now, so the wizard is the only visible top-level window
                    # this process owns and MainWindowHandle is it - no title
                    # matching, nothing to keep in step with the markup.
                    $process = [System.Diagnostics.Process]::GetCurrentProcess()
                    $process.Refresh()
                    $handle = $process.MainWindowHandle

                    # FindWindow is the fallback, and [NullString]::Value is not
                    # a nicety: $null cast to a [string] P/Invoke parameter
                    # marshals as EMPTY, not null, so FindWindow($null, $title)
                    # searches for a window class literally named "" and answers
                    # 0 every time. That is exactly what it did the first time
                    # this ran, and the window stayed up.
                    if ($handle -eq [System.IntPtr]::Zero) {
                        $handle = [HDTProbe.Window]::FindWindow([NullString]::Value, $title)
                    }

                    if ($handle -ne [System.IntPtr]::Zero) {
                        # 0x0010 = WM_CLOSE.
                        [void] [HDTProbe.Window]::PostMessage($handle, 0x0010, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
                    }
                }.GetNewClosure())
            $closer.Start()

            & $say ('showing {0}; dwelling {1}s for the screenshot' -f $XamlPath, $DwellSecond)

            $answer = Show-HDTWizard -XamlPath $XamlPath -Title $title -Field $field

            $probe['shown'] = $true
            $probe['action'] = [string] $answer.Action
            $probe['dwellSecond'] = $DwellSecond

            & $say ('the wizard answered: {0}' -f $probe['action'])
        } catch {
            $probe['showError'] = [string] $_.Exception.Message
            & $say ('SHOW FAILED: {0}' -f $probe['showError'])
        } finally {
            $probe['consoleRestored'] = [bool] (Hide-HDTShellWindow -Restore)
        }
    }
}

# -- 5. write the answer somewhere that survives the machine -----------------

if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    foreach ($letter in @('C', 'D', 'E', 'F', 'G', 'H')) {
        if (Test-Path -LiteralPath ('{0}:\HDTPROBE' -f $letter)) {
            $ContentRoot = '{0}:\' -f $letter
            break
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    [System.IO.File]::WriteAllText(
        (Join-Path -Path $ContentRoot -ChildPath 'WIZARDPROBE.json'),
        (ConvertTo-Json -InputObject $probe -Depth 4))
    & $say ('wrote WIZARDPROBE.json to {0}' -f $ContentRoot)
} else {
    & $say 'FATAL: no disk carrying \HDTPROBE was found.'
}

Start-Sleep -Seconds 3
& "$env:SystemRoot\System32\wpeutil.exe" shutdown
exit 0

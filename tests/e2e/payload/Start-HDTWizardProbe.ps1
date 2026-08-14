<#
    .SYNOPSIS
        W1's evidence: does the wizard window actually render inside WinPE?

    .DESCRIPTION
        .planning/WPF-FIRST.md, increment W1. Its whole job is to fail fast if
        WPF does not render in this WinPE build, BEFORE any wizard logic exists
        to throw away. PSD proves it is possible (Scripts/PSDWizard.xaml, loaded
        the same way), and WinPE-NetFx - one of the six required components - is
        what makes it possible; this answers it for THIS image.

        IT SHOWS THE WINDOW NON-MODALLY, ON PURPOSE. Show-HDTWizard's real host
        calls ShowDialog, which blocks until a human clicks - and nobody is
        going to click in an unattended lab run. So this calls Show() and closes
        the window itself after a fixed dwell, which is long enough for the
        harness to take the screenshot that is W1's actual deliverable.

        THAT IS THE ONE THING IT DOES DIFFERENTLY FROM THE PRODUCT, and it is
        the honest split: what can only be answered on a real machine is
        "does a Window built from this XAML appear on screen in WinPE". Which
        button was clicked, and what a dismissed window means, are decisions -
        and they are already asserted in tests/unit/Show-HDTWizard.Tests.ps1
        against New-HDTFakeWizardHost, on a machine with no display at all.

    .PARAMETER XamlPath
        The window. X:\HDT\UI\HDTWizard.xaml, staged by Update-HDTBootImage.

    .PARAMETER DwellSecond
        How long to leave the window on screen for the screenshot.

    .PARAMETER ContentRoot
        Where to write the answer. Found by scanning for \HDTPROBE.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $XamlPath = 'X:\HDT\UI\HDTWizard.xaml',

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
    launchedBy      = [string] $env:HDT_LAUNCHED_BY
    psVersion       = [string] $PSVersionTable.PSVersion

    xamlPresent     = $false
    xamlByteCount   = 0

    wpfLoaded       = $false
    windowCreated   = $false
    windowType      = ''
    windowTitle     = ''
    nextButtonFound = $false
    cancelButtonFound = $false
    rendered        = $false
    dwellSecond     = 0

    wpfError        = ''
    renderError     = ''
}

$say = {
    param([string] $Message)
    Write-Information ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message)
}

& $say ('W1 wizard probe; launched by ''{0}''' -f $probe['launchedBy'])

# -- 1. is the window even in the image --------------------------------------

$probe['xamlPresent'] = Test-Path -LiteralPath $XamlPath -PathType Leaf
if ($probe['xamlPresent']) {
    $xaml = [System.IO.File]::ReadAllText($XamlPath)
    $probe['xamlByteCount'] = [int] $xaml.Length
}

& $say ('XAML present: {0} ({1} bytes)' -f $probe['xamlPresent'], $probe['xamlByteCount'])

# -- 2. THE QUESTION: does WPF load and render here --------------------------

if ($probe['xamlPresent']) {
    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        $probe['wpfLoaded'] = $true

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $probe['windowCreated'] = ($null -ne $window)
        $probe['windowType'] = [string] $window.GetType().FullName
        $probe['windowTitle'] = [string] $window.Title

        # The two names the markup promises and Show-HDTWizard depends on.
        $probe['nextButtonFound'] = ($null -ne $window.FindName('HDTNextButton'))
        $probe['cancelButtonFound'] = ($null -ne $window.FindName('HDTCancelButton'))

        & $say ('window created: {0} ({1})' -f $probe['windowCreated'], $probe['windowType'])
    } catch {
        $probe['wpfError'] = [string] $_.Exception.Message
        & $say ('WPF FAILED: {0}' -f $probe['wpfError'])
    }
}

if ($probe['windowCreated']) {
    try {
        # NON-MODAL, so this script keeps running and can close it again.
        $window.Show()
        $probe['rendered'] = [bool] $window.IsVisible

        & $say ('window visible: {0}; dwelling {1}s for the screenshot' -f $probe['rendered'], $DwellSecond)

        # Pump the WPF DISPATCHER while it dwells - not WinForms' DoEvents,
        # which needs System.Windows.Forms and is not guaranteed by WinPE-NetFx.
        # Without a pump the window paints once and then stops responding, which
        # photographs badly and is not what a technician would see.
        $pump = [System.Windows.Threading.DispatcherFrame]::new()
        $deadline = (Get-Date).AddSeconds($DwellSecond)

        while ((Get-Date) -lt $deadline) {
            $window.Dispatcher.Invoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [action] {}) | Out-Null

            Start-Sleep -Milliseconds 200
        }

        $pump.Continue = $false

        $probe['dwellSecond'] = $DwellSecond
        $window.Close()
    } catch {
        $probe['renderError'] = [string] $_.Exception.Message
        & $say ('RENDER FAILED: {0}' -f $probe['renderError'])
    }
}

# -- 3. write the answer somewhere that survives the machine -----------------

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

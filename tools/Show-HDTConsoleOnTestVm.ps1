# Renders the admin console on OSDTEST01, which has no desktop: a WinRM session
# is not interactive, so ShowDialog has no window station to draw on.
# RenderTargetBitmap does not need one - it walks the visual tree and rasterises
# it - so the markup, the theme and the real view models are all exercised, and
# what comes back is what the window would look like.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = 'C:\repos\HDT'
$share = 'C:\HDTLab\Share'
$out = 'C:\repos\console-vm.png'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
[System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

Import-Module (Join-Path $repo 'src\Hephaestus\Hephaestus.psd1') -Force

# A share for it to open. This is a first run on a clean machine, which is the
# case worth rendering: the tree has to say something sensible about a workspace
# with nothing in it yet.
if (-not (Test-Path (Join-Path $share 'workspace.yaml'))) {
    $null = New-HDTWorkspace -Path $share -Id 'HDT-VM' -Name 'HDT test VM share'
}

$module = Get-Module -Name Hephaestus

$view = & $module {
    param($Root)

    $workspace = Get-HDTConsoleWorkspace -Path $Root
    [pscustomobject] @{
        Theme = Get-HDTConsoleTheme
        Node  = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($workspace)))
        Root  = $workspace.Root
        Status = $workspace.Status
    }
} $share

Write-Information ("workspace {0} status {1}" -f $view.Root, $view.Status) -InformationAction Continue
Write-Information ("tree rows {0}" -f @($view.Node).Count) -InformationAction Continue

$xaml = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Hephaestus\UI\Console\HDTConsole.xaml'))
$reader = New-Object System.Xml.XmlNodeReader ([xml] $xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$converter = New-Object System.Windows.Media.BrushConverter
foreach ($key in @($view.Theme.Keys)) {
    $window.Resources[$key] = $converter.ConvertFromString([string] $view.Theme[$key])
}

[void] (& $module { param($W) Set-HDTWindowText -Root $W -String (Get-HDTStringTable -Page 'Console') } $window)

$tree = $window.FindName('HDTConsoleTree')
# THE ROOTS ONLY. WPF builds the branches from each row's Children, so handing
# it the flat list draws every node twice - once as a root and once as a child.
# Show-HDTConsole passes roots, and a test asserts that it does.
$root = @($view.Node | Where-Object { [int] $_.Depth -eq 0 })
Write-Information ("root rows {0}" -f @($root).Count) -InformationAction Continue
$tree.ItemsSource = [object[]] $root

$command = $window.FindName('HDTCommandText')
if ($null -ne $command) { $command.Text = "Show-HDTConsole -Path '$share'" }

# Off the desktop entirely: give it a size, lay it out, rasterise it.
$width = 1500
$height = 1000
$window.Width = $width
$window.Height = $height
$content = $window.Content
$content.Measure([System.Windows.Size]::new($width, $height))
$content.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
$content.UpdateLayout()

$bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($content)

$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$stream = [System.IO.File]::Create($out)
$encoder.Save($stream)
$stream.Close()

Write-Information ("SAVED {0} ({1} bytes)" -f $out, (Get-Item $out).Length) -InformationAction Continue

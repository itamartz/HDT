function New-HDTConsoleDriverView {
    <#
        .SYNOPSIS
            Builds the driver properties window and wires it, without showing
            it.

        .DESCRIPTION
            Workbench's driver Properties, with its two tabs collapsed into one.
            One driver: what it is, which devices it claims, and the single
            thing about it that can be changed.

            IT BUILDS AND RETURNS; IT DOES NOT SHOW. ShowDialog is the caller's,
            which is what makes every handler on it reachable from Pester - see
            New-HDTConsoleView.

            SAVE IS THE ONLY WRITE, and it writes one boolean. Everything else
            on the window came out of the .inf and is read: an .inf is the
            vendor's file, and a console that edited one would be a console
            producing a driver no vendor shipped.

            SAVE ANSWERS. It opens grey, lights when the box stops agreeing with
            the share, and goes grey again with a word beside it once the write
            comes back - because a button identical before and after a press is
            one somebody presses twice and then checks the share by hand. What
            it may do and what it says are Get-HDTConsoleDriverSaveState's,
            where a test can reach them.

            DELETE TAKES THE .inf AND THE FILES BESIDE IT, which is why it is
            bottom-left and away from Save - and why it goes through
            Remove-HDTDriverFolder's rules rather than removing a path this
            window built.

            A HANDLER REACHES A PRIVATE HELPER THROUGH $call, as everywhere else
            here: a closure resolves commands in the console's session state,
            where a private function does not exist.

        .PARAMETER ConsoleHost
            The console host. Its Window owns this one; its Answer carries what
            happened back.

        .PARAMETER Xaml
            HDTDriverProperties.xaml, as text.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Driver
            The driver, as Get-HDTDriver answered it.

        .PARAMETER Theme
            The palette, as brushes.

        .PARAMETER Size
            Where and how big to open.

        .PARAMETER FileSystem
            The IFileSystem Save writes through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built, wired, and not shown.

        .EXAMPLE
            New-HDTConsoleDriverView -ConsoleHost $service -Xaml $xaml -Root 'C:\HDTLab\Share' -Driver $one

        .LINK
            Get-HDTDriver

        .LINK
            Set-HDTDriverState
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a window object and shows nothing; ShowDialog is the caller''s.')]
    [CmdletBinding()]
    [OutputType([System.Windows.Window])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ConsoleHost,

        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Xaml,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [object] $Driver,
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Size = $null,
        [Parameter()] [AllowNull()] [object] $FileSystem = $null
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $call = Get-HDTHandlerCall

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    $writer = $FileSystem

    $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $window.Icon = Get-HDTConsoleWindowIcon

    if ($null -ne $Size) {
        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height
        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top
    }

    $window.Owner = $ConsoleHost.Window

    if ($null -ne $Theme) {
        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }
    }

    $ConsoleHost.Answer = ''
    $driverHost = $ConsoleHost

    [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'DriverProperties'))

    # -- what it says ---------------------------------------------------------

    $window.FindName('HDTDriverTitleText').Text = [string] $Driver.Name
    $window.FindName('HDTDriverPathText').Text = ('Drivers\{0}' -f [string] $Driver.Path)
    $window.FindName('HDTDriverClassText').Text = [string] $Driver.Class
    $window.FindName('HDTDriverVendorText').Text = [string] $Driver.Provider
    $window.FindName('HDTDriverVersionText').Text = [string] $Driver.Version
    $window.FindName('HDTDriverDateText').Text = [string] $Driver.Date

    # THE TITLE IS THE FILE, as Workbench titles it. Several drivers in one
    # folder describe themselves with the same friendly name - "Intel(R)
    # Ethernet Connection" three times - and the .inf is what tells them apart
    # on a task bar holding two of these windows.
    $window.Title = '{0} Properties' -f [string] $Driver.InfName

    $window.FindName('HDTDriverArchText').Text = [string] $Driver.InfName
    $window.FindName('HDTDriverModelText').Text = [string] @($Driver.HardwareId).Count

    $enabled = $window.FindName('HDTDriverEnabledCheck')
    $enabled.IsChecked = [bool] $Driver.Enabled

    $window.FindName('HDTDriverPnpGrid').ItemsSource = [object[]] @(
        @($Driver.HardwareId) | ForEach-Object { [pscustomobject] @{ HardwareId = [string] $_ } })

    $command = $window.FindName('HDTDriverCommandText')
    $status = $window.FindName('HDTDriverStatusText')
    $save = $window.FindName('HDTDriverSaveButton')

    # WHAT THE SHARE SAYS, WHICH IS NOT WHAT THE BOX SAYS. The difference
    # between the two is the whole of Save's state, and it moves only when a
    # write comes back - which is why it is tracked on an object rather than in
    # a variable a closure would capture by value.
    $book = [pscustomobject] @{ Saved = [bool] $Driver.Enabled; Written = $false }

    $showState = {
        $state = & $call 'Get-HDTConsoleDriverSaveState' @{
            Enabled = [bool] $enabled.IsChecked; Saved = [bool] $book.Saved
            Root = $Root; Path = [string] $Driver.Path; Written = [bool] $book.Written
        }

        $command.Text = [string] $state.Command
        $status.Text = [string] $state.Status
        $save.IsEnabled = [bool] $state.CanSave
    }.GetNewClosure()

    & $showState

    $enabled.Add_Click({ & $showState }.GetNewClosure())

    # -- Save, which writes one boolean ---------------------------------------

    $save.Add_Click({
            $want = [bool] $enabled.IsChecked

            try {
                [void] (& $call 'Set-HDTDriverState' @{
                        Root = $Root; Path = [string] $Driver.Path
                        Enabled = $want; FileSystem = $writer; Confirm = $false
                    })
            } catch {
                # THE BOOK DOES NOT MOVE ON A REFUSAL. Save stays lit and the
                # status stays where it was, because the share still says what
                # it said before.
                $command.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $book.Saved = $want
            $book.Written = $true
            $driverHost.Answer = 'saved'

            & $showState
        }.GetNewClosure())

    # -- Delete ---------------------------------------------------------------
    #
    # IT REMOVES THE FOLDER THE .inf SITS IN, not the .inf alone. A driver is an
    # .inf AND the .sys, .cat and .dll beside it; deleting the .inf would leave
    # the rest as litter the catalog can no longer see or name.
    $window.FindName('HDTDriverDeleteButton').Add_Click({
            $folder = [string] $Driver.Folder

            if ([string]::IsNullOrWhiteSpace($folder)) {
                $command.Text = '# this driver sits at the top of the store, so there is no folder to remove.'
                return
            }

            try {
                [void] (& $call 'Remove-HDTDriverFolder' @{
                        Root = $Root; Path = $folder; FileSystem = $writer; Confirm = $false
                    })
            } catch {
                $command.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $driverHost.Answer = 'deleted'
            $command.Text = "Remove-HDTDriverFolder -Root '{0}' -Path '{1}'" -f $Root, $folder

            try { $window.Close() } catch {
                Write-Verbose 'the window was never shown, so there was nothing to close.'
            }
        }.GetNewClosure())

    $window.FindName('HDTDriverCloseButton').Add_Click({
            try { $window.Close() } catch {
                Write-Verbose 'the window was never shown, so there was nothing to close.'
            }
        }.GetNewClosure())

    return $window
}

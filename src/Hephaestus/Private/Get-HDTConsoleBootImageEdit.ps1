function Get-HDTConsoleBootImageEdit {
    <#
        .SYNOPSIS
            What one press of Save on the console's boot image pane writes to
            workspace.yaml.

        .DESCRIPTION
            FOURTEEN BRANCHES, TAKEN OUT OF AN Add_Click. Every optional setting
            on that pane made the same decision twice over and made it inside a
            WPF handler, where nothing could test it. This is that decision, on
            its own: it is handed what the boxes say and returns what to write.
            It touches no window, reads no share and saves nothing.

            EMPTY MEANS TWO OPPOSITE THINGS ON ONE SCREEN, which is the whole
            reason this is worth a command of its own.

            An empty PROPERTY box is a question nobody answered, so the key is
            left as it is. Clearing the boot image name would leave the share
            with a nameless boot image and a build that refuses - the pane offers
            no way back from that, because the box you would type the name into
            is the one that emptied it.

            An empty DOCUMENT box is an instruction: it is how an unattend file,
            a background, a time zone, a client certificate or a driver profile
            gets taken back off a boot image that already had one. There is no
            other control for "remove this", so the empty box has to mean it.

            A TICK BOX HAS NO EMPTY. Unticked is an answer, so PromptForKey is
            written whichever way it is set: 'promptForKey: false' in the
            document tells the next reader somebody decided, where a missing key
            tells them nothing at all.

            THE COMMAND AND ITS PARAMETER TRAVEL WITH THE VALUE. Three of the
            five documents are set with -Path and two with -Name; handing a path
            to -Name is a parameter binding failure inside a click handler, and
            the only symptom a technician sees is a Save button that does
            nothing. Naming both here puts that pairing somewhere a test can
            assert it.

            THE SCRATCH SPACE IS TYPED ON THE WAY THROUGH. The combo box hands
            back a string, and 'scratchSpaceMB: "512"' is not what a build reads.

        .PARAMETER BootImageName
            The name box. Empty leaves the key alone.

        .PARAMETER Architecture
            The architecture selection. Empty leaves the key alone.

        .PARAMETER Language
            The language box. Empty leaves the key alone.

        .PARAMETER ScratchSpaceMB
            The scratch space selection, as the combo box hands it over. Empty
            leaves the key alone; anything else is written as a number.

        .PARAMETER PromptForKey
            The tick box. Always written.

        .PARAMETER Unattend
            The unattend path. Empty clears it.

        .PARAMETER Background
            The background image path. Empty clears it.

        .PARAMETER TimeZone
            The time zone name. Empty clears it.

        .PARAMETER ClientCertificate
            The client certificate path. Empty clears it.

        .PARAMETER Driver
            The driver profile name. Empty clears it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Property  a hashtable to splat onto Set-HDTWorkspaceProperty
              Edit      five rows, in the order they are to be applied:
                          Command    the Set-HDTBootImage* command to call
                          Clear      whether to call it with -Clear
                          Parameter  'Path' or 'Name', the one it takes
                          Value      what to pass, '' when clearing

        .EXAMPLE
            Get-HDTConsoleBootImageEdit -BootImageName 'HDT Boot' -PromptForKey $true

        .EXAMPLE
            $edit = Get-HDTConsoleBootImageEdit -BootImageName $nameBox.Text -PromptForKey $check.IsChecked
            $line = @(Set-HDTWorkspaceProperty -Line $line @($edit.Property))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $BootImageName,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Architecture,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Language,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $ScratchSpaceMB,

        [Parameter()] [bool] $PromptForKey,

        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Unattend,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Background,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $TimeZone,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $ClientCertificate,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Driver
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # AN UNANSWERED PROPERTY IS LEFT ALONE. Ordered so the splat reads the way
    # the pane does, top to bottom, when it is echoed back as a command line.
    $property = [ordered] @{}

    if (-not [string]::IsNullOrWhiteSpace($BootImageName)) { $property['BootImageName'] = $BootImageName }
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) { $property['Architecture'] = $Architecture }
    if (-not [string]::IsNullOrWhiteSpace($Language)) { $property['Language'] = $Language }
    if (-not [string]::IsNullOrWhiteSpace($ScratchSpaceMB)) { $property['ScratchSpaceMB'] = [int] $ScratchSpaceMB }

    # ALWAYS, unlike every box above it. See the tick box note above.
    $property['PromptForKey'] = [bool] $PromptForKey

    # The five documents, each with the parameter its command actually takes.
    $document = @(
        @{ Command = 'Set-HDTBootImageUnattend'; Parameter = 'Path'; Value = $Unattend }
        @{ Command = 'Set-HDTBootImageBackground'; Parameter = 'Path'; Value = $Background }
        @{ Command = 'Set-HDTBootImageTimeZone'; Parameter = 'Name'; Value = $TimeZone }
        @{ Command = 'Set-HDTBootImageClientCertificate'; Parameter = 'Path'; Value = $ClientCertificate }
        @{ Command = 'Set-HDTBootImageDriver'; Parameter = 'Name'; Value = $Driver }
    )

    $edit = foreach ($one in $document) {
        $empty = [string]::IsNullOrWhiteSpace([string] $one.Value)

        [pscustomobject] @{
            Command   = [string] $one.Command
            Clear     = $empty
            Parameter = [string] $one.Parameter

            # NOTHING TO WRITE WITH WHEN CLEARING, rather than the whitespace
            # the box happened to hold: a caller that ignored Clear and passed
            # this straight through would write a key of spaces.
            Value     = if ($empty) { '' } else { [string] $one.Value }
        }
    }

    return [pscustomobject] @{
        Property = $property
        Edit     = [pscustomobject[]] @($edit)
    }
}

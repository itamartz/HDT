function Get-HDTConsoleCommandLine {
    <#
        .SYNOPSIS
            Everything on the editor's Run Command Line page, decided in a
            command so the window assigns and branches on nothing.

        .DESCRIPTION
            THE RUN COMMAND LINE STEP GETS ITS OWN PROPERTIES PAGE, the same
            bargain the disk, image, validate and application tabs already
            make. What it replaces was two rows on the generic sheet: 'Command',
            and 'successCodes - 2 entries, a table not a value'.

            SO workingDirectory COULD NOT BE REACHED FROM THE CONSOLE AT ALL.
            Invoke-HDTCommandLineStep reads it, MDT calls it "Start in", and
            every installer that resolves a relative path depends on it - and
            the only way to set one was to open the YAML in an editor. The exit
            codes were worse than absent: shown, and not editable.

            TWO FORMS, BECAUSE THE ENGINE HAS TWO. 'command' is a shell line run
            through %ComSpec% /c, and it is what a new step gets. 'file' plus
            'arguments' is a direct exec, with no shell to misread a quote. A
            document using the second was written that way on purpose, so
            UsesFile tells the page to show those two boxes instead of rewriting
            the step into a form nobody asked for.

            THE CODES SHOW THE DEFAULT WHEN THE FILE IS SILENT, and say that
            they are doing it. Invoke-HDTCommandLineStep treats an absent
            successCodes as 0 and an absent rebootCodes as 3010 - an empty box
            would read as "any code will do", which is the opposite of what the
            step does. Declared is what lets Apply leave a key the author never
            wrote out of the diff (DESIGN 12).

            THERE IS NO DEFAULT WORKING DIRECTORY and the box stays empty for
            one. The process service is handed none, so a box showing 'C:\'
            would be a lie about what the step runs.

            A STEP THAT IS NOT THERE COMES BACK WITH THE SAME SHAPE. The editor
            rebuilds this pane after every splice including the one that deleted
            the selected step, and a page that threw would take the window down
            on a successful delete.

        .PARAMETER Line
            The document's lines, as read.

        .PARAMETER Path
            The document's path, for the parser's messages.

        .PARAMETER Name
            The selected step, by name.

        .PARAMETER Document
            What the host already parsed. The editor rebuilds its whole right
            pane after every edit, and each view model turning the same lines
            back into a document costs about 70ms on the UI thread. Omitted,
            this parses the lines itself, which is what a script or a test wants.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              IsCommandLineStep     whether this page belongs on screen
              UsesFile              the direct-exec form rather than the shell one
              CommandLine           the shell line, as written
              File, Arguments       the direct-exec pair, as written
              WorkingDirectory      the directory the command runs in
              SuccessCode           the codes that mean it worked, comma separated
              RebootCode            the codes that mean it wants a restart
              SuccessCodeDeclared   whether the file says so, or this is the default
              RebootCodeDeclared    the same for the reboot codes
              Note                  what is wrong with the step, or empty
              Command               the cmdlet that produced the page

        .EXAMPLE
            Get-HDTConsoleCommandLine -Line $line -Path $path -Name 'Run Command Line'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -ne $Document) {
        $sequence = $Document
    } else {
        $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
        $sequence = Import-HDTSequenceDocument -Path $Path -FileSystem $reader
    }

    $step = @($sequence.Step | Where-Object { $_.Name -eq $Name })

    $isCommandLineStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'CommandLine')

    $property = $null
    if (@($step).Count -gt 0) { $property = $step[0].Property }

    # A KEY THE DOCUMENT WROTE, AS ONE STRING. Contains() on a null property bag
    # is what the StrictMode here would otherwise turn into a terminating error
    # on a step that carries no properties at all - which a half-written one does.
    $read = {
        param([string] $Key)

        if ($null -eq $property) { return '' }
        if (-not $property.Contains($Key)) { return '' }

        return [string] $property[$Key]
    }

    # A LIST, AS A PERSON WOULD RETYPE IT. '0, 1641, 3010' is the string the box
    # shows and Set-HDTStepPropertyList takes back apart - not the YAML, because
    # the brackets are punctuation the page owns and not a value anybody types.
    $readList = {
        param([string] $Key, [string] $Default)

        if ($null -eq $property -or -not $property.Contains($Key)) {
            return [pscustomobject] @{ Text = $Default; Declared = $false }
        }

        $text = ((@($property[$Key]) | ForEach-Object { [string] $_ }) -join ', ')

        return [pscustomobject] @{ Text = $text; Declared = $true }
    }

    $command = [string] (& $read 'command')
    $file = [string] (& $read 'file')
    $arguments = [string] (& $read 'arguments')

    # THE ENGINE'S OWN PRECEDENCE, NOT THE PAGE'S. Invoke-HDTCommandLineStep
    # takes 'command' when it is there and non-blank, and only then falls to
    # 'file' - so a document carrying both runs the shell line, and a page that
    # showed the file boxes would describe a step that will not happen.
    $usesFile = ([string]::IsNullOrWhiteSpace($command) -and -not [string]::IsNullOrWhiteSpace($file))

    $success = & $readList 'successCodes' '0'
    $reboot = & $readList 'rebootCodes' '3010'

    # THE REFUSAL THE ENGINE WILL MAKE, MADE HERE INSTEAD - at the moment the
    # step is being written, rather than four hours into a deployment. Same
    # sentence, because a technician who meets both should recognise the second.
    $note = ''
    if ($isCommandLineStep -and [string]::IsNullOrWhiteSpace($command) -and [string]::IsNullOrWhiteSpace($file)) {
        $note = 'This step names neither a command nor a file, so it will fail when it runs. Type the command line it should run.'
    }

    return [pscustomobject] @{
        IsCommandLineStep   = $isCommandLineStep
        UsesFile            = $usesFile

        CommandLine         = $command
        File                = $file
        Arguments           = $arguments
        WorkingDirectory    = [string] (& $read 'workingDirectory')

        SuccessCode         = [string] $success.Text
        RebootCode          = [string] $reboot.Text
        SuccessCodeDeclared = [bool] $success.Declared
        RebootCodeDeclared  = [bool] $reboot.Declared

        Note                = $note
        HasNote             = (-not [string]::IsNullOrEmpty($note))

        Command             = ("Get-HDTConsoleCommandLine -Line `$line -Path `$path -Name '{0}'" -f $Name)
    }
}

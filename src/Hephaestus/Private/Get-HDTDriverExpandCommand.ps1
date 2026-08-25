function Get-HDTDriverExpandCommand {
    <#
        .SYNOPSIS
            The program and arguments that expand a vendor driver archive.

        .DESCRIPTION
            WHAT TO RUN, DECIDED WHERE PESTER CAN SEE IT. Running it is the
            process adapter's job and is branch-free because it is not unit
            tested; choosing the switches is a decision, and getting one wrong
            means an archive that silently expands nowhere. So the knowledge
            lives here, in a command that returns strings.

            A .cab - expand.exe, WHICH IS IN EVERY WINDOWS AND EVERY WinPE.
            '-F:*' is the part people miss: without it expand copies the cab's
            first file and stops. '-R' is not used - these are plain cabinets,
            not update packages.

            An .exe - THE SOFTPAQ EXPANDS ITSELF. HP's installers take
            '/s /e /f<path>': silent, extract-only, to a folder. The path is
            attached to /f with NO SPACE, which is HP's own convention and the
            reason a naive '/f <path>' extracts to the current directory
            instead. Dell's own .exe packs accept the same shape.

            A .zip - EXPANDED BY THE FILE SYSTEM, NOT A PROCESS. It is here
            so the
            caller gets one answer for every archive kind; the empty FilePath is
            how it says "no process for this one".

            NOTHING IS QUOTED HERE. Quoting belongs to whoever builds the command
            line, and doubling it produces arguments with literal quotes in them.

        .PARAMETER Kind
            What Get-HDTDriverSourceKind decided.

        .PARAMETER Archive
            The file to expand.

        .PARAMETER Destination
            The folder to expand it into.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with FilePath and
            Argument. FilePath is empty when no process is involved.

        .EXAMPLE
            Get-HDTDriverExpandCommand -Kind 'Cab' -Archive 'D:\p\dell.cab' -Destination 'C:\S\Drivers\WinPE\Dell'

        .EXAMPLE
            (Get-HDTDriverExpandCommand -Kind 'Exe' -Archive 'D:\p\sp150000.exe' -Destination 'C:\out').Argument

            /s /e /f"C:\out" - HP's own switches, with the path attached to /f.

        .LINK
            Get-HDTDriverSourceKind
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Cab', 'Exe', 'Zip')]
        [string] $Kind,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Archive,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Kind -eq 'Cab') {
        return [pscustomobject] @{
            FilePath = 'expand.exe'
            Argument = ('-F:* "{0}" "{1}"' -f $Archive, $Destination)
        }
    }

    if ($Kind -eq 'Exe') {
        return [pscustomobject] @{
            FilePath = $Archive
            Argument = ('/s /e /f"{0}"' -f $Destination)
        }
    }

    return [pscustomobject] @{ FilePath = ''; Argument = '' }
}

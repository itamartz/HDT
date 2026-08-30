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

            An .exe - THE PACK EXPANDS ITSELF, AND THE VENDOR DECIDES HOW.
            HP's SoftPaqs take '/s /e /f<path>': silent, extract-only, to a
            folder. The path is attached to /f with NO SPACE, which is HP's own
            convention and the reason a naive '/f <path>' extracts to the
            current directory instead. A Dell Update Package takes '/s /e="<path>"'
            and nothing else - see the comment on that branch for the pack it was
            verified against. An .exe whose Vendor could not be read keeps HP's
            shape, because most of them in the wild are SoftPaqs.

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

        .PARAMETER Vendor
            What Get-HDTDriverSourceKind read out of the .exe's version block.
            Empty means it could not be read, and that gets HP's shape.

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
        [string] $Destination,

        [Parameter(Position = 3)]
        [AllowEmptyString()]
        [ValidateSet('', 'Dell', 'Hp')]
        [string] $Vendor = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Kind -eq 'Cab') {
        return [pscustomobject] @{
            FilePath = 'expand.exe'
            Argument = ('-F:* "{0}" "{1}"' -f $Archive, $Destination)
        }
    }

    # DELL AND HP DO NOT AGREE, AND THIS CODE USED TO ASSUME THEY DID. A comment
    # here claimed "Dell's own .exe packs accept the same shape" as HP's
    # SoftPaqs. Nobody had run one. On 2026-08-27 an administrator pointed the
    # console at Latitude-5420-X8RTR_Win11_1.0_A13.exe - a 2.38 GB Dell Update
    # Package - and the window locked up.
    #
    # Verified against that exact file: '/s /e="<path>"' exits 0 and extracts
    # 269 .inf files in 86 seconds. HP's '/s /e /f"<path>"' is not what a DUP
    # takes, and a DUP given switches it does not understand falls back to its
    # INTERACTIVE installer - which on a hidden window waits forever, and is why
    # the symptom was a frozen console rather than a failed import.
    if ($Kind -eq 'Exe' -and $Vendor -eq 'Dell') {
        return [pscustomobject] @{
            FilePath = $Archive
            Argument = ('/s /e="{0}"' -f $Destination)
        }
    }

    # HP's own convention, and the default for a vendor that could not be read:
    # most .exe driver packs in the wild are SoftPaqs, so changing what an
    # unidentified pack gets would be a silent regression for every share that
    # works today. An unknown pack is protected by the import running under a
    # timeout and by what lands on disk deciding rather than the exit code - not
    # by this guess being right.
    if ($Kind -eq 'Exe') {
        return [pscustomobject] @{
            FilePath = $Archive
            Argument = ('/s /e /f"{0}"' -f $Destination)
        }
    }

    return [pscustomobject] @{ FilePath = ''; Argument = '' }
}

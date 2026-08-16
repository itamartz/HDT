function Get-HDTBootIsoArgument {
    <#
        .SYNOPSIS
            Builds the oscdimg argument list for a bootable ISO, and refuses the
            one input SPIKES S2 proved cannot work.

        .DESCRIPTION
            PURE STRING LOGIC, AND THAT IS THE POINT. New-HDTBootIso runs
            oscdimg; every decision oscdimg's command line encodes - firmware,
            -NoPromptForKey, the label, the space-free staging - is made here,
            where all six combinations are asserted as exact strings in a suite
            that takes milliseconds and burns nothing.

            SPIKES S2 LIVES HERE, VERBATIM AND LOAD-BEARING:

              -bootdata: CANNOT TAKE A QUOTED PATH.

            The ADK lives under 'C:\Program Files (x86)\...', which has spaces.
            Passing a quoted path from PowerShell produces doubled quotes and
            oscdimg answers

              ERROR: Could not open boot sector file ""C:\Program Files (x86)\...\etfsboot.com""
              Error 123: The filename, directory name, or volume label syntax is incorrect.

            The verified fix is to STAGE THE BOOT BITS INTO A SPACE-FREE
            DIRECTORY FIRST and build the argument with unquoted paths. The
            caller does the staging; this function REFUSES to build an argument
            for a path that has a space in it. That refusal is the only thing
            keeping the staging from being quietly skipped by a future caller who
            "simplified" it, and it is why the message names S2 and quotes the
            error - otherwise the next person fixes it by adding quotes, which is
            precisely what does not work.

            THE FIXED HEAD IS -m -o -u2 -udfver102, the four SPIKES S2 verified
            at 100% completion:

              -m          ignore the maximum image size
              -o          de-duplicate identical files
              -u2         UDF file system
              -udfver102  UDF revision 1.02

            THE SIX COMBINATIONS:

              UEFI  no-prompt   1#pEF,e,b<bits>\efisys_noprompt.bin
              UEFI  prompt      1#pEF,e,b<bits>\efisys.bin
              BIOS  no-prompt   1#p0,e,b<bits>\etfsboot.com          + warning
              BIOS  prompt      1#p0,e,b<bits>\etfsboot.com
              Both  no-prompt   2#p0,e,b<bits>\etfsboot.com#pEF,e,b<bits>\efisys_noprompt.bin  + warning
              Both  prompt      2#p0,e,b<bits>\etfsboot.com#pEF,e,b<bits>\efisys.bin

            THE BIOS WARNING IS NOT AN APOLOGY, IT IS A FACT. etfsboot.com
            carries "Press any key to boot from CD or DVD..." in its boot sector
            and Microsoft ships no no-prompt variant - the Oscdimg folder holds
            oscdimg.exe, etfsboot.com, efisys.bin, efisys_noprompt.bin and the two
            _EX variants, and nothing else. DESIGN 5.2: "HDT states this rather
            than pretending otherwise."

        .PARAMETER Firmware
            UEFI, BIOS or Both. UEFI is what Generation 2 and every modern
            physical machine boot.

        .PARAMETER NoPromptForKey
            Select efisys_noprompt.bin for the UEFI leg. Has no effect on BIOS,
            which warns.

        .PARAMETER BootBitPath
            The space-free directory the caller staged the boot bits into. A path
            containing a space is refused; see the description.

        .PARAMETER Label
            The ISO volume label, uppercased. Defaults to HDTPE_X64. A label
            containing a space is refused - oscdimg takes it as one unquoted
            token. An empty label omits -l entirely.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the arguments before the media root and the ISO
            path, which New-HDTBootIso appends.

        .EXAMPLE
            Get-HDTBootIsoArgument -Firmware UEFI -NoPromptForKey -BootBitPath 'C:\HDTBootBits'

        .EXAMPLE
            Get-HDTBootIsoArgument -Firmware Both -BootBitPath 'C:\HDTBootBits' -Label 'HDTPE_x64'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('UEFI', 'BIOS', 'Both')]
        [string] $Firmware,

        [Parameter()]
        [switch] $NoPromptForKey,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $BootBitPath,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Label = 'HDTPE_x64'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $bits = $BootBitPath.TrimEnd('\', '/')

    # -- SPIKES S2, and there is no back door -------------------------------

    if ($bits -match '\s') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $bits `
                    -Message ("the boot bit path '{0}' contains a space, and oscdimg's -bootdata: argument cannot carry one. A quoted path arrives doubled and oscdimg answers `"ERROR: Could not open boot sector file `"`"...`"`" / Error 123: The filename, directory name, or volume label syntax is incorrect.`" Quoting is not the fix - stage etfsboot.com and efisys*.bin into a directory whose full path has no space (New-HDTBootIso does this) and pass that." -f $bits)))
    }

    if ($Label -match '\s') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Label `
                    -Message ("the ISO label '{0}' contains a space. oscdimg takes the label as one unquoted token after -l, so a space would be read as the start of the next argument. Choose a label without spaces - HDTPE_X64 is the default." -f $Label)))
    }

    # -- the fixed head ------------------------------------------------------

    $argument = New-Object -TypeName System.Collections.ArrayList
    foreach ($item in @('-m', '-o', '-u2', '-udfver102')) { [void] $argument.Add($item) }

    if (-not [string]::IsNullOrWhiteSpace($Label)) {
        [void] $argument.Add('-l' + $Label.ToUpperInvariant())
    }

    # -- the boot bits -------------------------------------------------------

    $etfsboot = [System.IO.Path]::Combine($bits, 'etfsboot.com')
    $efisys = [System.IO.Path]::Combine($bits, 'efisys.bin')
    if ($NoPromptForKey) {
        $efisys = [System.IO.Path]::Combine($bits, 'efisys_noprompt.bin')
    }

    $bootdata = ''

    if ($Firmware -eq 'UEFI') {
        $bootdata = '-bootdata:1#pEF,e,b{0}' -f $efisys
    }

    if ($Firmware -eq 'BIOS') {
        # efisys_noprompt.bin has no BIOS counterpart, so -NoPromptForKey
        # changes nothing here and the operator is told so.
        $bootdata = '-bootdata:1#p0,e,b{0}' -f $etfsboot

        if ($NoPromptForKey) {
            Write-Warning "-NoPromptForKey has no effect on a BIOS boot: etfsboot.com carries the 'Press any key' prompt in its boot sector and Microsoft ships no no-prompt variant. This ISO will prompt when booted on BIOS firmware."
        }
    }

    if ($Firmware -eq 'Both') {
        $bootdata = '-bootdata:2#p0,e,b{0}#pEF,e,b{1}' -f $etfsboot, $efisys

        if ($NoPromptForKey) {
            Write-Warning "-NoPromptForKey has no effect on a BIOS boot: etfsboot.com carries the 'Press any key' prompt in its boot sector and Microsoft ships no no-prompt variant. This ISO will prompt when booted on BIOS firmware - on the BIOS leg only; the UEFI leg will not prompt."
        }
    }

    [void] $argument.Add($bootdata)

    return [string[]] @($argument)
}

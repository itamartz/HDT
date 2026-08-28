function Get-HDTAdkComponentDescription {
    <#
        .SYNOPSIS
            What a WinPE optional component does, in one line.

        .DESCRIPTION
            THE ADK SHIPS NO DESCRIPTIONS. WinPE_OCs\ is a folder of .cab files
            and nothing else: no manifest, no metadata, not even a friendly
            name. Everything Get-HDTAdkComponent knows is derived from those
            filenames, which is why the console's Features tab read
            `WinPE-Dot3Svc  1.3 MB` and told an administrator nothing at all
            about what ticking it would do.

            SO HDT SHIPS A TABLE. The line beside a component on the Features
            tab comes from here and from nowhere else - which is the answer
            MDT's Deployment Workbench reached for the same reason.

            THE TEXT IS MICROSOFT'S, CONDENSED TO A LINE. It comes from the
            WinPE Optional Components (OC) Reference, cut down to something that
            fits a column beside a name and a size - a paragraph in a list row
            is a paragraph nobody reads. A test caps the length, because the
            temptation to paste the whole entry is real.

            FOUR ENTRIES ARE NOT IN MICROSOFT'S TABLE and are described from the
            cab name and what the component demonstrably contains:
            WinPE-FontSupport-WinRE, WinPE-PmemCmdlets, WinPE-Setup-ASZ and
            WinPE-FontSupport-ZH-TW. They are marked below.

            AN UNKNOWN NAME ANSWERS EMPTY rather than throwing. The next ADK
            will ship a component nobody here has written a line for, and the
            row must still appear with its name and its size - a window that
            refused to open over an undocumented cab would be a worse toolkit
            than one with a blank column.

        .PARAMETER Name
            The component, with or without regard to case. Omitted, the whole
            table is returned - which is what the tests measure and what a
            report would enumerate.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String, or System.Collections.Hashtable when -Name is
            omitted.

        .EXAMPLE
            Get-HDTAdkComponentDescription -Name 'WinPE-SecureStartup'

        .EXAMPLE
            (Get-HDTAdkComponentDescription).Keys | Sort-Object
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Name = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A PLAIN HASHTABLE, WHICH IS ALREADY CASE-INSENSITIVE. PowerShell's literal
    # hashtable compares keys without regard to case, so an earlier version
    # constructing one around an OrdinalIgnoreCase comparer was asking for the
    # behaviour it already had - and PSScriptAnalyzer says so. It matters
    # because a hand-edited workspace.yaml spells these however the
    # administrator spelled them, and Get-HDTBootImageComponent compares them
    # the same way.
    $table = @{}

    # -- scripting and management ------------------------------------------

    $table['WinPE-WMI'] = 'WMI providers for system diagnostics - the query surface most gather scripts use.'
    $table['WinPE-Scripting'] = 'Windows Script Host - VBScript, JScript and the COM objects they call.'
    $table['WinPE-NetFx'] = 'A subset of .NET Framework 4.5, which every .NET application in WinPE needs.'
    $table['WinPE-PowerShell'] = 'Windows PowerShell. No remoting and no ISE, and PowerShell 2.0 is not supported.'
    $table['WinPE-DismCmdlets'] = 'The DISM PowerShell module - cmdlets for servicing Windows images.'
    $table['WinPE-StorageWMI'] = 'PowerShell storage cmdlets - disks, partitions, volumes and iSCSI initiators.'
    $table['WinPE-SecureBootCmdlets'] = 'PowerShell cmdlets for the UEFI Secure Boot environment variables.'
    $table['WinPE-PlatformId'] = 'PowerShell cmdlets that read the machine''s Platform Identifier.'
    $table['WinPE-HTA'] = 'HTML Applications - GUI tools written in HTML and script.'
    $table['WinPE-MDAC'] = 'ODBC, OLE DB and ADO - reading a database, SQL Server included.'

    # NOT IN MICROSOFT'S TABLE. Named from the cab and what it contains.
    $table['WinPE-PmemCmdlets'] = 'PowerShell cmdlets for persistent memory devices.'

    # -- storage and startup -------------------------------------------------

    $table['WinPE-SecureStartup'] = 'BitLocker and the TPM - the tools, the WMI classes and the TPM driver.'
    $table['WinPE-EnhancedStorage'] = 'Encrypted and IEEE 1667 storage devices, so BitLocker can manage them natively.'
    $table['WinPE-FMAPI'] = 'The File Management API - recovering deleted files, from BitLocker volumes too.'
    $table['WinPE-HSP-Driver'] = 'The Microsoft Pluton security processor. amd64 only.'

    # -- network -------------------------------------------------------------

    $table['WinPE-WDS-Tools'] = 'The Windows Deployment Services client APIs - image capture and multicast.'
    $table['WinPE-Dot3Svc'] = 'IEEE 802.1X authentication on wired networks.'
    $table['WinPE-PPPoE'] = 'PPPoE connections - creating, connecting and deleting them from WinPE.'
    $table['WinPE-RNDIS'] = 'Remote NDIS - networking through USB-attached devices.'
    $table['WinPE-WiFi-Package'] = 'Used by Windows RE. Ships inside winre.wim, not with the ADK.'

    # -- setup and recovery --------------------------------------------------

    $table['WinPE-Setup'] = 'The Setup files common to client and server. The parent of the two below.'
    $table['WinPE-Setup-Client'] = 'Client branding for WinPE-Setup.'
    $table['WinPE-Setup-Server'] = 'Server branding for WinPE-Setup.'
    $table['WinPE-LegacySetup'] = 'Every Setup file from the media''s \Sources folder, for servicing Setup itself.'
    $table['WinPE-WinReCfg'] = 'Winrecfg.exe - configuring Windows RE on an offline image of the other architecture.'
    $table['WinPE-Rejuv'] = 'Used by Windows RE. Ships inside winre.wim, not with the ADK.'
    $table['WinPE-SRT'] = 'Used by Windows RE. Ships inside winre.wim, not with the ADK.'

    # NOT IN MICROSOFT'S TABLE. Named from the cab; it sits beside the two
    # branding components above.
    $table['WinPE-Setup-ASZ'] = 'Azure Stack branding for WinPE-Setup.'

    # -- input, architecture and fonts ---------------------------------------

    $table['WinPE-GamingPeripherals'] = 'Xbox wireless controllers.'
    $table['WinPE-x64-Support'] = 'x64 emulation on an arm64 WinPE. arm64 only.'

    $table['WinPE-Fonts-Legacy'] = '32 legacy fonts - Indic, Khmer, Lao, Tibetan, Mongolian, Ethiopic and more.'
    $table['WinPE-FontSupport-JA-JP'] = 'Japanese fonts - MS Gothic and Meiryo.'
    $table['WinPE-FontSupport-KO-KR'] = 'Korean fonts - Gulim, Batang and Malgun Gothic.'
    $table['WinPE-FontSupport-ZH-CN'] = 'Simplified Chinese fonts - Simsun and YaHei.'
    $table['WinPE-FontSupport-ZH-HK'] = 'Traditional Chinese fonts for Hong Kong, with the HKSCS character set.'

    # NOT IN MICROSOFT'S TABLE as a row of its own; it shares ZH-HK's entry.
    $table['WinPE-FontSupport-ZH-TW'] = 'Traditional Chinese fonts for Taiwan - MingLiu and JhengHei.'

    # NOT IN MICROSOFT'S TABLE. Named from the cab.
    $table['WinPE-FontSupport-WinRE'] = 'The font set Windows RE renders its own screens with.'

    if ([string]::IsNullOrWhiteSpace($Name)) { return $table }

    if (-not $table.ContainsKey($Name)) { return '' }

    return [string] $table[$Name]
}

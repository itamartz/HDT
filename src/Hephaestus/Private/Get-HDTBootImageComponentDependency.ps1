function Get-HDTBootImageComponentDependency {
    <#
        .SYNOPSIS
            The WinPE optional component dependency table, with a citation on
            every row.

        .DESCRIPTION
            One row per component that declares a dependency on ANOTHER OPTIONAL
            COMPONENT. Each row carries Requires (the component names) and Source
            (where the row came from).

            EVERY ROW IS TRANSCRIBED FROM MICROSOFT'S OWN PACKAGE METADATA. Each
            WinPE_OCs cab contains an `update.mum` - the package manifest -
            declaring the packages it is a child of:

                <package identifier="WinPE-PowerShell" releaseType="Feature Pack">
                  <parent integrate="delegate">
                    <assemblyIdentity name="WinPE-NetFx-Package" ... />
                  </parent>

            That is the citation for every row below, and it is re-derivable on
            any machine with the ADK installed:

                $oc = Get-HDTAdkPath -Asset WinPeOptionalComponent
                foreach ($cab in Get-ChildItem $oc -Filter *.cab) {
                    $dir = Join-Path $env:TEMP ([IO.Path]::GetFileNameWithoutExtension($cab.Name))
                    & "$env:SystemRoot\System32\expand.exe" -f:*.mum $cab.FullName $dir
                    # //package/parent/assemblyIdentity/@name
                }

            A DEPENDENCY THIS REPOSITORY CANNOT CITE IS OMITTED, NEVER GUESSED.
            An invented dependency refuses a build that would have worked, and
            does it in the name of documentation that does not say so. Omission
            is safe: a component absent from this table is allowed with no
            dependencies, which is already the shipped default for the twenty-odd
            components not named here.

            THREE KINDS OF PARENT ARE DELIBERATELY NOT ROWS:

            1. `Microsoft-Windows-WinPE-Package`, `Microsoft-Windows-Foundation-Package`
               and `Microsoft-Windows-ServerCore-Package` are WinPE itself. They
               are in the base image before any optional component is applied, so
               a row for them could only ever refuse a build that was fine.
            2. A dependency satisfied by the REQUIRED SIX can never refuse
               anything either, because those six are always present and always
               first - but the rows are kept anyway, because they are what proves
               The boot-verified order agrees with Microsoft's declared
               one (see the test of that name).
            3. Components whose manifest declares no parent at all. Note in
               particular that `WinPE-Setup-Server` and `WinPE-Setup-ASZ` declare
               none while `WinPE-Setup-Client` declares `WinPE-Setup`. That
               asymmetry is recorded as it is, not tidied into a pattern.

            Read from ADK 10.1.26100.2454, amd64.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Collections.Hashtable - component name -> @{ Requires; Source }.
            Case-insensitive on the key, as component names are everywhere else.

        .EXAMPLE
            (Get-HDTBootImageComponentDependency)['WinPE-PowerShell'].Requires

            Returns WinPE-NetFx.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $source = 'ADK 10.1.26100.2454 amd64 WinPE_OCs\{0}.cab, update.mum: //package/parent/assemblyIdentity[@name="{1}-Package"]'

    $table = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    $table['WinPE-PowerShell'] = @{
        Requires = @('WinPE-NetFx')
        Source   = ($source -f 'WinPE-PowerShell', 'WinPE-NetFx')
    }

    $table['WinPE-DismCmdlets'] = @{
        Requires = @('WinPE-PowerShell')
        Source   = ($source -f 'WinPE-DismCmdlets', 'WinPE-PowerShell')
    }

    $table['WinPE-StorageWMI'] = @{
        Requires = @('WinPE-WMI')
        Source   = ($source -f 'WinPE-StorageWMI', 'WinPE-WMI')
    }

    $table['WinPE-PmemCmdlets'] = @{
        Requires = @('WinPE-PowerShell')
        Source   = ($source -f 'WinPE-PmemCmdlets', 'WinPE-PowerShell')
    }

    $table['WinPE-SecureBootCmdlets'] = @{
        Requires = @('WinPE-PowerShell')
        Source   = ($source -f 'WinPE-SecureBootCmdlets', 'WinPE-PowerShell')
    }

    # The only row where both sides are OPTIONAL, so the only row that can refuse
    # a build on its own. WinPE-Setup-Server and WinPE-Setup-ASZ declare no
    # parent - see the note above.
    $table['WinPE-Setup-Client'] = @{
        Requires = @('WinPE-Setup')
        Source   = ($source -f 'WinPE-Setup-Client', 'WinPE-Setup')
    }

    return $table
}

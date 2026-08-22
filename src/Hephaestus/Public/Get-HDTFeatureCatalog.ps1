function Get-HDTFeatureCatalog {
    <#
        .SYNOPSIS
            The Windows Server roles and features the console offers to tick,
            grouped the way Server Manager groups them.

        .DESCRIPTION
            MDT'S Install Roles and Features DIALOG IS A TICK LIST, and this is
            what fills it. Before it, the console offered a text box: a
            technician had to know that the IIS role is spelled 'Web-Server' and
            not 'IIS' or 'Web Server', type it correctly, and find out at the
            machine if they had not.

            IT IS A STATIC TABLE, AND SO IS MDT'S. The step installs through
            Install-WindowsFeature, so the authoritative list is whatever
            Get-WindowsFeature returns ON THE TARGET - and the console is not
            running on the target, has no session to it, and is frequently
            running on a Windows client that has no ServerManager module at all.
            MDT solved this by shipping a list per operating system; so does this.

            SO IT IS AN OFFER, NOT A CONTRACT, and the engine is still the
            authority. Invoke-HDTInstallRolesStep asks the target for its own
            feature list and refuses a name that is not on it BEFORE it installs
            anything - so a name this table gets wrong fails at the machine with
            a message naming it, rather than installing something unexpected.

            A NAME THE DOCUMENT HAS AND THIS TABLE DOES NOT IS STILL SHOWN, by
            Get-HDTConsoleFeatureChoice rather than here. That is the same
            bargain the Operating System page makes with an image the share no
            longer holds: a sequence that names something unfamiliar is a
            sequence somebody wrote on purpose, and hiding the entry would lose
            it the first time anybody ticked a box.

            THESE ARE THE Install-WindowsFeature NAMES, not the DISM ones.
            Get-WindowsOptionalFeature calls the web server 'IIS-WebServer';
            Install-WindowsFeature calls it 'Web-Server'. The step uses the
            second, so this table does.

            THE LIST IS THE COMMON ONES, NOT ALL 250. Server 2025 has far more
            than this, most of them sub-features nobody names directly in a task
            sequence. Anything missing can still be typed, because the page keeps
            an unknown name rather than dropping it.

        .PARAMETER Category
            Only the entries in one group. Omitted, every entry comes back.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], each with:

              Name         the Install-WindowsFeature name, which is what the
                           document holds
              DisplayName  what Server Manager calls it
              Category     the group it is shown under
              Note         why somebody would want it, or empty

        .EXAMPLE
            Get-HDTFeatureCatalog

        .EXAMPLE
            Get-HDTFeatureCatalog -Category 'Roles'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Category = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $new = {
        param([string] $Group, [string] $Name, [string] $DisplayName, [string] $Note)

        return [pscustomobject] @{
            Name        = $Name
            DisplayName = $DisplayName
            Category    = $Group
            Note        = $Note
        }
    }

    $row = @(
        # -- the roles, in Server Manager's own order ------------------------
        & $new 'Roles' 'AD-Certificate' 'Active Directory Certificate Services' ''
        & $new 'Roles' 'AD-Domain-Services' 'Active Directory Domain Services' 'Promoting the machine afterwards is a separate step; this only installs the binaries.'
        & $new 'Roles' 'ADFS-Federation' 'Active Directory Federation Services' ''
        & $new 'Roles' 'ADLDS' 'Active Directory Lightweight Directory Services' ''
        & $new 'Roles' 'DHCP' 'DHCP Server' ''
        & $new 'Roles' 'DNS' 'DNS Server' ''
        & $new 'Roles' 'Fax' 'Fax Server' ''
        & $new 'Roles' 'FileAndStorage-Services' 'File and Storage Services' 'Installed on every Server by default.'
        & $new 'Roles' 'FS-FileServer' 'File Server' ''
        & $new 'Roles' 'FS-DFS-Namespace' 'DFS Namespaces' ''
        & $new 'Roles' 'FS-DFS-Replication' 'DFS Replication' ''
        & $new 'Roles' 'FS-Resource-Manager' 'File Server Resource Manager' ''
        & $new 'Roles' 'FS-iSCSITarget-Server' 'iSCSI Target Server' ''
        & $new 'Roles' 'FS-NFS-Service' 'Server for NFS' ''
        & $new 'Roles' 'Hyper-V' 'Hyper-V' 'Needs a restart, and the hardware has to support it.'
        & $new 'Roles' 'NPAS' 'Network Policy and Access Services' ''
        & $new 'Roles' 'Print-Services' 'Print and Document Services' ''
        & $new 'Roles' 'Print-Server' 'Print Server' ''
        & $new 'Roles' 'Remote-Desktop-Services' 'Remote Desktop Services' ''
        & $new 'Roles' 'RDS-RD-Server' 'Remote Desktop Session Host' ''
        & $new 'Roles' 'RDS-Connection-Broker' 'Remote Desktop Connection Broker' ''
        & $new 'Roles' 'RDS-Gateway' 'Remote Desktop Gateway' ''
        & $new 'Roles' 'RDS-Licensing' 'Remote Desktop Licensing' ''
        & $new 'Roles' 'RDS-Web-Access' 'Remote Desktop Web Access' ''
        & $new 'Roles' 'RemoteAccess' 'Remote Access' ''
        & $new 'Roles' 'DirectAccess-VPN' 'DirectAccess and VPN (RAS)' ''
        & $new 'Roles' 'Routing' 'Routing' ''
        & $new 'Roles' 'Web-Application-Proxy' 'Web Application Proxy' ''
        & $new 'Roles' 'VolumeActivation' 'Volume Activation Services' ''
        & $new 'Roles' 'Web-Server' 'Web Server (IIS)' 'The role. The pages, authentication and management tools below are separate.'
        & $new 'Roles' 'WDS' 'Windows Deployment Services' ''
        & $new 'Roles' 'WDS-Deployment' 'Deployment Server' ''
        & $new 'Roles' 'WDS-Transport' 'Transport Server' ''
        & $new 'Roles' 'UpdateServices' 'Windows Server Update Services' ''

        # -- IIS, which is the role most often specified in parts ------------
        & $new 'Web Server (IIS)' 'Web-Common-Http' 'Common HTTP Features' ''
        & $new 'Web Server (IIS)' 'Web-Default-Doc' 'Default Document' ''
        & $new 'Web Server (IIS)' 'Web-Dir-Browsing' 'Directory Browsing' ''
        & $new 'Web Server (IIS)' 'Web-Http-Errors' 'HTTP Errors' ''
        & $new 'Web Server (IIS)' 'Web-Static-Content' 'Static Content' ''
        & $new 'Web Server (IIS)' 'Web-Http-Redirect' 'HTTP Redirection' ''
        & $new 'Web Server (IIS)' 'Web-Http-Logging' 'HTTP Logging' ''
        & $new 'Web Server (IIS)' 'Web-Stat-Compression' 'Static Content Compression' ''
        & $new 'Web Server (IIS)' 'Web-Dyn-Compression' 'Dynamic Content Compression' ''
        & $new 'Web Server (IIS)' 'Web-Filtering' 'Request Filtering' ''
        & $new 'Web Server (IIS)' 'Web-Basic-Auth' 'Basic Authentication' ''
        & $new 'Web Server (IIS)' 'Web-Windows-Auth' 'Windows Authentication' ''
        & $new 'Web Server (IIS)' 'Web-Net-Ext45' '.NET Extensibility 4.8' ''
        & $new 'Web Server (IIS)' 'Web-Asp-Net45' 'ASP.NET 4.8' ''
        & $new 'Web Server (IIS)' 'Web-ISAPI-Ext' 'ISAPI Extensions' ''
        & $new 'Web Server (IIS)' 'Web-ISAPI-Filter' 'ISAPI Filters' ''
        & $new 'Web Server (IIS)' 'Web-Mgmt-Console' 'IIS Management Console' ''
        & $new 'Web Server (IIS)' 'Web-Scripting-Tools' 'IIS Management Scripts and Tools' ''
        & $new 'Web Server (IIS)' 'Web-Mgmt-Compat' 'IIS 6 Management Compatibility' ''
        & $new 'Web Server (IIS)' 'Web-Metabase' 'IIS 6 Metabase Compatibility' ''

        # -- the features ----------------------------------------------------
        & $new 'Features' 'NET-Framework-Features' '.NET Framework 3.5 Features' 'Its payload is not in the image. Set a payload source, or the install fails with 0x800F081F.'
        & $new 'Features' 'NET-Framework-Core' '.NET Framework 3.5 (includes .NET 2.0 and 3.0)' 'The one that needs a payload source.'
        & $new 'Features' 'NET-Framework-45-Features' '.NET Framework 4.8 Features' ''
        & $new 'Features' 'NET-WCF-Services45' 'WCF Services' ''
        & $new 'Features' 'NET-HTTP-Activation' 'HTTP Activation' ''
        & $new 'Features' 'BitLocker' 'BitLocker Drive Encryption' ''
        & $new 'Features' 'BitLocker-NetworkUnlock' 'BitLocker Network Unlock' ''
        & $new 'Features' 'BITS' 'Background Intelligent Transfer Service (BITS)' ''
        & $new 'Features' 'Containers' 'Containers' ''
        & $new 'Features' 'Data-Center-Bridging' 'Data Center Bridging' ''
        & $new 'Features' 'EnhancedStorage' 'Enhanced Storage' ''
        & $new 'Features' 'Failover-Clustering' 'Failover Clustering' ''
        & $new 'Features' 'GPMC' 'Group Policy Management' ''
        & $new 'Features' 'MultiPath-IO' 'Multipath I/O' ''
        & $new 'Features' 'Search-Service' 'Windows Search Service' ''
        & $new 'Features' 'Server-Media-Foundation' 'Media Foundation' 'Some applications will not install without it on Server Core.'
        & $new 'Features' 'SMTP-Server' 'SMTP Server' ''
        & $new 'Features' 'SNMP-Service' 'SNMP Service' ''
        & $new 'Features' 'Telnet-Client' 'Telnet Client' ''
        & $new 'Features' 'TFTP-Client' 'TFTP Client' ''
        & $new 'Features' 'WAS' 'Windows Process Activation Service' ''
        & $new 'Features' 'Windows-Defender' 'Microsoft Defender Antivirus' ''
        & $new 'Features' 'Windows-Internal-Database' 'Windows Internal Database' ''
        & $new 'Features' 'Windows-Server-Backup' 'Windows Server Backup' ''
        & $new 'Features' 'WINS' 'WINS Server' ''
        & $new 'Features' 'Wireless-Networking' 'Wireless LAN Service' ''
        & $new 'Features' 'XPS-Viewer' 'XPS Viewer' ''

        # -- the administration tools ----------------------------------------
        & $new 'Management Tools' 'RSAT' 'Remote Server Administration Tools' ''
        & $new 'Management Tools' 'RSAT-Role-Tools' 'Role Administration Tools' ''
        & $new 'Management Tools' 'RSAT-AD-Tools' 'AD DS and AD LDS Tools' ''
        & $new 'Management Tools' 'RSAT-ADDS' 'AD DS Tools' ''
        & $new 'Management Tools' 'RSAT-AD-PowerShell' 'Active Directory module for Windows PowerShell' ''
        & $new 'Management Tools' 'RSAT-DNS-Server' 'DNS Server Tools' ''
        & $new 'Management Tools' 'RSAT-DHCP' 'DHCP Server Tools' ''
        & $new 'Management Tools' 'RSAT-Hyper-V-Tools' 'Hyper-V Management Tools' ''
        & $new 'Management Tools' 'RSAT-Clustering' 'Failover Clustering Tools' ''
        & $new 'Management Tools' 'RSAT-File-Services' 'File Services Tools' ''
        & $new 'Management Tools' 'UpdateServices-RSAT' 'Windows Server Update Services Tools' ''
    )

    if ([string]::IsNullOrWhiteSpace($Category)) { return [pscustomobject[]] @($row) }

    return [pscustomobject[]] @($row | Where-Object { [string] $_.Category -eq $Category })
}

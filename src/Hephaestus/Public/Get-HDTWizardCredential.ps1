function Get-HDTWizardCredential {
    <#
        .SYNOPSIS
            Composes MDT's Bootstrap.ini credential quartet and proves it by
            connecting.

        .DESCRIPTION
            W2 of the WPF-first direction. The four
            fields MDT's Bootstrap.ini carries, and what HDT does with each:

              DeployRoot     the share, and therefore THE SERVER
              UserID         the account
              UserDomain     the domain - or, left blank, the SERVER, which is
                             how Windows names a local account
              UserPassword   never prefilled, never logged

            WHY UserDomain IS ITS OWN FIELD. HDT collapsed it into the username
            string until now ('LAP-AMMSO01\svc-hdt-deploy'), which is fine for a
            machine and wrong for a human: a technician must be able to say
            "this account is LOCAL to that server" without knowing the
            convention is to type the server's name where a domain goes. Blank
            means local, and this command turns that into the name Windows
            needs.

            A UserID THAT ALREADY CARRIES A DOMAIN IS LEFT ALONE. Technicians
            type what they know, and 'CONTOSO\svc' in the user box must not
            become 'CONTOSO\CONTOSO\svc'.

            IT CONNECTS, AND THAT IS THE POINT. A form that only collects text
            moves the failure thirty seconds downstream into a log nobody is
            reading, on a machine that has already started. Connecting here
            makes a wrong password a red line on the page the technician is
            looking at, with the cursor still in the box.

            IT NEVER THROWS FOR A BAD CREDENTIAL. The wizard has to stay on
            screen so the answer can be retyped, so every refusal comes back as
            Connected = $false with a Message. It throws only for the things a
            technician cannot fix by typing.

            IT ALWAYS DISCONNECTS. The mapping this makes is a test, not the
            deployment's, and a wizard that left one behind would hand the
            payload a connection it did not open and cannot reason about.

            THE PASSWORD APPEARS IN NOTHING IT RETURNS except the PSCredential
            itself - not the composed name, not the message, not the provider's
            operation journal. A deployment log is copied around far more freely
            than a password is.

        .PARAMETER DeployRoot
            The share, \\server\share. The server is taken from it.

        .PARAMETER UserId
            MDT's UserID.

        .PARAMETER UserDomain
            MDT's UserDomain. Blank means the account is local to the server.

        .PARAMETER Password
            MDT's UserPassword.

        .PARAMETER ContentProvider
            An IContentProvider to validate with. Built from the composed
            credential when omitted.

        .PARAMETER FileSystem
            An IFileSystem, for the provider built when none is injected.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with UserName, UserId,
            UserDomain, Server, IsLocalAccount, Connected, GuestRefused,
            Credential and Message.

        .EXAMPLE
            Get-HDTWizardCredential -DeployRoot '\\HDT01\HDTShare' -UserId 'svc' -UserDomain '' -Password $secure

            A local account on HDT01, composed as HDT01\svc and proven by
            connecting.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $DeployRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $UserId,

        [Parameter()]
        [AllowEmptyString()]
        [string] $UserDomain = '',

        [Parameter()]
        [AllowNull()]
        [securestring] $Password,

        [Parameter()]
        [AllowNull()]
        [object] $ContentProvider,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [ordered] @{
        UserName       = ''
        UserId         = $UserId
        UserDomain     = $UserDomain
        Server         = ''
        IsLocalAccount = $false
        Connected      = $false
        GuestRefused   = $false
        Credential     = $null
        Message        = ''
    }

    # -- 1. the share, and the server it names ------------------------------

    if (-not ([string] $DeployRoot).StartsWith('\\')) {
        $result['Message'] = ("'{0}' is not a share. A deployment share is a UNC path, \\server\share - a local path needs no account at all." -f $DeployRoot)
        return [pscustomobject] $result
    }

    $part = @(([string] $DeployRoot).TrimStart('\').Split('\') | Where-Object { $_ })
    if ($part.Count -ge 1) { $result['Server'] = [string] $part[0] }

    # -- 2. the account -----------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        $result['Message'] = 'Enter the user name of the deployment account (MDT calls this UserID).'
        return [pscustomobject] $result
    }

    $plain = ''
    if ($null -ne $Password) {
        $plain = [string] (New-Object -TypeName System.Management.Automation.PSCredential `
                -ArgumentList 'placeholder', $Password).GetNetworkCredential().Password
    }

    if ([string]::IsNullOrEmpty($plain)) {
        $result['Message'] = 'Enter the password for the deployment account.'
        return [pscustomobject] $result
    }

    # A user that already carries its own domain wins over the domain box.
    if ($UserId.Contains('\')) {
        $result['UserName'] = $UserId
        $result['UserDomain'] = [string] @($UserId.Split('\'))[0]
    } elseif ([string]::IsNullOrWhiteSpace($UserDomain)) {
        # BLANK MEANS LOCAL, and local is spelled SERVER\user.
        $result['UserName'] = '{0}\{1}' -f $result['Server'], $UserId
        $result['IsLocalAccount'] = $true
    } else {
        $result['UserName'] = '{0}\{1}' -f $UserDomain, $UserId
    }

    $result['Credential'] = New-Object -TypeName System.Management.Automation.PSCredential `
        -ArgumentList ([string] $result['UserName']), $Password

    # -- 3. prove it --------------------------------------------------------

    $provider = $ContentProvider
    if ($null -eq $provider) {
        $providerArgument = @{
            Provider   = 'Smb'
            Root       = $DeployRoot
            Credential = $result['Credential']
        }
        if ($null -ne $FileSystem) { $providerArgument['FileSystem'] = $FileSystem }

        $provider = New-HDTContentProvider @providerArgument
    }

    try {
        [void] $provider.Connect()

        $result['Connected'] = $true
        $result['Message'] = ("Connected to {0} as {1}." -f $DeployRoot, $result['UserName'])
    } catch {
        $message = [string] $_.Exception.Message

        $result['Connected'] = $false
        $result['Message'] = $message

        # DESIGN 6.3's refusal, reported as what it is from the technician's
        # seat: an account problem, fixed on this page.
        if ($message -match 'HDTSecurityError' -or $message -match 'guest') {
            $result['GuestRefused'] = $true
        }
    } finally {
        # THE MAPPING THIS MADE IS A TEST, NOT THE DEPLOYMENT'S.
        try { [void] $provider.Disconnect() } catch { $null = $_ }
    }

    return [pscustomobject] $result
}

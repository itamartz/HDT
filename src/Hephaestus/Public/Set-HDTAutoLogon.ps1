function Set-HDTAutoLogon {
    <#
        .SYNOPSIS
            Arms autologon for the next n reboots.

        .DESCRIPTION
            Writes, in this order, through the injected services:

              HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
                AutoAdminLogon    = '1'          String
                DefaultUserName   = -UserName    String
                DefaultDomainName = -DomainName  String  (empty for a workgroup)
                AutoLogonCount    = -RemainingLeg DWord
                DefaultPassword                  REMOVED, always

              LSA private data
                DefaultPassword   = -Password

              HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
                HDTResume         = -ResumeCommand String

            THE PASSWORD GOES TO LSA AND NOWHERE ELSE. Winlogon
            reads DefaultPassword from LSA private data as well as from the
            registry, so there is no plaintext in a hive that any local read can
            lift, in a registry backup, or in a captured image. SPIKES.md S7
            observed Windows itself doing exactly that, and S8 drove three real
            autologons with the registry DefaultPassword absent throughout - so
            this is the supported path and there is no registry fallback. The
            registry value is REMOVED rather than left alone, because an image or
            another tool may have put one there and the guarantee is about the
            machine, not about what this function wrote.

            The password never appears in a log record, a message, the state
            document or a report. Tests assert that by reading everything the
            filesystem was asked to write.

            -RemainingLeg IS LITERAL. SPIKES.md S8 observed Windows decrementing
            the count before handing the session over: armed at 3, the three
            autologged sessions read 2, 1 and 0, and the fourth boot did not
            autologon at all. So n buys exactly n more autologons, with no
            off-by-one. The caller computes it; 03-04 computes it as the number
            of Restart steps left plus one.

            ARMING TWICE LEAVES WHAT ARMING ONCE LEFT. Every write is a set, not
            an append, so a run that re-arms before each Restart step - which is
            what a multi-leg deployment requires, since RunOnce is consumed each leg -
            converges rather than accumulating.

            It updates -State but does NOT save it: the caller owns the write
            order, and 03-04 saves immediately afterwards.

        .PARAMETER Registry
            An IRegistryService.

        .PARAMETER Lsa
            An ILsaService.

        .PARAMETER UserName
            The account to autologon as. Normally the local Administrator.

        .PARAMETER Password
            That account's password, for this deployment only. Generate it with
            the HDTAdminPassword variable (DESIGN 4.5.2).

        .PARAMETER RemainingLeg
            How many more autologons are needed. At least 1.

        .PARAMETER DomainName
            The account's domain. Empty for a workgroup machine, which is what a
            machine mid-deployment normally is.

        .PARAMETER ResumeCommand
            What RunOnce launches at logon. Defaults to
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1

        .PARAMETER State
            The run state document. Its autoLogon block is updated in place.

        .PARAMETER LogContext
            A log context. One reboot.arm record is written when supplied.

        .OUTPUTS
            None.

        .EXAMPLE
            Set-HDTAutoLogon -Registry $registry -Lsa $lsa -UserName 'Administrator' `
                -Password $password -RemainingLeg 3 -State $state -LogContext $log

            Three more legs, the password only in LSA.
    #>
    # SecureString and PSCredential are declined here on purpose, and it is worth
    # writing down why rather than letting a future reader "fix" it.
    #
    # This password is a per-deployment throwaway that DESIGN 4.5.2 requires to
    # exist in cleartext in two places anyway - the LSA secret Winlogon reads,
    # and state.json on the machine being built. LsaStorePrivateData takes an
    # LSA_UNICODE_STRING, so a SecureString would be unwrapped to plaintext
    # inside this process on every call regardless. It would move the plaintext
    # around, not remove it, while making the whole path harder to test and
    # adding a marshalling step that behaves differently on the two engines.
    #
    # What actually protects this value is the design, not the type: it is
    # random per deployment, it never reaches the registry, the log, a report or
    # a recorded operation, and Clear-HDTAutoLogon deletes it. Those are the
    # properties the tests assert.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'DESIGN 4.5.2 stores this password as an LSA secret and in state.json in cleartext by design; a PSCredential would be unwrapped on every call and protects nothing here.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'LsaStorePrivateData takes an LSA_UNICODE_STRING, so a SecureString would be converted back to plaintext in this process anyway. See the comment above the param block.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Registry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Password,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $RemainingLeg,

        [Parameter()]
        [AllowEmptyString()]
        [string] $DomainName = '',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ResumeCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1',

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $secretName = 'DefaultPassword'
    $runOnceName = 'HDTResume'

    if (-not $PSCmdlet.ShouldProcess($winlogonPath, ("Arm autologon for {0} for {1} leg(s)" -f $UserName, $RemainingLeg))) {
        return
    }

    $Registry.SetValue($winlogonPath, 'AutoAdminLogon', '1', 'String')
    $Registry.SetValue($winlogonPath, 'DefaultUserName', $UserName, 'String')
    $Registry.SetValue($winlogonPath, 'DefaultDomainName', $DomainName, 'String')
    $Registry.SetValue($winlogonPath, 'AutoLogonCount', $RemainingLeg, 'DWord')

    # Unconditional and idempotent. Whatever left one there, it is not going to
    # be there when this returns.
    $Registry.RemoveValue($winlogonPath, $secretName)

    $Lsa.SetSecret($secretName, $Password)

    $Registry.SetValue($runOncePath, $runOnceName, $ResumeCommand, 'String')

    if ($null -ne $State) {
        $State.autoLogon.armed = $true
        $State.autoLogon.userName = $UserName
        $State.autoLogon.domainName = $DomainName
        $State.autoLogon.countSet = $RemainingLeg
        $State.autoLogon.secretName = $secretName
        $State.autoLogon.runOnceName = $runOnceName
    }

    if ($null -ne $LogContext) {
        # The user name and the count. Not the password, not the secret, not a
        # hash of either.
        Write-HDTLog -Context $LogContext -Event 'reboot.arm' `
            -Message ("Autologon armed for {0} for {1} more leg(s)" -f $UserName, $RemainingLeg) `
            -Data ([ordered] @{
                userName    = $UserName
                domainName  = $DomainName
                count       = $RemainingLeg
                secretName  = $secretName
                runOnceName = $runOnceName
            })
    }
}

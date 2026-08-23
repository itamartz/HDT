function Test-HDTElevation {
    <#
        .SYNOPSIS
            Whether this process is running as an administrator.

        .DESCRIPTION
            A THIN ADAPTER OVER THE TOKEN, and deliberately branch-free: it asks
            Windows one question and answers it. Anything that DECIDES something
            from the answer takes it as a parameter, so the decision stays
            testable without a second process and a UAC prompt.

            WHAT IT IS FOR. Publishing an SMB share needs elevation, and without
            it New-SmbShare fails inside the SmbShare module with an access
            error naming a CIM class - a sentence that tells a technician
            nothing about reopening the console. Asked first, the refusal can
            say what to do.

            IT IS NOT A SECURITY CHECK. It reports what this token is, which is
            a fact about the session, not a permission being enforced: anything
            that matters is still enforced by Windows when the call is made.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTElevation

            Whether this session can do the things a deployment needs - mount an
            image, write an LSA secret, partition a disk.

        .EXAMPLE
            if (-not (Test-HDTElevation)) { 'Reopen this console as an administrator.' }

            Asked before the work rather than during it. A DISM call that fails halfway
            through leaves a mounted image behind.

    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity

    return [bool] $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

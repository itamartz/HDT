function Set-HDTShareCredential {
    <#
        .SYNOPSIS
            Writes the deployment account credential a boot image will carry.

        .DESCRIPTION
            THE ONLY WRITER OF THE DEPLOYMENT SECRET. It writes
            Control\share-credential.json inside the workspace, and 05-01 made a
            password: key in workspace.yaml a validation error that names this
            command - because workspace.yaml is the document an administrator
            hand-edits and commits, and a secret in it ends up in git.

            THE STORED VALUE IS OBFUSCATED AND IS NOT CLAIMED TO BE SECURE, and
            the file says so itself: it carries a 'warning' field whose sentence
            states that anyone who can read this file or the boot image can
            recover the password. DESIGN 6.3 - "obfuscation is not claimed as
            security ... the docs say so plainly rather than implying the image
            is safe to hand out". docs/share-account.md says it again in prose,
            with the least-privilege setup that makes the account worth as
            little as possible.

            IT IS NOT DPAPI. DPAPI is user- and machine-bound, and this file has
            to be readable inside WinPE on a machine that has never seen the one
            that wrote it - which is the whole reason the credential is embedded
            at all.

            The path is built with Get-HDTWorkspacePath, never a literal: the
            layout in DESIGN 2.1 is written down in exactly one place, and
            Start-HDTResume once built a path from the literal 'Sequences' while
            everything else said 'TaskSequences'.

            It carries SupportsShouldProcess because it overwrites a secret.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Credential
            The deployment account. Its password must not be empty: an empty
            password is an anonymous logon, which is what
            New-HDTSmbContentProvider refuses at Connect.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. A cmdlet that echoed the credential would put it in a
            transcript.

        .EXAMPLE
            Set-HDTShareCredential -WorkspaceRoot '\\server\HdtShare' -Credential (Get-Credential)

        .EXAMPLE
            Set-HDTShareCredential -WorkspaceRoot 'C:\HDTLab\Share' -Credential $credential -WhatIf

            What it would overwrite, without overwriting it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscredential] $Credential,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) {
        $FileSystem = New-HDTFileSystem
    }

    $path = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Control -ChildPath 'share-credential.json'

    $plain = [string] $Credential.GetNetworkCredential().Password

    if ([string]::IsNullOrEmpty($plain)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the credential for '{0}' has an empty password. An empty password is an anonymous logon, and the Smb content provider refuses one at Connect (DESIGN 6.3)." -f $Credential.UserName)))
    }

    $document = [ordered] @{
        schemaVersion = 1
        username      = [string] $Credential.UserName
        password      = (Protect-HDTShareSecret -Secret $plain)
        warning       = 'This password is obfuscated, not encrypted: the key is a constant in the Hephaestus module, so anyone who can read this file - or the boot image, the ISO or the Boot folder that carry it - can recover the password. Treat all of them as credentials, and keep the account least-privileged (DESIGN 6.3, docs/share-account.md).'
    }

    # ConvertTo-Json, then IFileSystem: the adapter writes UTF-8 with no BOM on
    # both engines, which Set-Content does not (tests/helpers/README.md F11).
    $text = ConvertTo-Json -InputObject $document -Depth 3

    if (-not $PSCmdlet.ShouldProcess($path, ("Write the deployment credential for '{0}'" -f $Credential.UserName))) {
        return
    }

    $FileSystem.WriteAllText($path, $text)
}

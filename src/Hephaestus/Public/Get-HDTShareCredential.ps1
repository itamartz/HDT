function Get-HDTShareCredential {
    <#
        .SYNOPSIS
            Reads the deployment account credential back out of the workspace.

        .DESCRIPTION
            The read half of DESIGN 6.3's embedded credential. It is what runs
            inside WinPE: the booted machine reads
            Control\share-credential.json out of the boot image or the share,
            recovers the password, and hands it to
            New-HDTSmbContentProvider.

            It reads through an injected IFileSystem, never Get-Content, so the
            whole path is provable under Pester with no share and no boot image.

            A missing file is an HDTConfigurationError naming the file AND the
            command that writes it, because "no credential" is the single most
            likely reason a PXE-booted machine cannot reach its share.

            THE PASSWORD IT RETURNS IS PLAIN TEXT. That is what New-SmbMapping
            takes, and DESIGN 6.3 is explicit that the value is recoverable by
            anyone holding the boot image; wrapping it in a SecureString here
            would unwrap one call later and protect nothing.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with UserName and
            Password.

        .EXAMPLE
            $secret = Get-HDTShareCredential -WorkspaceRoot 'X:\Deploy'
            $secret.UserName

        .EXAMPLE
            $secret = Get-HDTShareCredential -WorkspaceRoot $root -FileSystem $fs
            $secure = New-Object System.Security.SecureString
            foreach ($character in $secret.Password.ToCharArray()) { $secure.AppendChar($character) }
            $credential = New-Object System.Management.Automation.PSCredential $secret.UserName, $secure

            The shape New-HDTSmbContentProvider -Credential takes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

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

    if (-not $FileSystem.TestPath($path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'there is no deployment credential in this workspace. Write one with Set-HDTShareCredential; a booted machine has no other way to authenticate to the share (DESIGN 6.3).' `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($path)

    try {
        # Assigned first, wrapped second: under Windows PowerShell 5.1
        # ConvertFrom-Json does not enumerate a top-level array (README F12).
        $document = ConvertFrom-Json -InputObject $text
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the deployment credential could not be read as JSON: {0}. Rewrite it with Set-HDTShareCredential." -f $_.Exception.Message)))
    }

    $userName = ''
    $protected = ''
    if ($null -ne $document.PSObject.Properties['username']) { $userName = [string] $document.username }
    if ($null -ne $document.PSObject.Properties['password']) { $protected = [string] $document.password }

    if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($protected)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the deployment credential is missing its username or its password. Rewrite it with Set-HDTShareCredential.'))
    }

    try {
        $plain = Unprotect-HDTShareSecret -Protected $protected
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the deployment credential could not be decoded: {0}. Rewrite it with Set-HDTShareCredential." -f $_.Exception.Message)))
    }

    return [pscustomobject] @{
        UserName = $userName
        Password = $plain
    }
}

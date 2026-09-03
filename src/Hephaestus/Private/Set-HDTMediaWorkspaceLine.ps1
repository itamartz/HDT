function Set-HDTMediaWorkspaceLine {
    <#
        .SYNOPSIS
            The provider swap: deployRoot becomes \Share and the credential block
            goes, spliced into the lines rather than re-serialised.

        .DESCRIPTION
            DESIGN 6.2 calls media generation "a content projection plus a
            provider swap". Get-HDTMediaProjection is the projection;
            this is the swap, and it is two edits to one file.

            THE PROVIDER IS DERIVED, NOT CONFIGURED, and that is the whole trick.
            Update-HDTBootImage reads:

                $provider = 'Local'
                if (([string] $workspace.DeployRoot).StartsWith('\\')) { $provider = 'Smb' }

            So a projected workspace.yaml carrying deployRoot \Share produces a
            Local boot image and NOTHING ELSE HAS TO KNOW. There is no media flag
            threaded through the builder, no second code path, and no place for
            the two to disagree.

            \Share, AND DELIBERATELY NOT A DRIVE LETTER. The volume-relative form
            is the only one a Local boot image may carry - Assert-HDTWorkspaceDocument
            says so in its own header, because a lab test recorded WinPE handing
            the content disk C: while the RAM disk was X:. The letter the disc
            lands on is the one value that is certainly wrong at build time, so
            the volume is discovered at boot instead, by Resolve-HDTDeployRoot
            probing every ready drive for rules.yaml.

            THE CREDENTIAL BLOCK GOES BECAUSE A LOCAL IMAGE AUTHENTICATES TO
            NOTHING. There is no share to reach and no account to reach it with,
            and a disc is handed around - DESIGN 6.3 treats boot media as a
            credential in itself. Removing the whole block rather than its
            username matters: a credential: holding nothing parses as a null and
            the engine refuses a workspace whose credential is not a mapping, so
            the husk would be a disc that cannot be read at all.
            Set-HDTWorkspaceKey removes the block with the key, which is exactly
            the behaviour its own header records.

            IT SPLICES, SO THE COMMENTS REACH THE DISC. Both edits go through
            Set-HDTWorkspaceKey and nothing is re-serialised, because parsing and
            rewriting a YAML document loses every comment in it - and those
            comments are somebody's notes about the share they are handing out.

        .PARAMETER Line
            The workspace document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the projected document.

        .EXAMPLE
            $projected = Set-HDTMediaWorkspaceLine -Line ($text -split "`r?`n")

        .LINK
            Set-HDTWorkspaceKey
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a copy of in-memory lines. Update-HDTMediaContent is what writes, under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NO SECOND SPLICER. Set-HDTWorkspaceKey already replaces, inserts and
    # removes, and already takes the block away with the key it emptied.
    $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('deployRoot') -Text @('deployRoot: \Share'))

    return [string[]] @(Set-HDTWorkspaceKey -Line $result -Path @('credential') -Text @())
}

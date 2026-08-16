function New-HDTFileSystemFromText {
    <#
        .SYNOPSIS
            An IFileSystem holding one document that exists only in memory.

        .DESCRIPTION
            WHAT LETS SAVE CHECK BEFORE IT WRITES. Import-HDTSequenceDocument
            reads through an IFileSystem, so handing it one whose only file is
            the edited text means the ENGINE'S OWN READER passes judgement on a
            document that is not on the share yet. A splice that produced
            something unreadable then fails in the editor with the file intact,
            rather than after it has been overwritten.

            THE PATH IS THE REAL ONE, so any error the engine raises names the
            file the administrator is actually editing rather than a temporary
            one they have never heard of.

            IT IS NOT A TEST FAKE. tests/helpers is not shipped, and the
            product cannot depend on it; this is a two-method adapter over a
            string, and it is branch-free for the same reason the other
            adapters are.

        .PARAMETER Path
            The path the text should appear at.

        .PARAMETER Text
            The document.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            An object with TestPath and ReadAllText.

        .EXAMPLE
            $fs = New-HDTFileSystemFromText -Path $path -Text $text
            Import-HDTSequenceDocument -Path $path -FileSystem $fs
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Text
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        DocumentPath = $Path
        DocumentText = $Text
    }

    Add-Member -InputObject $service -MemberType ScriptMethod -Name 'TestPath' -Value {
        param([string] $Path)

        return ([string] $Path -eq [string] $this.DocumentPath)
    }

    # IT ANSWERS FOR ONE PATH AND REFUSES EVERY OTHER. Returning the document
    # whatever was asked for would make a caller that read the wrong file look
    # like it had read the right one.
    Add-Member -InputObject $service -MemberType ScriptMethod -Name 'ReadAllText' -Value {
        param([string] $Path)

        if ([string] $Path -ne [string] $this.DocumentPath) {
            throw ("this reader holds only '{0}', and '{1}' was asked for." -f $this.DocumentPath, $Path)
        }

        return [string] $this.DocumentText
    }

    return $service
}

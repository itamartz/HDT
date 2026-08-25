function ConvertTo-HDTSelectionProfileId {
    <#
        .SYNOPSIS
            A profile id derived from the name an administrator typed.

        .DESCRIPTION
            A PROFILE HAS TWO NAMES AND ONLY ONE OF THEM IS TYPED. The window
            shows 'Boot critical - Dell and HP'; workspace.yaml references
            'boot-critical-dell-and-hp'. Asking for both would be asking an
            administrator to invent a slug, which is a field people leave wrong.

            THE ID IS WHAT A DOCUMENT CARRIES, so it has to survive
            Assert-HDTSelectionProfileDocument's pattern -
            ^[A-Za-z0-9][A-Za-z0-9_.-]*$ - which is why everything else becomes a
            dash and why a leading one is trimmed. It is also lower-cased: an id
            is compared, and two profiles differing only in case would be two
            rows an administrator cannot tell apart.

            A NAME WITH NOTHING USABLE IN IT ANSWERS EMPTY rather than inventing
            something. The caller refuses the click and says so; a generated
            'profile-1' would be a name nobody chose appearing in their document.

            IT DOES NOT CHECK FOR COLLISIONS. New-HDTSelectionProfile already
            refuses an id the document declares and one a built-in owns, and
            two places deciding that is two places to disagree.

        .PARAMETER Name
            What the administrator typed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the id, or an empty string.

        .EXAMPLE
            ConvertTo-HDTSelectionProfileId -Name 'Boot critical - Dell and HP'

            boot-critical-dell-and-hp

        .EXAMPLE
            ConvertTo-HDTSelectionProfileId -Name '???'

            An empty string - there is nothing in that a document could carry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $text = $Name.ToLowerInvariant()

    # Anything the id pattern will not take becomes a dash, and a run of them
    # collapses - 'Dell  /  HP' is one separator, not four.
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, '[^a-z0-9]+', '-')
    $text = $text.Trim('-')

    # The pattern demands a letter or a digit FIRST, and the trim above has
    # already guaranteed it for anything that is left.
    if ($text -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { return '' }

    return $text
}

function ConvertTo-HDTHtmlText {
    <#
        .SYNOPSIS
            Escapes one value for inclusion in the HTML report's text or an
            attribute.

        .DESCRIPTION
            Everything ConvertTo-HDTReport renders goes through here, because
            everything it renders is untrusted in the only sense that matters:
            it came from a machine being deployed. A step message routinely
            carries a command line with an ampersand, an unattend fragment with
            angle brackets, or a quoted argument with both kinds of quote - and a
            report that renders those raw either swallows the line the technician
            opened it for, or renders a machine-supplied string as markup.

            THE AMPERSAND GOES FIRST, and that ordering is the whole function.
            Escaping & after < would turn the &lt; just produced into &amp;lt;,
            which is the classic double-escape bug and reads as literal '&lt;' on
            the page.

            Both quotes are escaped as well as the three structural characters,
            so one function serves text nodes and attribute values alike rather
            than leaving the caller to choose - a caller that chooses wrongly
            once is an injected attribute.

            The function is pure. It has no clock, no filesystem and no state,
            and $null renders as the empty string rather than 'null', because a
            report cell for a step that has no exit code should be empty.

        .PARAMETER Value
            Anything. A non-string is rendered with ToString first, so an int
            exit code and a [datetime] both work without the caller casting.

        .OUTPUTS
            System.String

        .EXAMPLE
            ConvertTo-HDTHtmlText -Value 'cmd.exe /c echo "a<b" & echo done'

            cmd.exe /c echo &quot;a&lt;b&quot; &amp; echo done
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Value) {
        return ''
    }

    # A LIST IS COMMA DELIMITED BEFORE IT IS ESCAPED, because a [string] cast
    # SPACE-joins one ($OFS) and the report would then disagree with the log
    # line and the %Var% substitution about what a multi-valued variable is.
    # Here rather than at the one call site that has an array today, so the next
    # array-valued fact cannot regress the report by being added. Scalars are
    # untouched: a timestamp keeps rendering exactly as it did.
    if (($Value -is [System.Collections.IList]) -and -not ($Value -is [string])) {
        $text = ConvertTo-HDTVariableText -Value $Value
    } else {
        $text = [string] $Value
    }

    # & FIRST. See the description.
    $text = $text.Replace('&', '&amp;')
    $text = $text.Replace('<', '&lt;')
    $text = $text.Replace('>', '&gt;')
    $text = $text.Replace('"', '&quot;')
    $text = $text.Replace("'", '&#39;')

    return $text
}

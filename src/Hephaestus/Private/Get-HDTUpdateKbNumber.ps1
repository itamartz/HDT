function Get-HDTUpdateKbNumber {
    <#
        .SYNOPSIS
            The KB numbers an update carries, normalised to KB#####.

        .DESCRIPTION
            THE ONE PLACE THE AGENT'S SPELLING AND A HUMAN'S MEET. WUA returns
            IUpdate.KBArticleIDs WITHOUT the prefix - '5121003', not
            'KB5121003' - because the prefix is a documentation convention and
            not part of the article id. Humans write it WITH one, every support
            article is titled with one, and DESIGN 10.1's own example exclude
            list mixes '*Preview*' and 'KB5001234' in the same array.

            Normalising in one place is what lets the step's log, its Data
            payload and its exclude matching all say the same thing about the
            same update. Normalising at three call sites is how two of them
            end up disagreeing.

            AND THE TITLE IS THE FALLBACK, BECAUSE KBArticleIDs IS EMPTY MORE
            OFTEN THAN ITS DOCUMENTATION SUGGESTS. Driver updates routinely
            carry none; some third-party catalogue entries carry none; a WSUS
            server publishing a local update carries none. The title almost
            always ends in '(KB#######)' anyway, because that is how the
            catalogue names things, so it is read only when the agent supplied
            nothing - a title-derived number is a guess and the reported one
            never is. A log line that cannot name a KB is a line an
            administrator cannot search a support article with, which is the
            whole reason the fallback exists.

            The order is the order the agent reported, because an update that
            carries several lists the one it is actually named after first.

        .PARAMETER Update
            One update row from IUpdateSessionService.SearchUpdate: Title and
            KBArticleId are the fields read.

        .OUTPUTS
            System.String[] - KB#####, uppercase, possibly empty.

        .EXAMPLE
            Get-HDTUpdateKbNumber -Update $update

            KB5121003, from an agent that reported '5121003'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Update
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $number = New-Object -TypeName System.Collections.ArrayList

    $reported = @()
    $property = $Update.PSObject.Properties['KBArticleId']
    if ($null -ne $property -and $null -ne $property.Value) {
        $reported = @($property.Value)
    }

    foreach ($current in $reported) {
        $text = ([string] $current).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        # 'kb5121003', 'KB5121003' and '5121003' are the same article, and all
        # three are written in the field by somebody.
        if ($text -match '^(?:[Kk][Bb])?\s*(\d+)$') {
            [void] $number.Add('KB' + $Matches[1])
        }
    }

    if ($number.Count -gt 0) {
        return [string[]] @($number)
    }

    $title = ''
    $titleProperty = $Update.PSObject.Properties['Title']
    if ($null -ne $titleProperty -and $null -ne $titleProperty.Value) {
        $title = [string] $titleProperty.Value
    }

    foreach ($match in ([regex]::Matches($title, '(?i)\bKB\s*(\d+)\b'))) {
        $candidate = 'KB' + $match.Groups[1].Value
        if (-not ($number -contains $candidate)) { [void] $number.Add($candidate) }
    }

    return [string[]] @($number)
}

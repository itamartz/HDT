function Get-HDTConsoleRuleSetting {
    <#
        .SYNOPSIS
            Works out what the Rules tab of the Windows PE window shows for a
            rules document.

        .DESCRIPTION
            MDT PUT CustomSettings.ini ON THE DEPLOYMENT SHARE'S PROPERTIES, in a
            tab called Rules, as text edited in place. HDT's equivalent is
            rules.yaml and it goes in the same place - the window that is
            Deployment Workbench's share Properties - because that is where an
            administrator coming from MDT will look for it.

            TEXT, NOT A GRID, AND THAT IS THE HOMAGE. Add-HDTRule, Set-HDTRule
            and Remove-HDTRule exist, and a grid could be built on them. But
            rules.yaml is walked top to bottom with a set: taking effect only if
            the variable is not already resolved - first match wins per variable
            - so the ORDER of the rules and the comments explaining that order
            are the document's meaning. A grid would hide the one thing the
            administrator is reasoning about.

            IT VALIDATES BEFORE IT SAVES, which the .ini never could.
            Assert-HDTRuleLine is the same gate Add-HDTRule passes through, so a
            document WinPE would refuse at three in the morning is refused here,
            at the desk, in the same words.

            IT NEVER THROWS ON A BAD DOCUMENT. A tab that throws on open leaves
            an administrator looking at a file they can neither see nor fix - and
            a broken rules.yaml is exactly when they need to see it. The problem
            comes back as text for the window to show, with IsValid false so the
            Save button can be dark.

        .PARAMETER Line
            The rules.yaml document, as lines. Empty for a share that has none.

        .PARAMETER Bootstrap
            Judge it as bootstrap-rules.yaml rather than rules.yaml: the same
            grammar, but only the handful of variables a machine with no share
            can act on. THE SAME JUDGEMENT Update-HDTBootImage makes when it
            injects the file, rather than a second opinion the window invented.

        .PARAMETER Path
            Where the document lives. Carried through to the save command; this
            function reads nothing.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

              Text         the whole document, for the editor
              Path         where it came from
              RuleName     the rule names, in document order
              SummaryText  '4 rules', or why there are none
              Problem      the engine's refusal, or ''
              IsValid      whether Save may be offered
              SaveCommand  what Save runs

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\rules.yaml'
            Get-HDTConsoleRuleSetting -Line $line -Path 'C:\HDTLab\Share\rules.yaml'

        .LINK
            Save-HDTRuleDocument

        .LINK
            Add-HDTRule
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [switch] $Bootstrap
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # CRLF, because that is what Save-HDTRuleDocument writes and what a WPF
    # TextBox produces. Joining on "`n" here would make every save look like a
    # whole-file change to git the first time somebody touched one line.
    $text = ($Line -join "`r`n")

    $problem = ''
    $ruleName = @()

    if (@($Line).Count -eq 0) {
        return [pscustomobject] @{
            Text        = $text
            Path        = $Path
            RuleName    = [string[]] @()
            SummaryText = 'no rules yet - a document starts with schemaVersion: 1 and a rules: list'
            Problem     = ''
            IsValid     = $false
            SaveCommand = "Save-HDTRuleDocument -Path '$Path' -Line `$line"
        }
    }

    try {
        Assert-HDTRuleLine -Line $Line

        # THE VOCABULARY, SECOND, AND ONLY WHEN ASKED. The grammar has to be
        # right before the allow-list can say anything useful about the names in
        # it - a document that will not parse has no set: keys to judge.
        if ($Bootstrap) {
            Assert-HDTBootstrapRuleDocument `
                -Document (ConvertFrom-HDTRuleYaml -Yaml ($Line -join "`r`n") -Path $Path) `
                -Path $Path
        }

        $ruleName = @(Get-HDTRuleBlock -Line $Line | ForEach-Object { [string] $_.Name })
    } catch {
        $problem = [string] $_.Exception.Message
    }

    if ($problem) {
        $summary = 'not a rules document yet'
    } elseif ($ruleName.Count -eq 1) {
        $summary = '1 rule'
    } else {
        $summary = '{0} rules' -f $ruleName.Count
    }

    return [pscustomobject] @{
        Text        = $text
        Path        = $Path
        RuleName    = [string[]] $ruleName
        SummaryText = $summary
        Problem     = $problem
        IsValid     = [bool] (-not $problem)
        SaveCommand = "Save-HDTRuleDocument -Path '$Path' -Line `$line"
    }
}

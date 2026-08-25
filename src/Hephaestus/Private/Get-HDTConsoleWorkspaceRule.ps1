function Get-HDTConsoleWorkspaceRule {
    <#
        .SYNOPSIS
            Whether a share's rules.yaml would parse, as the share's own row
            reports it.

        .DESCRIPTION
            DESIGN 12: "Validation: the same JSON Schemas the cmdlets use,
            surfaced inline." rules.yaml was the one document on a share that
            surfaced nowhere in the tree. Its per-keystroke validation has always
            existed - in the Windows PE window's Rules tab, through
            Get-HDTConsoleRuleSetting - and that is the only place it existed, so
            a share whose rules would not parse looked healthy in the browser
            until somebody opened that tab for an unrelated reason.

            IT IS THE SHARE'S DOCUMENT, NOT A CATEGORY'S. rules.yaml is what
            CustomSettings.ini was: every deployment from this share resolves
            through it, so one that will not parse breaks all of them rather than
            one task sequence. That is why the answer belongs on the share row.

            THE JUDGEMENT IS Get-HDTConsoleRuleSetting'S, WHICH IS THE ENGINE'S.
            A second opinion written here could disagree with the box a person
            types into, and the disagreement would be invisible: the tree would
            say broken and the editor would offer Save. One judge, two readers.

            ABSENT IS NOT BROKEN. A share with no rules.yaml deploys - every
            variable falls to its default - so it is a share nobody has
            configured, not a damaged one. Drawing it red would put a mark on
            every new share there is, and a console where the normal case is red
            is one where red stops meaning anything.

        .PARAMETER Root
            The share's root. rules.yaml sits beside workspace.yaml.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Path      where it looked
              Status    'Ok', 'Error' or 'Missing'
              Summary   how many rules, or why there are none
              Problem   the engine's refusal, or ''

        .EXAMPLE
            Get-HDTConsoleWorkspaceRule -Root 'C:\HDTLab\Share'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $rulePath = [System.IO.Path]::Combine($Root, 'rules.yaml')

    if (-not $FileSystem.TestPath($rulePath)) {
        return [pscustomobject] @{
            Path    = $rulePath
            Status  = 'Missing'
            Summary = 'no rules yet - every variable falls to its default'
            Problem = ''
        }
    }

    $line = @([string] $FileSystem.ReadAllText($rulePath) -split "`r?`n")

    # THE SAME CALL THE RULES TAB MAKES, with the same arguments. Bootstrap is
    # false: bootstrap-rules.yaml is a different file with a narrower grammar,
    # and it lives in the boot image rather than on the share.
    $judged = Get-HDTConsoleRuleSetting -Line $line -Path $rulePath -Bootstrap:$false

    $status = 'Ok'
    if (-not [string]::IsNullOrWhiteSpace([string] $judged.Problem)) { $status = 'Error' }

    return [pscustomobject] @{
        Path    = $rulePath
        Status  = $status
        Summary = [string] $judged.SummaryText
        Problem = [string] $judged.Problem
    }
}

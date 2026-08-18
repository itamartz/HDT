function Get-HDTWorkspaceFolderKey {
    <#
        .SYNOPSIS
            The workspace.yaml key a console category's folders are listed under.

        .DESCRIPTION
            ONE PLACE THE TWO SPELLINGS MEET. The commands take a category the
            way the rest of the module names it - TaskSequence, singular, as in
            Set-HDTTaskSequenceProperty - and the document lists it the way YAML
            keys are written here, taskSequences, plural and camel. A second copy
            of that mapping is a second place for them to disagree.

        .PARAMETER Category
            The category, as the commands name it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTWorkspaceFolderKey -Category TaskSequence
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application')]
        [string] $Category
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $key = @{
        TaskSequence    = 'taskSequences'
        OperatingSystem = 'operatingSystems'
        Application     = 'applications'
    }

    return [string] $key[$Category]
}

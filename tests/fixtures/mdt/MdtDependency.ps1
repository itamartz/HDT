# Bait fixture: six MDT dependencies, one per line, each of a different kind.
# tests/fixtures is excluded from Get-HDTSourceFile, so none of this reaches the
# no-MDT contract that scans the real repository.

function Get-HDTMdtBaitSample {
    Import-Module MicrosoftDeploymentToolkit
    New-PSDrive -Name DS001 -PSProvider MDTProvider -Root 'C:\DeploymentShare'
    $ts = New-Object Microsoft.BDD.TaskSequenceModule
    & "$PSScriptRoot\ZTIGather.wsf"
    Get-MDTDeploymentShare
    Get-Content 'Control\ts.xml'
    Write-Output $ts
}

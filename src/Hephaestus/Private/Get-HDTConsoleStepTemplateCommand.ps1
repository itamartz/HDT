function Get-HDTConsoleStepTemplateCommand {
    <#
        .SYNOPSIS
            The command that writes a new step of this type, or $null if the
            engine cannot author one.

        .DESCRIPTION
            ONE PLACE ANSWERS "CAN THIS BE ADDED?", so the menu and the buttons
            behind it cannot disagree. The answer is the engine's: a step type is
            creatable exactly when it exports Get-HDT<Type>StepTemplate, which
            Get-HDTStepType reports as CanAdd.

            IT ALSO ACCEPTS A ROW THAT PREDATES THAT COLUMN. Callers hand
            Get-HDTConsoleStepCatalog a registry to test it against, and such a
            row may carry nothing but Type and Source. Rather than fail on the
            missing member under Set-StrictMode, the type name is resolved
            against the session - which is the same lookup Get-HDTStepType did,
            and gives the same answer.

        .PARAMETER StepType
            One row from Get-HDTStepType, or anything carrying a Type.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.CommandInfo, or $null.

        .EXAMPLE
            Get-HDTConsoleStepTemplateCommand -StepType (Get-HDTStepType -Name NoOp)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($StepType.PSObject.Properties.Name -contains 'TemplateCommand') {
        return $StepType.TemplateCommand
    }

    $name = 'Get-HDT{0}StepTemplate' -f [string] $StepType.Type

    return (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue |
            Select-Object -First 1)
}

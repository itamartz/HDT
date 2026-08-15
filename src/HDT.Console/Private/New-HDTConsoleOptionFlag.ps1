function New-HDTConsoleOptionFlag {
    <#
        .SYNOPSIS
            One checkbox row on the editor's Options tab.

        .DESCRIPTION
            The counterpart to New-HDTConsoleField, for the tab where a row is a
            state and a press rather than a label and a value. Written once
            because the two boxes differ only in their wording, and a second
            hand-built row is how the two commands drift apart.

            THE COMMAND IS THE PRESS, NOT THE STATE. Value is the opposite of
            Checked, because a checkbox offers to change what it shows - see
            Get-HDTConsoleStepOption.

        .PARAMETER Label
            The wording beside the box.

        .PARAMETER Property
            The flag Set-HDTConsoleStepFlag names.

        .PARAMETER Checked
            What the file currently says.

        .PARAMETER Name
            The step or group the command would act on.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Label, Property,
            Checked and Command.

        .EXAMPLE
            New-HDTConsoleOptionFlag -Label 'Disable this step' -Property 'Disabled' -Checked $false -Name 'Apply OS'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds one row of a display model in memory. Set-HDTConsoleStepFlag is what the row''s command would run, and that one carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Label,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Disabled', 'ContinueOnError')]
        [string] $Property,

        [Parameter(Mandatory = $true, Position = 2)]
        [bool] $Checked,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyString()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $value = '$true'
    if ($Checked) { $value = '$false' }

    return [pscustomobject] @{
        Label    = $Label
        Property = $Property
        Checked  = $Checked
        Command  = ("Set-HDTConsoleStepFlag -Line `$line -Name '{0}' -Flag {1} -Value {2}" -f $Name, $Property, $value)
    }
}

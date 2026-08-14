function New-HDTConsoleErrorRecord {
    <#
        .SYNOPSIS
            Builds the ErrorRecord the console throws when it is pointed at
            something that is not a deployment share.

        .DESCRIPTION
            The engine's New-HDTErrorRecord is private to Hephaestus and is not
            exported, so the console cannot call it. This is the same shape,
            deliberately - "{Path}: {Message}", -Path as the TargetObject, the
            HDTConfigurationError id - so a caller that already handles the
            engine's configuration failures handles the console's without
            learning a second convention.

            Callers throw it with $PSCmdlet.ThrowTerminatingError(), never with
            `throw "message"`: a bare string throw discards the error id and the
            target object, which are what let a wrapper recover WHICH file was at
            fault without parsing prose.

        .PARAMETER Message
            The sentence an administrator reads, without the file prefix.

        .PARAMETER Path
            The file or folder at fault. Becomes both the message prefix and the
            TargetObject.

        .PARAMETER ErrorId
            The error id. Defaults to HDTConfigurationError.

        .PARAMETER Category
            The ErrorCategory. Defaults to InvalidData.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.ErrorRecord

        .EXAMPLE
            $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -Message 'there is no workspace document here.' -Path $path))
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an ErrorRecord object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ErrorId = 'HDTConfigurationError',

        [Parameter()]
        [System.Management.Automation.ErrorCategory] $Category = [System.Management.Automation.ErrorCategory]::InvalidData
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = $Message
    $target = $null

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $text = '{0}: {1}' -f $Path, $Message
        $target = $Path
    }

    $exception = New-Object -TypeName System.Exception -ArgumentList $text

    return (New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $exception, $ErrorId, $Category, $target)
}

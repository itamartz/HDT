function New-HDTErrorRecord {
    <#
        .SYNOPSIS
            Builds the ErrorRecord every HDT configuration failure is thrown as.

        .DESCRIPTION
            DESIGN 12.1 classifies a failure as Transient, Configuration or
            Environment, and requires a Configuration failure to fail fast and
            point at the file and the line. This builds that record so every
            caller produces the same shape:

              with -Path and -Line : "{Path}({Line}): {Message}"
              with -Path only      : "{Path}: {Message}"
              with neither         : "{Message}"

            -Path also becomes the TargetObject, so a log reader and the console
            can both recover which file was at fault without parsing prose.

            Callers throw it with $PSCmdlet.ThrowTerminatingError(), never with
            `throw "message"`: a bare string throw discards the error id and the
            target object, which are exactly what make a configuration failure
            greppable in a log and machine-readable by the console. Thrown that
            way the record's FullyQualifiedErrorId is
            "<ErrorId>,<FunctionName>", so 'HDTConfigurationError*' matches every
            one of them regardless of which function raised it.

            The line number is only available where the caller knows one. YAML
            parse errors carry a line; authoring-rule violations, which are
            detected after parsing, carry the offending rule instead - the object
            graph the parser returns has no line information on it.

        .PARAMETER Message
            The sentence an administrator reads, without the file prefix.

        .PARAMETER Path
            The file at fault. Becomes both the message prefix and the
            TargetObject.

        .PARAMETER Line
            The 1-based line at fault. Only used when -Path is supplied.

        .PARAMETER ErrorId
            The error id. Defaults to HDTConfigurationError; the dependency gate
            in ConvertFrom-HDTYaml uses HDTDependencyError.

        .PARAMETER Category
            The ErrorCategory. Defaults to InvalidData.

        .PARAMETER InnerException
            An exception to preserve underneath the one this record carries.
            Omitted where the underlying exception is a third-party type that
            must not escape the engine.

        .OUTPUTS
            System.Management.Automation.ErrorRecord

        .EXAMPLE
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Message 'schemaVersion is missing.' -Path $Path))

            The canonical call: fail fast, name the file, keep the error id.
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
        [int] $Line,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ErrorId = 'HDTConfigurationError',

        [Parameter()]
        [System.Management.Automation.ErrorCategory] $Category = [System.Management.Automation.ErrorCategory]::InvalidData,

        [Parameter()]
        [System.Exception] $InnerException
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = $Message
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if ($PSBoundParameters.ContainsKey('Line') -and $Line -gt 0) {
            $text = '{0}({1}): {2}' -f $Path, $Line, $Message
        } else {
            $text = '{0}: {1}' -f $Path, $Message
        }
    }

    if ($PSBoundParameters.ContainsKey('InnerException') -and $null -ne $InnerException) {
        $exception = New-Object -TypeName System.Exception -ArgumentList $text, $InnerException
    } else {
        $exception = New-Object -TypeName System.Exception -ArgumentList $text
    }

    $target = $null
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $target = $Path
    }

    return (New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $exception, $ErrorId, $Category, $target)
}

function Test-HDTApplicationDetection {
    <#
        .SYNOPSIS
            Answers whether an application's detection rule says it is already
            installed.

        .DESCRIPTION
            DESIGN 8's detection, and the reason an HDT sequence can be re-run
            over a machine without reinstalling everything on it - MDT has no
            first-class detection, so its reruns do.

            It runs entirely against injected services, so every rule type is
            provable under Pester with no registry, no disk and no installed
            software.

            NO RULE MEANS NOT DETECTED, WHICH MEANS INSTALL. A $null rule returns
            $false without asking any service anything. That is not a degenerate
            case: DESIGN 8 makes detect: optional, and an application that
            declares none installs every time the step reaches it. The engine
            never infers a rule, because a guessed rule that reports an
            application installed when it is not silently skips work the sequence
            asked for - which is worse than installing something twice.

            THE FOUR RULES

              msiProduct  the product code is a key under
                          CurrentVersion\Uninstall, in the native view OR in
                          WOW6432Node. Both, because a 32-bit MSI on a 64-bit
                          machine registers only under the second one and an
                          engine that looked at one view would reinstall it every
                          deployment. NOT Win32_Product: querying that class
                          triggers a consistency check that can silently
                          reconfigure every MSI on the machine, which is a real
                          way to break a build.

              file        the file is there, and - if the rule states a version -
                          the file's version is at least that one. THE VERSION IS
                          THE HALF THAT MATTERS: a path test alone reports
                          "installed" for a stale build the sequence exists to
                          replace. A rule stating no version does not read one.

              registry    the key exists; if the rule names a value, that value
                          is present; if it also states data, the data matches.
                          Each level is a narrowing, so "the key exists" is a
                          legitimate whole rule.

              script      the script's output is truthy. A SCRIPT THAT THROWS
                          REPORTS NOT INSTALLED rather than failing the
                          deployment: it was asked "is this here?" and could not
                          answer, which is the same outcome for the sequence as
                          answering no, and is not a reason to scrap an otherwise
                          good build.

            A RULE WHOSE SERVICE WAS NOT SUPPLIED THROWS. That is a wiring
            mistake in the engine rather than an application that is absent, and
            reporting it as "not installed" would reinstall the application on
            every single deployment while looking like it worked.

        .PARAMETER Detect
            The projected detection rule, as Get-HDTApplication returns it on an
            application's Detect property. $null - the application declares none -
            returns $false.

        .PARAMETER FileSystem
            An IFileSystem. Required by the file rule.

        .PARAMETER Registry
            An IRegistryService. Required by the msiProduct and registry rules.

        .PARAMETER ScriptInvoker
            An IScriptInvoker. Required by the script rule.

        .PARAMETER Variable
            The variable scope. Tokens in a path or a key are expanded through it,
            and it is what a detection script is handed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean. $true when the application is already installed.

        .EXAMPLE
            $fs = New-HDTFileSystem
            $registry = New-HDTRegistryService
            $app = @(Get-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share')[0]
            $context = [pscustomobject] @{ Variable = [ordered] @{} }
            Test-HDTApplicationDetection -Detect $app.Detect -Registry $registry

        .EXAMPLE
            if (-not (Test-HDTApplicationDetection -Detect $app.Detect -FileSystem $fs -Variable $context.Variable)) {
                # install it
            }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Detect,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Registry = $null,

        [Parameter()]
        [AllowNull()]
        [object] $ScriptInvoker = $null,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Detect) { return $false }

    # A property the rule did not declare reads as empty rather than throwing
    # under Set-StrictMode, so a hand-built rule object behaves like a projected
    # one.
    $read = {
        param($Name)

        if ($null -eq $Detect.PSObject.Properties[$Name]) { return '' }
        return [string] $Detect.$Name
    }

    $expand = {
        param([string] $Text)

        if ($null -eq $Variable) { return $Text }
        return [string] (Expand-HDTVariableToken -Value $Text -Scope $Variable)
    }

    $require = {
        param($Service, [string] $ServiceName, [string] $RuleType)

        if ($null -eq $Service) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("a {0} detection rule needs the {1} service, and none was supplied. This is a wiring mistake in the engine: reporting it as 'not installed' would reinstall the application on every deployment while looking like it worked." -f $RuleType, $ServiceName)))
        }
    }

    $type = & $read 'Type'

    switch ($type) {

        'msiProduct' {
            & $require $Registry 'Registry' 'msiProduct'

            $productCode = & $read 'ProductCode'

            # Native view first, then the 32-bit one. A 32-bit MSI on a 64-bit
            # machine appears only in the second.
            $uninstallRoot = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )

            foreach ($root in $uninstallRoot) {
                if ($Registry.TestPath(('{0}\{1}' -f $root, $productCode))) { return $true }
            }

            return $false
        }

        'file' {
            & $require $FileSystem 'FileSystem' 'file'

            $path = & $expand (& $read 'Path')

            if (-not $FileSystem.TestPath($path)) { return $false }

            $required = & $read 'Version'
            if ([string]::IsNullOrWhiteSpace($required)) { return $true }

            return ([version] $FileSystem.GetVersion($path) -ge [version] $required)
        }

        'registry' {
            & $require $Registry 'Registry' 'registry'

            $key = & $expand (& $read 'Key')

            if (-not $Registry.TestPath($key)) { return $false }

            $valueName = & $read 'Value'
            if ([string]::IsNullOrWhiteSpace($valueName)) { return $true }

            $data = $Registry.GetValue($key, $valueName)
            if ($null -eq $data) { return $false }

            $expected = & $read 'Data'
            if ([string]::IsNullOrWhiteSpace($expected)) { return $true }

            return ([string] $data -eq $expected)
        }

        'script' {
            & $require $ScriptInvoker 'ScriptInvoker' 'script'

            $scriptPath = & $read 'Path'

            $scope = $Variable
            if ($null -eq $scope) { $scope = @{} }

            try {
                $result = $ScriptInvoker.Invoke($scriptPath, $scope)
            } catch {
                # It was asked whether the application is here and could not
                # answer. That is not a reason to scrap the build.
                return $false
            }

            return [bool] $result
        }

        default {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("'{0}' is not a detection rule HDT can run. The types are msiProduct, file, registry, script." -f $type)))
        }
    }
}

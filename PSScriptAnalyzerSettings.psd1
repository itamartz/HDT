@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')
    ExcludeRules        = @()

    Rules               = @{
        # Second, independent layer of the PowerShell 5.1 constraint: this flags
        # PS7-only syntax such as ?? as an Error. The AST contract test in plan
        # 01-02 is the first layer.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}

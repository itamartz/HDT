function New-HDTCimProvider {
    <#
        .SYNOPSIS
            Creates the real ICimProvider adapter over Get-CimInstance.

        .DESCRIPTION
            The one place in HDT that calls Get-CimInstance. PROJECT constraint 4
            forbids engine logic from touching CIM directly, so Get-HDTMachineFact
            and everything after it receives this object and can be swapped for
            New-HDTFakeCimProvider in a test with no machine attached.

            Adapters stay branch-free because they are not unit tested
            (DESIGN 12.2.3). The two branches here are not logic: one dispatches
            the contract's two overloads, which a ScriptMethod must do positionally
            because it cannot be overloaded, and the other attaches the class name
            to an error message Get-CimInstance leaves out. Neither inspects data.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class. Classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03); a pscustomobject
            duck-types to the same contract, reloads cleanly, and behaves
            identically under pwsh 7 and Windows PowerShell 5.1.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with a GetInstance
            ScriptMethod. Note that Get-Member -MemberType Method does NOT list a
            ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $cim = New-HDTCimProvider
            $cim.GetInstance('Win32_ComputerSystem')[0].Model

            The one-argument form, which defaults to root/cimv2.

        .EXAMPLE
            $cim = New-HDTCimProvider
            $cim.GetInstance('root/cimv2/security/microsofttpm', 'Win32_Tpm')[0].SpecVersion

            The two-argument form, which fact gathering needs because Win32_Tpm
            lives outside root/cimv2 (DESIGN 3.2.1).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    $provider = [pscustomobject] @{}

    $provider | Add-Member -MemberType ScriptMethod -Name GetInstance -Value {
        param([string] $First, [string] $Second)

        # A ScriptMethod cannot be overloaded, and it binds optional arguments
        # positionally. When $Second is empty the caller used the one-argument
        # form, so $First is the class name and the namespace is the default.
        if ([string]::IsNullOrEmpty($Second)) {
            $namespace = 'root/cimv2'
            $class = $First
        } else {
            $namespace = $First
            $class = $Second
        }

        try {
            # The unary comma is mandatory: a ScriptMethod returning an array
            # collapses a single-element array to a scalar without it, and the
            # ICimProvider contract requires an array even for Win32_BaseBoard.
            return , ([object[]] @(Get-CimInstance -Namespace $namespace -ClassName $class -ErrorAction Stop))
        } catch {
            # Get-CimInstance says only "Invalid class " - it does NOT name the
            # class. The ICimProvider contract requires the class name, and 01-03
            # proved that assertion goes red when it is removed, because a vaguer
            # message hides a typo in a fact gatherer. This is a rethrow with the
            # argument attached, not a branch on data, so the adapter stays dumb.
            throw [System.ArgumentException]::new(
                "Invalid class '$class' in namespace '$namespace': $($_.Exception.Message)", $_.Exception)
        }
    }

    return $provider
}

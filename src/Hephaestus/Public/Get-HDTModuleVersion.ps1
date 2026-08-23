function Get-HDTModuleVersion {
    <#
        .SYNOPSIS
            Returns the version of the loaded Hephaestus module.

        .DESCRIPTION
            Reports the ModuleVersion declared in Hephaestus.psd1 for the instance
            of the module that is currently loaded.

            Boot images record the engine version they contain; a
            mismatch between the version staged in a boot image and the version in
            the deployment share is a common cause of confusing failures, so the
            version has to be readable at runtime, including from inside WinPE.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Version

        .EXAMPLE
            Get-HDTModuleVersion

            The version in the manifest, which is the one number every artefact this
            build produces is stamped with.

        .EXAMPLE
            $version = Get-HDTModuleVersion
            'HDT {0}' -f $version

            What the console's title bar and every log header carry, so a support
            question comes with the build that produced it.

    #>
    [CmdletBinding()]
    [OutputType([version])]
    param()

    return $MyInvocation.MyCommand.Module.Version
}

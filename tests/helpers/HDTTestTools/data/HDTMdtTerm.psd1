#
# The forbidden-MDT term list (CLAUDE.md hard rule 4, PROJECT.md "MDT
# dependency: NONE. Zero MDT components.").
#
# It lives in a .psd1 rather than inside Get-HDTMdtDependency.ps1 on purpose:
# Get-HDTSourceFile excludes .psd1 files, so the scanner's own patterns are not
# scanned by the contract that uses them. Written inline, every pattern below
# would flag the file that defines it.
#
# ADK (DISM, oscdimg, WinPE) and WDS are permitted and deliberately absent from
# this list - they are supported Microsoft products independent of MDT.
#
# Matching is case-insensitive and applies to non-comment tokens only, so prose
# such as "replaces ZTIGather.wsf" stays legal in comments and documentation.
#
@{
    Term = @(
        @{
            Name        = 'MdtModule'
            Pattern     = 'MicrosoftDeploymentToolkit'
            Description = 'the MDT PowerShell module'
        }
        @{
            Name        = 'MdtDrive'
            Pattern     = 'MDTProvider'
            Description = 'the MDT PSDrive provider'
        }
        @{
            Name        = 'BddAssembly'
            Pattern     = 'Microsoft\.BDD'
            Description = 'an MDT assembly or namespace'
        }
        @{
            Name        = 'ZtiScript'
            Pattern     = '\bZTI[A-Za-z0-9]*\b'
            Description = 'an MDT ZTI script'
        }
        @{
            Name        = 'LtiScript'
            Pattern     = '\bLTI[A-Za-z0-9]*\b'
            Description = 'an MDT LTI / LiteTouch script'
        }
        @{
            Name        = 'MdtCmdlet'
            Pattern     = '-MDT[A-Za-z]'
            Description = 'an MDT cmdlet'
        }
        @{
            Name        = 'TaskSequenceXml'
            Pattern     = '\bts\.xml\b'
            Description = "MDT's task sequence file format"
        }
    )
}

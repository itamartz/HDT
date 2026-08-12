# Control fixture: MDT terms appear only in comments, and the commands used are
# ADK and WDS, which CLAUDE.md rule 4 explicitly permits. Must yield zero
# violations - prose about what HDT replaces has to stay free.

function Get-HDTMdtFreeSample {
    # Replaces ZTIGather.wsf and CustomSettings.ini from MDT; see DESIGN 3.
    # MDTProvider and Microsoft.BDD assemblies are deliberately not used.
    Import-WdsBootImage -Path 'X:\boot.wim' -WhatIf
    & 'oscdimg.exe' '-h'
}

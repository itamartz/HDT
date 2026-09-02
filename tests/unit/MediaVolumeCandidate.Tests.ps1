# AN ISO IS THE FORM OF MEDIA DESIGN 6.2 NAMES FIRST, AND IT COULD NOT BE FOUND.
#
# Start-HDTDeployment enumerates the machine's volumes and hands them to
# Resolve-HDTDeployRoot, which hunts each one for the content marker. The
# enumeration filtered on drive type:
#
#     Where-Object { $_.IsReady -and @('Fixed', 'Removable') -contains $_.DriveType }
#
# A USB stick is Removable, so USB media worked. A DVD is CDRom, so an ISO -
# the artefact Update-HDTBootImage builds every time, the one DESIGN 6.1 says
# is worth generating on every build, and the one a VM or an iDRAC actually
# boots - was excluded from the list before the marker hunt ever began.
#
# WATCHED ON A REAL MACHINE, 2026-09-03. A Generation 2 VM booted a 10 GB
# offline media ISO carrying \Share\rules.yaml and said:
#
#   bootstrap: workspace 'HDT-LAB-MEDIA', provider Local, deployRoot '\Share'
#   deployment method MEDIA, from the boot image's 'Local' provider
#   FATAL: the deployment content could not be found ... the candidate volumes
#   it looked under, in order, were: X:\
#
# X:\ is the RAM disk. The disc it had booted from seconds earlier was never a
# candidate, so the error naming "every candidate it looked at" was telling the
# truth about a list that was wrong.
#
# WHY A TEST EXISTED AND MISSED IT. StartHDTDeploymentPayload.Tests.ps1 asserts
# `$codeOnly | Should -Match 'GetDrives'` - the payload enumerates rather than
# naming letters, which it does. The defect was three characters further along,
# in the filter, and no text scan of the word GetDrives can see it. So this file
# LIFTS THE PREDICATE OUT BY AST and runs it against drive-shaped rows, the way
# MediaConnectLoop.Tests.ps1 lifts the connect loop, because a text scan is what
# let the last one ship too.
#
# BOTH DIRECTIONS, AND EVERY ENUMERATION. Network must stay excluded - a mapped
# drive is not where this machine's content lives, and probing one costs a
# timeout per volume. And the payload enumerates TWICE, once for what
# bootstrap.json carried and once for what a technician typed into the Welcome
# screen; a fix applied to one of them leaves the other exactly as it was.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:payloadToken = $null
    $script:payloadError = $null
    $script:payloadAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:payloadPath, [ref] $script:payloadToken, [ref] $script:payloadError)

    # BY AST AND NOT BY LINE NUMBER. The file is edited constantly and a test
    # pinned to line 980 would quietly start testing something else.
    # THE BODY, NOT THE EXTENT. Extent.Text carries the braces, so
    # [scriptblock]::Create on it builds a block whose body is a scriptblock
    # LITERAL - an object, which is truthy - and every row passes the filter.
    # The first cut of this file did exactly that and reported the payload
    # keeping mapped network drives, which it never did. The fake was wrong,
    # not the caller.
    $script:filterSource = @($script:payloadAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true) |
            Where-Object { $_.Extent.Text -match 'IsReady' -and $_.Extent.Text -match 'DriveType' } |
            ForEach-Object { [string] $_.ScriptBlock.EndBlock.Extent.Text })

    # A ROW SHAPED LIKE System.IO.DriveInfo. Only the three members the filter
    # reads are needed, and a real DriveInfo cannot be constructed for a drive
    # letter this machine does not have.
    $script:drive = @(
        [pscustomobject] @{ DriveType = 'Fixed'; IsReady = $true; RootDirectory = [pscustomobject] @{ FullName = 'X:\' } }
        [pscustomobject] @{ DriveType = 'CDRom'; IsReady = $true; RootDirectory = [pscustomobject] @{ FullName = 'D:\' } }
        [pscustomobject] @{ DriveType = 'Removable'; IsReady = $true; RootDirectory = [pscustomobject] @{ FullName = 'E:\' } }
        [pscustomobject] @{ DriveType = 'Network'; IsReady = $true; RootDirectory = [pscustomobject] @{ FullName = 'Z:\' } }
        [pscustomobject] @{ DriveType = 'CDRom'; IsReady = $false; RootDirectory = [pscustomobject] @{ FullName = 'F:\' } }
    )
}

Describe 'Start-HDTDeployment volume candidates' {

    It 'lifts a filter out of the payload to run, rather than reading it as text' {
        # THE GUARD THAT STOPS EVERY ASSERTION BELOW PASSING VACUOUSLY. An AST
        # query that matches nothing makes an empty loop, and an empty loop is
        # green.
        $script:payloadError | Should -BeNullOrEmpty
        $script:filterSource.Count | Should -BeGreaterThan 0
    }

    It 'enumerates the machine once and reuses that list' {
        # ONE ENUMERATION, AND THAT IS THE DESIGN. The share a technician
        # corrects at the Welcome screen is resolved against the SAME
        # $candidateRoot rather than a second scan, so there is exactly one
        # filter and no second copy to drift from it. If a later author adds a
        # rescan, this count changes and every assertion below starts covering
        # both - which is the point of asserting it at all.
        $script:filterSource.Count | Should -Be 1
    }

    It 'offers a DVD as a candidate, because an ISO is media' {
        foreach ($source in $script:filterSource) {
            $predicate = [scriptblock]::Create($source)
            $kept = @($script:drive | Where-Object $predicate |
                    ForEach-Object { [string] $_.RootDirectory.FullName })

            $kept | Should -Contain 'D:\' -Because ("this filter drops the optical drive, so a machine that booted an ISO can never find the content on it: {0}" -f $source)
        }
    }

    It 'offers a USB stick as a candidate, because that is media too' {
        foreach ($source in $script:filterSource) {
            $predicate = [scriptblock]::Create($source)
            $kept = @($script:drive | Where-Object $predicate |
                    ForEach-Object { [string] $_.RootDirectory.FullName })

            $kept | Should -Contain 'E:\'
        }
    }

    It 'offers a fixed disk as a candidate, because a share deployment still needs one' {
        # THE DIRECTION THAT MATTERS MOST. Every SMB deployment in this lab
        # depends on this list, and a change made for a disc must not narrow it.
        foreach ($source in $script:filterSource) {
            $predicate = [scriptblock]::Create($source)
            $kept = @($script:drive | Where-Object $predicate |
                    ForEach-Object { [string] $_.RootDirectory.FullName })

            $kept | Should -Contain 'X:\'
        }
    }

    It 'does not offer a mapped network drive' {
        # A mapped drive is not where this machine's content is, and hunting a
        # marker on one costs a network timeout for every volume behind it.
        foreach ($source in $script:filterSource) {
            $predicate = [scriptblock]::Create($source)
            $kept = @($script:drive | Where-Object $predicate |
                    ForEach-Object { [string] $_.RootDirectory.FullName })

            $kept | Should -Not -Contain 'Z:\'
        }
    }

    It 'does not offer a drive that is not ready' {
        # AN EMPTY OPTICAL DRIVE IS THE COMMON CASE, not a hypothetical: a
        # machine with two of them has one disc in it, and IsReady is what tells
        # them apart. Probing the empty one throws rather than returning false.
        foreach ($source in $script:filterSource) {
            $predicate = [scriptblock]::Create($source)
            $kept = @($script:drive | Where-Object $predicate |
                    ForEach-Object { [string] $_.RootDirectory.FullName })

            $kept | Should -Not -Contain 'F:\'
        }
    }
}

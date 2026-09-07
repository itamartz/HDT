# DELIBERATELY INVALID SOURCE. This file is the command that destroyed the
# per-machine overrides on 2026-09-07, kept verbatim so no future loosening of
# the scanner can let it back through silently.
#
# WHAT HAPPENED. An agent ran the line below. It removed 16 per-machine override
# files from C:\HDTLab\Share\Control\machines. Five were unrecoverable from
# backups; four of those were later recovered from an ISO by luck and one was
# reconstructed from logs.
#
# WHY IT MATTERED MORE THAN THE FILES. The consequence of a missing override is
# not a refusal, it is a SILENT WRONG BUILD: without its override a redeploy of
# HDT-WDS-01 resolves to the default OS and installs Windows 11 instead of
# Server 2025, then reports success.
#
# WHY ProtectedPath.Contract.Tests.ps1 DID NOT FIRE, all three verified:
#   1. It scans committed .ps1/.psm1/.psd1 files. This was typed into a tool
#      call and never became a file in the repository. Nothing static can catch
#      that - the runtime deny rules in .claude/settings.json are the layer that
#      does, and they are why this file exists as evidence rather than as the
#      only guard.
#   2. Its verb pattern was ^(Remove-Item|rd|rmdir|Remove-VMHardDiskDrive)$.
#      'rm' was not in it. The path matched; the verb did not.
#   3. The shape - a target built by a wildcard against an enumerated parent -
#      had no rule at all. CLAUDE.md names it in prose and nothing tested it.
#
# This file lives under tests/fixtures/, which the scan excludes by path, so it
# cannot trip the repository-wide assertions. The contract feeds it in by hand.

rm -f C:\HDTLab\Share\Control\machines\*.yaml

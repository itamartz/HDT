# Evidence — `run-20260830-204613`

The artefacts behind M5's and M6's "✅ Met" blocks in `docs/ROADMAP.md`.
Preserved here because the share's log tree has been pruned twice already —
`run-20260829-223623` and `run-20260830-003424` are both gone from
`C:\HDTLab\Share\Logs\`, and each time the milestone evidence went with them.

**The machine.** A physical Dell Latitude 5420, `HDTIsVM: false`, 2026-08-30.
The driver folder `Win11\Dell Inc.\Latitude 5420` was renamed to
`Latitude 5420 Fallback` immediately before the run, which is what made the model
unrecognised — the share still carries the renamed folder.

**Two copies, and they are not the same file.** The engine logs to the machine
and mirrors to the share, so a leg that starts before the share is reachable
lands only on the machine.

| Tree | Came from | Holds |
|---|---|---|
| `share/` | `C:\HDTLab\Share\Logs\LT-D5M1NN3\run-20260830-204613\` | `HDT.jsonl`, `HDT.log`, `Steps\` |
| `machine-local/` | `C:\HDTLab\Share\Logs\LT-D5M1NN3-run-20260830-204613\` | the same, **plus** the resume and SMB-reconnect lines the share-side log cannot hold, `status.json`, `state.json`, and `Gather\` |

Text only. The 4.3 GB of staged drivers the run copied to `W:\Drivers` are not
here and are not meant to be; what proves they were staged is the log line that
counts them.

## Provenance

**These files are byte-for-byte what came off the share, except for the one
redaction recorded below.** 26 of the 33 artefacts are identical to their source;
the other 7 differ only by the 24 substitutions described next, and nothing else
was reformatted, re-serialised or trimmed. `.gitattributes` marks this directory
`-text` so git's CRLF normalisation cannot rewrite them on the way in or out — a
checkout that no longer matches what the machine wrote is not evidence.

## Redaction — global-unicast IPv6 only

**Two addresses were removed**, both from a single /64 on
this machine's NIC, replaced with `2a0d:6fc0:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx` in 24
places across 7 files. They are **globally routable, ISP-delegated** addresses —
`2000::/3` — and identify the author's actual home connection, which is a
different thing from the lab addressing this repository treats as unremarkable.
This repository has a remote and publishes to the PowerShell Gallery, so they do
not belong in it.

The placeholder is deliberately visible rather than deleted: a reader can see
that an address *was* there, that it was a `2a0d:6fc0:` address, and that its
value was removed on purpose. **Both entries carry the same placeholder** — there
were two distinct addresses, and no attempt is made to keep them distinguishable.
`HDTIPAddress` still has its four entries and the JSON still parses.

**Nothing else was touched.**

- **Link-local `fe80::` stays** — it is not routable and identifies nothing.
- **Every RFC1918 IPv4 address stays**, `192.168.1.x` included. Removing them
  would break the SMB-reconnect line M5 is cited on, and this repository does not
  treat lab addressing as a secret.
- **The machine's name and serial stay.** `LT-D5M1NN3` is the host name — it is
  the log directory itself and appears throughout the repository — and the serial
  `D5M1NN3` is legible inside it and inside the derived asset tag regardless. An
  earlier draft masked the bare serial and left the two-thirds of its occurrences
  that are structural, which implied the rest had been missed. Better one plain
  sentence: **this lab machine is identified by name and service tag throughout,
  on purpose.**

If a later reader finds an address here that looks corrupted, it is not
corruption — check this section before "restoring" anything.

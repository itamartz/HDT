# Phase 08-01 Verification — Windows Update

**Date:** 2026-09-06
**Plans:** 08-01-01 (lab memory budget), 08-01-02 (`IUpdateSessionService`),
08-01-03 (`Invoke-HDTWindowsUpdateStep`), 08-01-04 (authoring surfaces + E2E)
**Gate:** `./build.ps1 ci` on Windows PowerShell 5.1.26100.8655 —
**BUILD SUCCEEDED**, `test: 14389 passed, 0 failed, 298 skipped`,
`lint: 0 diagnostics across 1175 file(s)`, `selfcheck: 4 of 4`.

---

## The exit criteria, met or not

### 1. A VM deploys through HDT — **NOT PROVEN ON A MACHINE**

No VM was deployed in this phase. The E2E was not written and not run; see
"Blocked" below. This criterion was met for other sequences in M6 and M7 and
nothing in phase 08 changes the deployment path, but **this phase did not
re-prove it.**

### 2. The `WindowsUpdate` step patches a machine against `HDT-WSUS-01` — **NOT PROVEN ON A MACHINE**

The step's logic is tested and its wire is not — the same shape of statement M6's
verification makes about `JoinDomain`.

**What IS proven, against fakes and against the real COM API:**

| Claim | Evidence |
|---|---|
| The service contract holds for a fake and for the real agent | `tests/contract/UpdateSessionService.Contract.Tests.ps1` runs the same shape assertions over both, with the real row skipped at discovery on a WUA-presence predicate |
| The real adapter talks to a real Windows Update Agent | Plan 08-01-02 imported the module and called `GetRebootRequired()` on this laptop's agent — answered `False`. Nothing was searched, downloaded or installed: the `WindowsUpdateClient` event log showed the machine's own unchanged ten-minute scan cadence, and the WU policy key carried no `WUServer` |
| The multi-pass loop bounds passes ACROSS reboot legs | Checkpointed pass counter, asserted in plan 08-01-03's unit tests |
| Both reboot questions are asked | `RebootRequired` on the session and on the install result |
| Every update logs KB, title, classification, result code AND its meaning, HResult and elapsed | `update.apply` record per update, asserted in 08-01-03 |
| Every filtered-out update reports a REASON | `Select-HDTApplicableUpdate` returns one per row, so the log can answer "why did this machine not get that patch" |
| The step is refused in a WinPE group at AUTHORING time | `Import-HDTSequenceDocument`'s flattener, walking `Get-HDTFullOsOnlyStepType` — the importer carries no `'WindowsUpdate'` literal and a test asserts that |

**What is NOT proven:** that a real WUA search against a real WSUS returns the
two approved updates; that the install succeeds; that a reboot between passes
resumes at the next pass on a real machine; that the step stops because a pass
found nothing rather than because `maxPasses` was hit. **All four are wire, and
all four are what the E2E existed to prove.**

### 3. The machine comes back running 26100.9168 — **NOT PROVEN**

No machine was patched.

### 4. More than one pass, with a reboot between — **NOT PROVEN ON A MACHINE**

Proven against fakes only (see 2).

### 5. Only the expected VMs ran, and every VM the harness did not create is as it was found — **MET**

`HDT-WSUS-01` Running / 8 GB / `Notes` empty. `HDT-WDS-01` Running / 4 GB /
`Notes` empty. **No VM was created, started, stopped or removed in this plan.**
Plan 08-01-01's stamp makes removing an unstamped VM structurally impossible.

### 6. `./build.ps1 ci` green under Windows PowerShell 5.1, analyzer in its own process — **MET**

2026-09-06T00:10Z. `BUILD SUCCEEDED (clean, version, bundle, build, lint, test,
selfcheck) on PowerShell 5.1.26100.8655`.

### 7. Every surface that must know about the step type knows about it — **MET**

Proven by a test written against the SET, not against the new type:
`tests/unit/WindowsUpdateStepSurface.Tests.ps1`. It found a second, older defect
on its first run — `Gather` had been offered under Custom since it shipped —
which is the argument for set-based tests made by the test itself.

Template, description, console shelf, four properties rows, closed-set drop-down
read from `Get-HDTStepPropertyChoice`, both manifest exports, the document
validator (asserted by test rather than by reading), the schema fixture, the step
contract's list, `docs/command-categories.psd1` and the regenerated reference.

**The console was opened and photographed** — offscreen, STA, `RenderTargetBitmap`,
nothing shown on the user's desktop. General shelf: `... Install Applications,
Join Domain, Tattoo, Windows Update, Gather`. Properties sheet: Update server,
Classifications, Exclude, Passes, each with a one-or-two-line hint.

### 8. Both samples run it twice, the shipped template carries it disabled — **MET**

`STD-CLIENT` and `STD-SERVER` each carry two instances bracketing
`InstallApplications`, under MDT's own names. `src/Hephaestus/Templates/client.yaml`
carries both `disabled: true`, matching MDT's `Client.xml` read on this host.
`C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml` spliced to match.

### 9. No document still calls the step deferred — **MET**

`docs/DESIGN.md` §1, §4, §10.1 and `docs/ROADMAP.md`'s deferral block all record
"deferred 2026-08-16, built 2026-09-06". The history is struck through, not
deleted. A test walks all five documents and fails any line that stops at the
deferral.

### 10. `.planning/SPIKES.md` records what the real Windows Update Agent did — **NOT DONE**

The SPIKES entry was to be written from the E2E run. There is no run, so there is
nothing verified-by-execution to record, and SPIKES takes nothing else. Plan
08-01-02's finding about `BeginInstall($null,$null,$null)` rejecting the null
callback is already recorded in that plan's commit.

---

## Blocked: the E2E

**Pre-flight check 4 failed: `HDT-WSUS-01` does not resolve by name from this
host.**

```
Resolve-DnsName -Name 'HDT-WSUS-01' -Type A   ->  DNS name does not exist
Test-Connection  -ComputerName 'HDT-WSUS-01'  ->  No such host is known
```

The server is healthy, on the `HDT External` switch, and Hyper-V reports its
guest address on `192.168.1.0/24`. It is a **workgroup** machine and the real
LAN's DNS carries no registration for it.

The plan is explicit that this is a stop, not a thing to work around: a name that
does not resolve makes `SetServer` write a policy pointing at nothing, the search
return nothing applicable, and the step report **exactly what a working step
reports on a fully-patched machine** — a 45-minute run that proves nothing and
looks like a pass. Substituting an address into the sequence, or planting a
hosts-file entry on the target, would make the E2E prove something other than
what a real deployment does.

**The other three pre-flight checks passed**, and they are the expensive ones:

- Exactly **2** updates approved on `HDT-WSUS-01`, both `State: Ready` —
  **KB5121003**, the 2026-08 cumulative for Windows 11 24H2 x64 (build
  **26100.9168**), and **KB5120710**, the matching .NET cumulative. The other 597
  synced updates are declined. That staging is what would make a client coming
  back on 26100.9168 prove the STEP worked rather than proving Microsoft's
  catalogue works. The 14 GB download that was in flight when this phase was
  planned has completed.
- The memory budget ignores both lab servers, so a 4 GB target would be accepted.
- The host's address on `HDT External` is present and /24. Read, not written down.

**A decision is needed.** Every way forward is either a change to the user's lab
or a departure from the plan's own rule:

1. **Give `HDT-WSUS-01` a DNS record** so the name resolves the way a real
   deployment's would. Keeps the E2E honest; needs a change on the LAN's DNS.
2. **Put the address in the sequence.** Against the plan's explicit instruction
   and against the lease rule.
3. **Defer the E2E to a follow-up plan** and land the authoring work as it
   stands, with this document recording what is and is not proven.

---

## Summary

**The `WindowsUpdate` step is built, authorable from the console, shipped in the
samples and in the template, and green on the gate. It has never patched a
machine.** Phase 08-01's milestone exit is therefore **not met**; items 1–4 above
are the outstanding ones and all four are the same E2E.

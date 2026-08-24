# The deployment account, step by step

A PXE-booted machine has no identity of its own to authenticate with, so HDT
embeds a deployment account's credential in the boot image — the model MDT used,
and the same exposure. **Anyone who can read the boot WIM, the ISO, or the
`Boot\` folder can recover that account's password.** That is not solvable while
WinPE has no machine identity; what is solvable is making the account worth as
little as possible.

`Test-HDTShareAcl` checks the result and `Update-HDTBootImage` warns loudly when
the account is over-privileged, because a domain admin credential in a boot image
is a domain compromise. A checker that tells an administrator they are wrong
without telling them what right looks like is half a feature, so this page is the
other half. Every command below is copy-pasteable.

---

## 1. Create the account

It needs no group membership beyond `Domain Users` (or `Users` locally). It is
**not** a member of `Administrators`, `Domain Admins` or `Enterprise Admins` —
`Test-HDTShareAcl` reports any of those three as `Critical` and quotes the
sentence above.

**Active Directory:**

```powershell
New-ADUser -Name 'svc-hdt-deploy' `
    -SamAccountName 'svc-hdt-deploy' `
    -UserPrincipalName 'svc-hdt-deploy@contoso.com' `
    -Path 'OU=Service Accounts,DC=contoso,DC=com' `
    -AccountPassword (Read-Host -AsSecureString 'Password') `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Enabled $true

# No groups beyond the default. Check it, do not assume it:
Get-ADPrincipalGroupMembership -Identity 'svc-hdt-deploy' | Select-Object -ExpandProperty Name
```

**A standalone file server, no domain:**

```cmd
net user svc-hdt-deploy * /add /expires:never /passwordchg:no
net localgroup Administrators svc-hdt-deploy /delete
```

The `net localgroup ... /delete` line is there on purpose: run it, and expect it
to say the account is not a member. Confirming a negative costs one command.

## 2. Deny it every interactive logon

The account exists to read files over SMB. It should not be able to log on to
anything, so that a recovered password is worth as little as it can be.

**Group Policy** — *Computer Configuration → Policies → Windows Settings →
Security Settings → Local Policies → User Rights Assignment*:

| Right | Add |
|---|---|
| Deny log on locally | `CONTOSO\svc-hdt-deploy` |
| Deny log on through Remote Desktop Services | `CONTOSO\svc-hdt-deploy` |
| Deny log on as a batch job | `CONTOSO\svc-hdt-deploy` |
| Deny log on as a service | `CONTOSO\svc-hdt-deploy` |

**Without Group Policy**, on the file server:

```cmd
secedit /export /cfg %TEMP%\hdt.inf /areas USER_RIGHTS
rem edit SeDenyInteractiveLogonRight, SeDenyRemoteInteractiveLogonRight,
rem SeDenyBatchLogonRight and SeDenyServiceLogonRight to include the account
secedit /configure /db %TEMP%\hdt.sdb /cfg %TEMP%\hdt.inf /areas USER_RIGHTS
```

Leave `Access this computer from the network` alone: that is the one right the
account does need.

## 3. Share and NTFS rights, per folder

**This is the table `Test-HDTShareAcl` checks against.** The folder names are
DESIGN 2.1's workspace layout, and a test asserts that this page names every one
of them, so the document and the checker cannot drift apart.

| Folder | Deployment account | Why |
|---|---|---|
| the workspace root | **Read** | it reads `workspace.yaml` and `rules.yaml` |
| `TaskSequences\` | Read | sequence documents |
| `OperatingSystems\` | Read | the images it applies |
| `Applications\` | Read | installers |
| `Drivers\` | Read | the driver store |
| `Boot\` | Read | boot images and PXE payloads |
| `Control\` | Read | per-machine overrides, and its own credential file |
| `Scripts\` | Read | user scripts the engine dot-sources |
| `Modules\` | Read | third-party step modules |
| `Logs\` | **Write** (or Modify) | every deployment writes its log back |
| `Captures\` | **Write** (or Modify) | image capture writes here |

**Nowhere gets `FullControl`.** `FullControl` carries `ChangePermissions` and
`TakeOwnership`, so an account holding it can rewrite the share's own security —
`Test-HDTShareAcl` reports it as `Critical` even on `Logs\`.

`New-HDTWorkspaceShare -Account` sets **both** of these — the share permission
and the NTFS rows below — so on a share HDT published there is nothing to do
here:

```powershell
New-HDTWorkspaceShare -Path 'D:\HdtShare' -Account 'CONTOSO\svc-hdt-deploy'
```

The rest of this section is what that command does, for a share published some
other way.

Share permission first — read-only at the share level, so the NTFS rights below
are the only thing that can widen it:

```powershell
New-SmbShare -Name 'HdtShare' -Path 'D:\HdtShare' `
    -ReadAccess 'CONTOSO\svc-hdt-deploy' `
    -FullAccess 'CONTOSO\Domain Admins'
```

Then NTFS. `/T` applies to the tree; `icacls /grant` adds a row rather than
replacing the ACL, so nothing else is needed to leave the existing entries
alone — `/grant:r` is the one that replaces.

**Not `/E`.** That is a `cacls` switch, not an `icacls` one: `icacls` parses it
as a file name and fails with *The system cannot find the file specified*.

```cmd
icacls D:\HdtShare              /grant "CONTOSO\svc-hdt-deploy:(OI)(CI)(RX)" /T
icacls D:\HdtShare\Logs         /grant "CONTOSO\svc-hdt-deploy:(OI)(CI)(M)"  /T
icacls D:\HdtShare\Captures     /grant "CONTOSO\svc-hdt-deploy:(OI)(CI)(M)"  /T
```

Grant the root before the two writable folders. The root grant is inherited by
the tree, so a `Modify` written first is flattened back to `Read` by the one that
follows it.

## 4. Check it, rather than believing it

```powershell
$root = '\\server\HdtShare'
$accessRule = @{}
foreach ($folder in @('.', 'TaskSequences', 'OperatingSystems', 'Applications',
                      'Drivers', 'Boot', 'Control', 'Scripts', 'Modules',
                      'Logs', 'Captures')) {

    $path = $root
    if ($folder -ne '.') { $path = Join-Path -Path $root -ChildPath $folder }

    $accessRule[$folder] = Get-HDTShareAccessRule -Path $path
}

$result = Test-HDTShareAcl -WorkspaceRoot $root -Identity 'CONTOSO\svc-hdt-deploy' -AccessRule $accessRule
$result.Compliant
$result.Finding | Format-Table Severity, Path, Message -Wrap
```

`Compliant` is `$true` only when nothing above `Information` was found. An ACL
the checker could not read is an `Information` finding, not a failure —
`Update-HDTBootImage` warns and builds anyway, because a build that died on an
unreadable ACL is a check somebody turns off.

## 5. Store the password

```powershell
Set-HDTShareCredential -WorkspaceRoot '\\server\HdtShare' -Credential (Get-Credential 'CONTOSO\svc-hdt-deploy')
```

It writes `Control\share-credential.json` and nothing else writes that file.
`workspace.yaml` carries the **username only**; a `password:` key in it is a
validation error naming this command, because `workspace.yaml` is the document an
administrator hand-edits and commits.

```yaml
# workspace.yaml
deployRoot: \\server\HdtShare
credential:
  username: CONTOSO\svc-hdt-deploy
```

`Control/share-credential.json` is in `.gitignore`.

### The protection on that file is obfuscation, and is not claimed as security

The password is AES-encrypted with **a key that is a constant in the Hephaestus
module**. The module ships inside the boot image, so anyone holding the image
holds the key. The file says so itself, in a `warning` field written next to the
value.

It is not DPAPI, and that is deliberate: DPAPI is bound to a user and a machine,
and this value has to be readable inside WinPE on a machine that has never seen
the one that built the image — which is the entire reason the credential is
embedded.

### Boot media is a credential

The boot WIM, the ISO, the USB stick and the `Boot\` folder all carry that
password. Handle them the way you would handle the password itself: do not post
the ISO on a file share everyone can read, do not hand a technician a USB stick
you would not hand them the password on, and rotate the account's password when
one goes missing — then rebuild the image with `Set-HDTShareCredential` and
`Update-HDTBootImage`.

### A build going offsite: `-PromptForCredential`

```powershell
Update-HDTBootImage -WorkspaceRoot '\\server\HdtShare' -PromptForCredential
```

builds an image with **no embedded credential**: the technician is asked for one
at the WinPE prompt. It is the right choice for a shared lab, a media build going
offsite, or any image leaving your control. It is available, not the default —
prompting at every bare-metal boot defeats the point of PXE.

## 6. When something goes wrong

| Symptom | Look at |
|---|---|
| `HDTSecurityError: ... came back as ... it fell back to guest` | the account is disabled, or its password no longer matches the one `Set-HDTShareCredential` wrote. Rewrite the credential and rebuild the boot image |
| `HDTSecurityError: ... negotiated SMB dialect '1.x'` | SMB1 on the file server. HDT refuses it outright |
| A warning about an unencrypted connection | the server does not support SMB encryption. HDT continues; the credential and every file cross the network in clear |
| `HDTSecurityError: no credential was supplied` | no `Control\share-credential.json`, or the boot image was built before one was written |
| `Test-HDTShareAcl` reports `Critical` at the root | the account cannot read the share at all — check the **share** permission as well as NTFS |

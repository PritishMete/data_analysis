# InsightFlow Excel v2 Windows Desktop acceptance record

Do not mark a test PASS based on browser-only or CI tests. Execute each case in the supported Windows Excel Desktop build with the local test backend and record evidence.

## Test environment

| Field | Value |
|---|---|
| Date/time and time zone | |
| Windows edition/build | |
| Excel version/build/channel | |
| Microsoft Edge WebView2 version | |
| Browser and version | |
| Repository commit | |
| Local backend commit | |
| Development Supabase project ref | |
| Add-in GUID | |
| PostgreSQL server version | |
| Test operator | |

Allowed result values: PASS, FAIL, BLOCKED, NOT RUN. All tests start as NOT RUN.

## Acceptance cases

| # | Test | Procedure | Expected behavior | Result | Evidence / notes |
|---:|---|---|---|---|---|
| 1 | Add-in sideloading | Add the generated local manifest through the Windows shared-folder catalog; open a workbook and task pane. | Excel accepts the manifest, loads https://localhost:3000/ over trusted HTTPS, and shows the InsightFlow pane without certificate or manifest errors. | NOT RUN | |
| 2 | Email/password login | Start with no Excel-local session. Begin a handoff, open the browser link, sign in using the development account, then approve the exact candidate in Excel. | Excel displays the verified candidate identity; after explicit approval, the claimed session getUser() UID matches the approved UID. | NOT RUN | |
| 3 | Google OAuth login | Repeat the flow with Google through the development Supabase project's configured Google provider. | OAuth returns to the same browser tab and local callback; authorization code is removed from the address bar; Excel receives no tokens through dialog messages; verified UID matches approval. | NOT RUN | |
| 4 | Existing-session restoration | Sign in successfully, close and reopen the task pane without logging out. | The local Supabase session restores and is checked with the authoritative user lookup before workspace access. | NOT RUN | |
| 5 | Explicit account approval | Start a new handoff and sign in in the browser; do not approve immediately. | Excel remains pending until the user explicitly approves the exact displayed candidate UID/email and generation. No automatic approval occurs. | NOT RUN | |
| 6 | Wrong-account rejection | Start a handoff intended for account A, then authenticate as account B in the browser. Reject the candidate in Excel. | Account B is not installed as the Excel session; the transaction is rejected/terminal and its staged token material is cleared. | NOT RUN | |
| 7 | Task-pane reload | Reload Excel's task pane while a browser handoff is pending and again after candidate approval. | The pane recovers the existing transaction state safely; it does not create a second claim or replay a completed claim. | NOT RUN | |
| 8 | Browser closure and return | Close the external browser before candidate completion, then reopen the old browser URL; repeat with a newly generated pairing code. | Old/expired browser capability is rejected. A fresh pairing code can start a new attempt without reviving the old capability. | NOT RUN | |
| 9 | Expired access-token recovery | Use a development test account/session with a deliberately short access-token lifetime or wait for expiry before browser completion. | Backend rejects expired access token; no refresh is attempted by backend and no session is approved from stale identity. User can restart sign-in and complete with a fresh token. | NOT RUN | |
| 10 | Cancellation while backend unavailable | Begin a pending transaction, stop the local backend, then cancel from Excel. Restart backend and inspect transaction status. | Excel clears local handoff capabilities even when remote cancellation fails. Server-side transaction cannot be claimed after expiry; no token is exposed locally. | NOT RUN | |
| 11 | Excel-local logout | Complete an Excel sign-in, use the Excel-specific logout action, then reload the task pane. | Only the local Supabase session and Excel handoff capabilities are cleared. Other InsightFlow clients remain signed in. | NOT RUN | |
| 12 | Website logout isolation | Sign in to the website and Excel using the same development account. Log out from the website only. | Website logout does not clear the Excel-local session or Excel transaction capability. Confirm Excel still passes its authoritative user check. | NOT RUN | |
| 13 | Excel restart and session recovery | Complete a sign-in, fully exit Excel, reopen Excel and the same workbook. Repeat after Excel-local logout. | A valid retained local session restores after restart; after Excel-local logout, no session is restored. Other clients remain unaffected. | NOT RUN | |
| 14 | Multiple Excel instances | Open two Excel instances/workbooks and start independent handoffs. Complete one, then the other. | Each transaction remains bound to its own claim capability and approved UID/generation; no cross-instance claim, identity mix-up or token reuse occurs. | NOT RUN | |
| 15 | Office Dialog fallback | Force or select the Office Dialog fallback; complete one login and close the dialog mid-flow in a second attempt. | Supported fallback completes the same explicit approval and identity checks. Closing the dialog does not leak tokens or make a cancelled/ambiguous claim replayable. | NOT RUN | |

## Sign-off

- [ ] All 15 cases have a recorded result.
- [ ] Every FAIL or BLOCKED case has a linked log/screenshot and issue.
- [ ] No production credentials or production database were used.
- [ ] No production migration, Render configuration change, or deployment was performed.
- [ ] Test manifest and local secrets were kept outside the repository.

**Acceptance status:** NOT ACCEPTED until all required cases pass on the actual supported Windows Excel Desktop host.

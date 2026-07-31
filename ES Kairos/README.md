# Kairos

**STDIO MCP server for calendar, reminders, contacts, and mail on macOS.**

EventKit + Contacts + Scripting Bridge (Mail), native AppKit, Objective-C.
Events, reminders, and messages are identified by semantic keys
(`title + calendar + start`, `title + list + due`, `subject + sender + date`) —
no UUIDs in the LLM context, so summaries stay reliable. A native macOS
confirmation dialog appears before any deletion, and every outgoing
email is gated by a native dialog showing the full message.

---

## Install (end users)

1. Download `ES_Kairos.mcpb` from this repo's root and **double-click it**.
   Claude Desktop will install it as a connector.
2. **Quit and reopen Claude Desktop.** On first launch three macOS
   permission prompts appear in sequence — one each for Calendar,
   Contacts, and Reminders. Approve all three. (The chained prompts
   are deliberate; macOS won't show them reliably if asked in parallel.)
   A fourth prompt — Automation access to Mail — appears later, on the
   first use of a mail tool, and may launch Mail.app in the background.
3. Ask Claude things like:
   - *"What's on my calendar today?"*
   - *"What reminders are due today?"*
   - *"Find Mary's phone number"*
   - *"Add a reminder to call the dentist tomorrow at 2pm"*
   - *"Move the 3pm meeting on Friday to 4pm"*

Claude reads and writes through the live macOS data stores. Anything
Kairos creates appears immediately in Calendar.app, Reminders.app, and
Contacts.app, and vice versa.

### What's safe

Every **deletion** (event or reminder) pops a native dialog asking you to
confirm before anything happens — Kairos cannot quietly remove your data.
Updates do not pop a dialog, so Claude's MCP client is expected to
confirm with you before invoking destructive tools (the tool annotations
flag this).

The **mail tools are tiered by consequence**:

- `mail_mark` (reversible flag) and `mail_draft` (additive, nothing
  leaves the Mac) run without dialogs.
- `mail_move` runs silently for filing, but Trash/Junk targets — and
  their provider aliases like "Deleted Items" — pop the same warning
  alert as event/reminder deletion.
- `mail_send` and `mail_reply` **always** pop a native dialog showing
  every recipient, the subject, and the complete scrollable body.
  Sending requires a deliberate mouse click — the Send button has no
  key equivalent, so a Return keystroke in flight when the dialog
  steals focus cannot fire it. Escape cancels.

Reading email means untrusted content from external senders enters
Claude's context, and with send tools present that matters: a message
saying "forward this to…" is the textbook prompt-injection attack.
The tool descriptions instruct Claude to treat message bodies strictly
as data and never to compose or send based on them — but the dialog is
the hard guarantee: nothing leaves this Mac unseen.

### If a permission prompt doesn't appear

macOS TCC sometimes silently drops a permission request if another is in
flight. If you grant Calendar but Contacts or Reminders never asks:

```sh
tccutil reset Calendar com.elarity.ES-Kairos
tccutil reset Contacts com.elarity.ES-Kairos
tccutil reset Reminders com.elarity.ES-Kairos
```

Then fully quit Claude Desktop (Cmd-Q) and reopen. All three prompts
should fire on the next launch. Alternatively, grant access manually in
**System Settings → Privacy & Security**.

### What gets installed where

- **App bundle:** `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.kolja-wawrowsky.es-kairos/server/ES_Kairos.app/`
- **Logs:** `~/Library/Logs/Claude/mcp-server-ES Kairos.log`
- **TCC permissions:** under the bundle ID `com.elarity.ES-Kairos`

To uninstall: in Claude Desktop, **Settings → Connectors → ES Kairos →
Remove**. macOS will keep the TCC entries; reset them with `tccutil` if
you want a clean slate.

---

## Tools

| Tool | Description |
|---|---|
| `datetime_now` | Current local date & time: ISO 8601 with UTC offset, weekday, IANA timezone |
| `calendar_list` | All calendars: name, type, source, editable |
| `events_in_range` | Events in a date window, optional calendar filter |
| `event_search` | Substring search across title, location, notes |
| `event_create` | Create a new event |
| `event_update` | Update by semantic key (title + calendar + start) |
| `event_delete` | Delete with native confirmation dialog |
| `reminder_lists` | All reminder lists: name, source, editable |
| `reminders_today` | Reminders due today + overdue (the morning brief) |
| `reminders_in_range` | Reminders due in a date window, optional list filter |
| `reminder_search` | Substring search across title and notes |
| `reminder_create` | Create a new reminder with optional due/priority/notes; `#tags` in title/notes become native Reminders tags |
| `reminder_update` | Update by semantic key (title + list + due) |
| `reminder_complete` | Mark a reminder completed (reversible) |
| `reminder_delete` | Delete with native confirmation dialog |
| `contact_search` | Search contacts by name |
| `ask_user` | Native text-input popup |
| `mailbox_list` | Mail accounts and mailboxes with unread counts |
| `mail_list` | Recent messages in a mailbox, newest first |
| `mail_search` | Substring search across subject and sender |
| `mail_read` | Full message by semantic key (subject + sender + date) |
| `mail_mark` | Mark read/unread by semantic key (reversible) |
| `mail_move` | File a message; deletion-like targets require the native dialog |
| `mail_draft` | Compose into Drafts without sending |
| `mail_send` | Send email — full-body native dialog, click-only Send |
| `mail_reply` | Threaded reply via Mail's reply command — same dialog |

---

## Building from source

> The rest of this README is for developers. End users only need the
> "Install" section above — drag-drop the `.mcpb` file and you're done.

Modelled on the [ES UITest](../ES UITest) pattern: accessory app,
`LSUIElement = YES`, GCD queues for stdio framing, AppKit on the main
thread.

### Quick start

```sh
# Build, run tests, and produce ES_Kairos.mcpb
bash scripts/smoke-test.sh      # build + stdio handshake check (no TCC needed)
xcodebuild test -project "ES Kairos.xcodeproj" -scheme "ES Kairos" \
  -destination 'platform=macOS' -derivedDataPath /tmp/kairos-derived
bash scripts/package-mcpb.sh    # clean release build, packaged as .mcpb
```

### Xcode Project Setup

1. **New project**: macOS → App, Objective-C, bundle ID `com.elarity.kairos`
2. **Add all `.h`/`.m` files** from this folder (synchronized folder recommended)
3. **Frameworks**: EventKit.framework, Contacts.framework, AppKit.framework,
   ScriptingBridge.framework (all auto-linked via module imports).
   `Mail.h` is generated, not hand-written — regenerate after macOS updates with
   `sdef /System/Applications/Mail.app | sdp -fh --basename Mail`
4. **Info.plist** — add usage strings:
   ```
   NSCalendarsFullAccessUsageDescription  →  "Kairos needs calendar access for AI collaboration."
   NSContactsUsageDescription             →  "Kairos needs contacts access for AI collaboration."
   ```
5. **Entitlements** — App Sandbox OFF (same as ES UITest). For hardened runtime + notarization, add:
   ```xml
   <key>com.apple.security.personal-information.calendars</key><true/>
   <key>com.apple.security.personal-information.contacts</key><true/>
   ```
   These are only required for sandboxed apps, but harmless to include and
   required by notarization tooling in some configurations.
6. **Build Settings**:
   - `ENABLE_USER_SCRIPT_SANDBOXING = NO` (see ES UITest §10.5)
   - `PRODUCT_NAME = Kairos` (no spaces — avoids manifest path issues)
   - DerivedData outside iCloud (see ES UITest §10.2)
7. **Delete `MainMenu.xib`** — `main.m` bypasses `NSApplicationMain`; the xib
   is never loaded (see ES UITest §10.3), but removing it is cleaner.

---

## Event Identity

Events are identified by the triple **(title, calendar, start)**. This is
sufficient for personal calendars in virtually all real cases. An `index`
field appears in query results only when multiple events share the same
title and calendar within the result set (e.g. back-to-back recurrences).

The lookup window is ±2 minutes around the supplied start date, which
tolerates timestamp rounding in how the LLM echoes dates back.

## Reminder Identity

Reminders are identified by **(title, list, due)**. Same pattern as events
but `due` is optional — many reminders have no due date. Pass `due` as a
string when the reminder has one, omit it when it doesn't. The ±2 minute
window applies to the due date too.

The dedup `index` field appears when multiple reminders share title + list,
exactly mirroring the event mechanism.

## Message Identity

Messages are identified by **subject**, narrowed by an optional **sender
substring** and **received date** (±2 minute window, same as events).
Exact (case-insensitive, trimmed) subject match is preferred; if nothing
matches exactly, substring matching is the fallback. When several
messages still match — newsletters reuse subjects for months —
`mail_read` returns an `ambiguous` result listing candidates newest-first
with 1-based `index` fields, and the LLM calls again with `index`.

Mail's `Message-ID` header stays internal: reliable, but exactly the
kind of opaque identifier Kairos keeps out of the LLM context.

Every phase-2 write tool (`mail_mark`, `mail_move`, `mail_reply`)
resolves its target through the same shared front-end as `mail_read`
(`targetMessageWithSubject:…`), so ambiguity, `index` disambiguation,
and the staleness re-check behave identically across the surface.

Priorities are exposed as **strings**: `"high"` (EventKit priority 1–4),
`"medium"` (5), `"low"` (6–9), or omitted (0 = none). The numeric scale is
an EventKit-internal artifact; the LLM works better with semantic labels.

---

## Span Parameter

EventKit exposes two spans: `EKSpanThisEvent` and `EKSpanFutureEvents`.
The `span` parameter maps as follows:

| Parameter value | EKSpan |
|---|---|
| `"this"` (default) | `EKSpanThisEvent` |
| `"following"` | `EKSpanFutureEvents` |

There is no "all occurrences" that includes past events — `EKSpanFutureEvents`
covers this occurrence and all future ones, which is the standard calendar
behavior.

---

## Threading

| Concern | Thread / Queue |
|---|---|
| `[NSApp run]`, AppKit UI, NSAlert, AskUserWindowController, SendConfirmWindowController | main thread |
| stdin reader (line-buffered) | `kairos.mcp.read` (serial) |
| per-request tool dispatch | `kairos.mcp.work` (concurrent) |
| stdout writes | `kairos.mcp.write` (serial) |
| EKEventStore operations | `kairos.ekbridge` (serial) |
| CNContactStore operations | `kairos.cnbridge` (serial) |
| Scripting Bridge / Apple Events to Mail | `kairos.mailbridge` (serial) |

EKEvent, CNContact, and SBObject references never cross their respective
queue boundaries — all results are converted to `NSDictionary` before
being returned to callers.

---

## Authorization

Calendar, Contacts, and Reminders access is requested at launch in
`AppDelegate`. The system permission dialogs appear on first run. Tool
handlers check `isAuthorized` and return a clear error message if the
user denied access, directing them to System Settings.

Mail is different: the Automation permission is requested **lazily on
first mail tool use** inside `MailBridge`, never at launch — because the
request sends an Apple Event, and an Apple Event launches Mail.app.
Requesting at launch would open Mail every time Claude Desktop starts.
See dragon N.10.

---

## Build & Smoke Test

```sh
# Build
xcodebuild -project Kairos.xcodeproj -scheme Kairos \
  -configuration Debug -derivedDataPath /tmp/kairos-derived build

# Smoke test: initialize + tools/list
BIN="/tmp/kairos-derived/Build/Products/Debug/Kairos.app/Contents/MacOS/Kairos"
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| "$BIN" 2>/tmp/kairos.err
cat /tmp/kairos.err

# Test calendar_list (keep stdin open — see ES UITest §10.8)
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"calendar_list","arguments":{}}}'
  sleep 3
} | "$BIN" 2>/tmp/kairos.err
```

---

## Gotchas Inherited from ES UITest

All of §10 from the ES UITest README applies here. Summary of the most
relevant:

- **§10.1** `setvbuf` on both stdout and stderr — done in `main.m`.
- **§10.2** Build DerivedData outside iCloud (`/tmp/kairos-derived`).
- **§10.3** Bypass `NSApplicationMain` — done in `main.m`.
- **§10.4** Hold `AppDelegate` in a static — done in `main.m`.
- **§10.8** Keep stdin open in shell tests (`sleep N` at end of pipe).

## New Dragons

### N.1 EKEventStore thread affinity

`EKEventStore` operations must run on the queue that created the store.
`EKBridge` enforces this via `dispatch_sync(self.queue, ...)` for all
store access. Never call store methods from another queue or the main thread.

### N.2 TCC prompts at first run

On first launch the system will show two permission dialogs (Calendar,
Contacts) before the MCP handshake completes. This is normal — the dialogs
are modal and block the main thread. The MCP host (Claude Desktop) will
wait. Subsequent launches skip the dialogs.

The two requests are **chained**, not parallel: Contacts only fires from
Calendar's completion handler, and only after a 500 ms hop back to the
main queue. Firing both `requestAccess` calls in parallel from
`applicationDidFinishLaunching` causes macOS TCC to silently drop the
second one — no dialog, immediate `denied`. See `AppDelegate.m`.

### N.3 EKEventStoreChangedNotification

External changes (another app saving an event) trigger this notification.
`EKBridge` observes it and calls `[store reset]` on the bridge queue.
In-flight queries complete before the reset runs (serial queue ordering).

### N.4 All-day event end dates

EventKit stores the end date of an all-day event as midnight of the *next*
day. `formatEvent:` detects `isAllDay` and emits only a `date` field
(from `startDate`), not `start`/`end`, to avoid surfacing the off-by-one
to the LLM.

### N.5 NSAlert on main thread

The delete confirmation `NSAlert` is dispatched to the main thread via
`dispatch_async` + semaphore, blocking the work queue thread while the
user responds — same pattern as `AskUserWindowController`. Only one
blocking main-thread operation should be active at a time; concurrent
`event_delete` calls will serialize on the semaphore naturally, but the
second alert won't appear until the first resolves.

### N.6 Xcode 26 declarative Resource Access (the three-gate TCC trap)

On macOS, getting a TCC dialog to appear requires **three** independent
gates lining up — miss any one and the system silently denies with no
prompt, returning immediate `CNErrorAuthorizationDenied` (or the EventKit
equivalent). All three are mandatory:

1. **Info.plist usage description** — `NSContactsUsageDescription` /
   `NSCalendarsFullAccessUsageDescription`. Set via the
   `INFOPLIST_KEY_NS...` build settings.
2. **Hardened-runtime entitlement** — auto-injected by Xcode 26's new
   resource-access build settings:
   - `ENABLE_RESOURCE_ACCESS_CALENDARS = YES` →
     `com.apple.security.personal-information.calendars`
   - `ENABLE_RESOURCE_ACCESS_CONTACTS = YES` →
     `com.apple.security.personal-information.addressbook`
     (note the *legacy* name — predates the Contacts.app rename;
     the iOS-style `personal-information.contacts` key is NOT
     recognized on macOS and including it in a hand-written
     entitlements file actively confuses TCC).
3. **Resource access build setting itself** — `ENABLE_RESOURCE_ACCESS_*`
   is the gate that tells the TCC daemon "this binary may legitimately
   ask for X." Without it, the entitlement alone isn't enough and TCC
   short-circuits the request before showing any UI.

`Kairos.entitlements` therefore only declares `app-sandbox = false`;
all personal-information entitlements are owned by the resource-access
build settings to avoid the iOS-vs-macOS key mismatch. Toggle them via
**Signing & Capabilities → + Capability → Resource Access** in Xcode.

### N.7 Reminders share the EKEventStore with events

`EKEventStore` handles both `EKEntityTypeEvent` and `EKEntityTypeReminder`.
A single bridge instance, a single queue, but **two independent TCC
entitlements** (`personal-information.calendars` and
`personal-information.reminders`) and two independent authorization
statuses. The store can be authorized for one entity type and denied for
the other — tool handlers must consult the right `isAuthorized` /
`isAuthorizedForReminders` flag.

Reminder fetches are async (`fetchRemindersMatchingPredicate:completion:`)
unlike events. `EKBridge` wraps the async API in a semaphore on the bridge
queue with a 10 s ceiling — if EventKit hangs, callers see an empty result
rather than a deadlock.

### N.8 Don't package `.mcpb` from a tested DerivedData

`xcodebuild test` injects `XCTest.framework`, `XCUnit.framework`, and
the test bundle's `.xctest` plugin into the host `.app`. The signature
of the resulting `.app` is **not** valid under `codesign -v --strict`,
and macOS TCC refuses to attribute permissions to a strict-invalid
bundle — `requestAccess` returns `denied` with no dialog.

`scripts/package-mcpb.sh` uses its own dedicated
`/tmp/kairos-release-derived` path, does a `clean build` (no `test`),
and aborts if it ever sees `PlugIns/` or `XCTest.framework` inside the
about-to-be-packaged bundle. Keep that guard.

### N.9 Scripting Bridge: batch or die, and rich text has no string

Two traps in one framework.

**Per-property round trips.** Naively looping over `SBElementArray`
messages and reading `.subject` sends one Apple Event *per property per
message* — thousands of round trips on a real mailbox. `MailBridge`
instead batch-fetches with `arrayByApplyingSelector:` (or `valueForKey:`
for scalar properties), which sends **one** event per property regardless
of message count ("get subject of every message of …"). Mail answers
these from its envelope database without loading message bodies; the
54k-message unified inbox resolves in a couple of seconds. Never touch
message properties per-item in a loop.

**Rich text bodies.** A message's `content` is declared as `rich text`,
which exposes paragraphs/words/characters but no plain-string property.
The trick is to evaluate the object specifier itself: `[[msg content]
get]` makes Mail coerce and return the text — at runtime the result is
an `NSString`. Type-check it anyway; on failure the tool returns
`"(body unavailable)"` rather than garbage. Coerced HTML mail arrives
littered with U+FFFC placeholders and NBSPs — `normalizeBody:` strips
them before the text reaches the LLM.

Batch-fetched arrays may contain `NSNull` for missing values, and the
parallel property arrays are only index-aligned as of fetch time — the
`StrAt`/`DateAt`/`BoolAt` helpers sanitize the former, and `mail_read`
re-verifies the live subject before returning a body to catch the latter.

### N.10 Automation TCC (Apple Events) — a fourth kind of permission

The mail tools need the **Automation** permission (`kTCCServiceAppleEvents`),
which behaves differently from Calendar/Contacts/Reminders in every way
that matters:

1. **No resource-access flag.** Xcode 26's resource-access capability has
   no `ENABLE_RESOURCE_ACCESS_APPLE_EVENTS` (the full list: audio input,
   bluetooth, calendars, camera, contacts, location, photos, printing,
   USB). Like reminders, the hardened-runtime entitlement
   `com.apple.security.automation.apple-events` is declared manually in
   `Kairos.entitlements`, and the usage string is
   `INFOPLIST_KEY_NSAppleEventsUsageDescription` in build settings.
2. **Per-target, prompted on first event.** The permission is granted per
   *target app* (Mail), and the prompt fires on the first Apple Event
   sent — not at launch, and `AppDelegate` must not chain it with the
   other three: sending the event **launches Mail.app**. `MailBridge`
   settles it lazily via `AEDeterminePermissionToAutomateTarget`
   (`askUserIfNeeded=YES`) on the first mail tool call, launching Mail in
   the background (`NSWorkspaceOpenConfiguration.activates = NO`) if it
   isn't running (`procNotFound`).
3. **Reset name is different.** `tccutil reset AppleEvents
   com.elarity.ES-Kairos` — not `Mail`, not `Automation`.
4. **10 s event timeout.** `SBApplication.timeout` is set to 600 ticks so
   a hung Mail yields an error instead of deadlocking the work queue —
   same ceiling philosophy as the reminders semaphore (N.7).

### N.11 Composing mail via Scripting Bridge — ceremony and safety wiring

The write tools (v1.4.0) collect several hard-won behaviors:

1. **Outgoing message creation** follows Apple's SBSendEmail idiom:
   `[[[mail classForScriptingClass:@"outgoing message"] alloc]
   initWithProperties:…]`, then add to `outgoingMessages`, then append
   typed `to recipient` / `cc recipient` objects. `content` accepts a
   plain string inside the make-event's properties record — no rich
   text object needed at creation time.
2. **Drafts** use the AppleScript idiom `close … saving yes`
   (`closeSaving:MailSaveOptionsYes savingIn:nil`) — the unsent message
   lands in Drafts. There is no explicit "save to drafts" command.
3. **Reply** uses `replyOpeningWindow:NO replyToAll:` so threading
   headers are Mail's problem, not ours. Setting the body afterward
   assigns a plain NSString through the `MailRichText *`-typed setter —
   SB marshals it exactly like AppleScript's `set content to`. If
   Mail's "quote original message" preference pre-filled a quote, the
   reply body goes above it.
4. **Reply recipients are previewed, not guessed.** A reply to a
   message goes to its *sender* (or reply-to) — which for a message in
   Sent is yourself, and in general may differ from what the LLM
   assumes. The two-phase flow creates a throwaway reply, reads the
   recipients Mail actually resolved, discards it unsent
   (`closeSaving:MailSaveOptionsNo`), shows them in the dialog, and
   only then recreates and sends. Field-verified: the dialog surfaced
   an iCloud reply address where Gmail was expected.
5. **The send dialog is click-only.** `SendConfirmWindowController`
   deliberately gives Send no key equivalent: the dialog steals
   keyboard focus when it appears, and a Return keystroke already in
   flight from typing must never send email. Escape cancels; a second
   dialog arriving while one is on screen is auto-declined, never
   queued. The bridge's `sendMessageTo:…` sends unconditionally — the
   dialog in MCPServer is the one and only gate, so never call the
   bridge's send/reply-confirmed paths from new code without it.

### N.12 unreadCount lies under mailbox categorization

Mail's mailbox-level `unreadCount` property tracks the *badge*, and with
mailbox categorization enabled (macOS Sequoia+) the badge only counts
the Primary category. Field-verified: the unified inbox reported
`unreadCount = 0` while three unread Promotions/Updates-category
messages sat in it with `readStatus = false`. Per-message `readStatus`
is ground truth.

`mailbox_list` therefore computes `inbox_unread` from a single batched
`readStatus` fetch over the unified inbox (~1–2 s on a 54k-message
store, envelope-DB served — dragon N.9). The per-account mailbox counts
still come from `unreadCount` — batching flags for every mailbox would
be dozens of extra events for a cosmetic listing — so the tool
description tells the LLM those may undercount and to trust
`mail_list unread_only` when it matters.

# ES Kairos MCP server

A macOS MCP server that lets Claude read and write your Calendar,
Reminders, and Contacts — through Apple's own EventKit and Contacts
frameworks — and read your Apple Mail via Scripting Bridge. Every
deletion pops a native confirmation dialog; identity is semantic
(`title + calendar + start`, `title + list + due`,
`subject + sender + date`) so the LLM never has to handle opaque UUIDs.
Mail access is read-only: Claude can list, search, and read messages,
but nothing in your mailboxes can be modified, sent, or deleted.

## Install

1. **Download [`ES_Kairos.mcpb`](./ES_Kairos.mcpb)** and double-click it.
   Claude Desktop installs it as a connector.
2. **Quit and reopen Claude Desktop.** On first launch you'll see three
   macOS permission prompts in sequence (Calendar, Contacts, Reminders).
   Approve all three.
3. Try it out:
   - *"What's on my calendar today?"*
   - *"What reminders are due today?"*
   - *"Find Mary's phone number"*
   - *"Add a reminder to call the dentist tomorrow at 2pm"*
   - *"Move the 3pm meeting on Friday to 4pm"*
   - *"Anything unread in my inbox?"*

   The first **mail** question triggers one more permission prompt —
   a macOS Automation dialog asking to allow ES Kairos to control
   Mail — and may launch Mail.app in the background. This happens on
   first use rather than at install, and only if you use the mail tools.

## Tools

| Tool | Description |
|---|---|
| `datetime_now` | Current local date & time (ISO 8601, weekday, timezone) |
| `calendar_list` | All calendars |
| `events_in_range` | Events in a date window |
| `event_search` | Substring search across title, location, notes |
| `event_create` | Create a new event |
| `event_update` | Update by `(title, calendar, start)` |
| `event_delete` | Delete with native confirmation dialog |
| `reminder_lists` | All reminder lists |
| `reminders_today` | Reminders due today + overdue (morning brief) |
| `reminders_in_range` | Reminders due in a date window |
| `reminder_search` | Substring search across title and notes |
| `reminder_create` | Create with optional due/priority/notes; `#tags` in title/notes become native Reminders tags |
| `reminder_update` | Update by `(title, list, due)` |
| `reminder_complete` | Mark completed (reversible) |
| `reminder_delete` | Delete with native confirmation dialog |
| `contact_search` | Search contacts by name |
| `ask_user` | Native text-input popup |
| `mailbox_list` | Mail accounts and mailboxes with unread counts |
| `mail_list` | Recent messages in a mailbox, newest first (read-only) |
| `mail_search` | Substring search across subject and sender |
| `mail_read` | Full message by `(subject, sender, date)`; body as plain text |

## Troubleshooting

**A permission prompt didn't appear.** macOS TCC sometimes silently
drops a request when another is in flight. Reset and relaunch:

```sh
tccutil reset Calendar com.elarity.ES-Kairos
tccutil reset Contacts com.elarity.ES-Kairos
tccutil reset Reminders com.elarity.ES-Kairos
```

Then fully quit Claude Desktop (Cmd-Q) and reopen.

**Mail tools say permission is denied.** The mail tools use a separate
Automation permission that is requested on first use, not at launch.
Grant it under **System Settings → Privacy & Security → Automation →
ES Kairos → Mail**, or reset it to re-trigger the prompt:

```sh
tccutil reset AppleEvents com.elarity.ES-Kairos
```

**Uninstall.** Claude Desktop → Settings → Connectors → ES Kairos →
Remove. Optionally clear TCC entries with the commands above.

**Where things live.** Logs are at
`~/Library/Logs/Claude/mcp-server-ES Kairos.log`; the installed app is
at `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.kolja-wawrowsky.es-kairos/server/`.

## For developers

Full developer documentation, threading model, packaging scripts, and
the "New Dragons" of macOS TCC are in [`ES Kairos/README.md`](./ES%20Kairos/README.md).
Source builds:

```sh
bash scripts/smoke-test.sh      # build + stdio handshake check
xcodebuild test -project "ES Kairos.xcodeproj" -scheme "ES Kairos" \
  -destination 'platform=macOS' -derivedDataPath /tmp/kairos-derived
bash scripts/package-mcpb.sh    # produce ES_Kairos.mcpb at repo root
```

## License

MIT.

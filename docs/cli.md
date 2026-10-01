# CLI & AI

Move Awake to Applications and enable **Allow CLI & AI tasks** in its menu.
The `awake` command is installed automatically.

## Terminal

```sh
awake run -- swift test
awake watch --pid 12345
awake status
awake --help
```

`run` follows a command; `watch` follows an existing process. Both release their
session when the work ends. Your command keeps its output and exit code.

| Option | Meaning |
| --- | --- |
| `-b`, `-c`, `-a` | Battery, power adapter, both |
| `--battery-floor 20` | Reserve 0–80% battery; 0 disables protection |
| `--for 2h` | Duration: seconds, minutes, hours or days |
| `--until 2026-10-01T18:00:00+02:00` | Date with timezone |
| `--unlimited` | No duration limit; still ends with the task |

Choose one power mode and one stop condition. App limits always apply.
Reaching a limit ends protection, not your command. `status --json` is available.

## AI agent setup

Close your agent, then run its command once:

| Agent | Install |
| --- | --- |
| **Codex** | `awake setup codex` |
| **Claude Code** | `awake setup claude` |
| **Cursor** | `awake setup cursor` |
| **Gemini CLI** | `awake setup gemini` |
| **Other** | [Manual connection below](#other) |

Restart the agent and accept its normal hook approval if asked. Setup installs
the skill and task hooks together. Existing settings are kept, with a private
`.awake-backup-*` copy beside the settings file. Invalid or linked files are
left untouched, as are paths writable by another user through permissions or ACLs.
Setup also stops if a configuration directory is replaced while the change is in
progress. A failed setup or removal restores the previous settings and skill files.
Custom configuration locations need manual setup.

During a task, Awake uses **both power sources and a 20% battery reserve**,
including while the agent thinks. Stricter app limits still apply. The last task
to finish releases the hold. A manual **Keep awake** session always takes priority.

To remove an integration: `awake setup codex --remove` (replace the agent name).
App uninstall also removes integrations installed this way. Backups are retained
for recovery; other settings and hooks are preserved. A failed removal is rolled back
so a retry starts from the prior complete installation.

These integrations need a local agent with lifecycle hooks. If your agent misses
a cancellation event, click **Stop** in Awake; exiting the agent also releases
its holds. Work detached beyond a turn needs its own task tracking.

### Other

Copy [SKILL.md](../skills/awake/SKILL.md) into your agent’s skill folder.
Connect its real task start, finish and cancellation events to `awake hook other`.
Pass this JSON on standard input:

```json
{"hook_event_name":"Begin","session_id":"conversation-123","turn_id":"task-456"}
```

Send `End` with the same IDs on completion or cancellation; `SessionEnd` with the
session ID when closing the conversation. Without task events, use `awake run`
for individual commands. An open agent window is not an active task.

Hook references: [Codex](https://developers.openai.com/codex/hooks),
[Claude](https://code.claude.com/docs/en/hooks), [Cursor](https://cursor.com/docs/hooks),
[Gemini](https://geminicli.com/docs/hooks/reference/).

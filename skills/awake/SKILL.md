---
name: awake
description: Keep this Mac awake for the whole agent task using the installed Awake lifecycle hooks.
---

# Awake

Installed lifecycle hooks start protection with the task and end it when the task
finishes. Keep them active through thinking and tool calls. Wait for delegated
work before ending the turn. Never create dummy work to extend a session.

Use both power sources and a 20% battery reserve, within stricter user limits.
Each task releases only its own hold; the last finished task ends protection.
A manual Keep awake session takes priority: never change or stop it.

Do not change preferences, use sudo, rearm protection or reacquire a stopped hold.
Use `awake status` if uncertain. If setup is missing, report it rather than
claiming protection. Never read transcripts to infer activity.

[One-command setup and other agents](https://github.com/oviron/Awake/blob/main/docs/cli.md#ai-agent-setup).

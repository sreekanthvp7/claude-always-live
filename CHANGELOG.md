# Changelog

## v1.2.1 — 2026-11-19
- Linux, run without `sudo`: the second download now times out and retries
  instead of hanging silently, and says to use `| sudo bash` if GitHub is slow.

## v1.2.0 — 2026-11-19
- **Several people on one server.** The installer asks how people use Claude:
  1. one Claude account per Linux user, or
  2. extra people's Claude accounts on the *same* Linux user (same home and
     files, each signs in with their own account and sees only their own
     sessions).
- New commands: `claude-live account add | login | remove | list`,
  `claude-live --account <name> …`, and `claude-as <name>`.
- Helper scripts are swapped in safely, so re-running the installer doesn't
  disturb sessions that are running.
- The installer shows its version.

## v1.1.0 — 2026-11-19
- **Sign-in during install:** if a user isn't signed in, the installer asks
  them to sign in right away.
- **Waits for sign-in:** the device no longer gives up after 20 tries; it
  connects by itself as soon as the user signs in.
- **Every 5 minutes:** picks up new sessions (terminal or desktop app) and
  restarts any live session that stopped.

## v1.0.0 — 2026-11-19
- One installer for Linux (systemd) and macOS (launchd).
- Remote Control device per user, so the machine shows under *Devices*.
- Sessions used in the last 30 days kept live and reconnected after reboots.
- Start-up questions answered automatically; older autostart services
  disabled.

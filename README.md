# claude-always-live

Keep Claude Code sessions live on your servers and Macs. Every session stays
connected to Remote Control, comes back by itself after a reboot, and the
machine shows under **Devices** in the Claude app so you can start new
sessions on it from your phone.

## What the script does

For each user you choose, it:

1. Installs **tmux** and **Claude Code** if they are missing, and if a user
   isn't signed in, asks you to sign in right there (use the same Claude
   account as your phone app).
2. Starts a **Remote Control device** for that user, so the machine appears
   under *Devices* in the Claude app.
3. Finds that user's sessions used in the last 30 days (up to 8 by default)
   and keeps each one **live with Remote Control on**, in its own tmux session.
4. **Every 5 minutes** picks up new sessions (started in a terminal or the
   desktop app) and restarts any live session that stopped.
5. Sets this up as background services (systemd on Linux, launchd on macOS),
   so after every reboot the device and all sessions reconnect on their own.
6. Answers Claude's start-up questions ("trust this folder?",
   "enable Remote Control?") automatically, so nothing waits at a prompt.
7. Turns off older Claude autostart services at boot, if it finds them.

Sessions stay live until you remove them with `claude-live remove`.
Running the script again is safe: it updates everything, keeps your session
list, and never starts a session that is already open.

## Install — one command for every machine

Latest version: see [CHANGELOG.md](CHANGELOG.md). To install a fixed
version, put the tag in the link instead of `main`, e.g. `.../v1.2.0/install.sh`.

Linux servers (Ubuntu, Debian, RHEL/Rocky/Alma, Fedora, openSUSE), AWS / Google
Cloud / Azure VMs, and Macs all use the same command:

```bash
curl -fsSL https://raw.githubusercontent.com/sreekanthvp7/claude-always-live/main/install.sh | bash
```

The script checks which system it is on:

- **Linux:** asks for sudo itself and sets up every user you choose (systemd).
- **macOS:** run it as the Mac user, **without** sudo (launchd). Turn on
  automatic login (System Settings → Users & Groups) so it starts after a
  restart; that isn't possible while FileVault is on.
  Uninstall: `bash install.sh --uninstall`

It asks a few questions; pressing Enter keeps the default:

| Question | Default | Notes |
|---|---|---|
| Users to set up (Linux) | users who already use Claude | Leave out service accounts |
| Permission mode | `auto` | Recommended. Never `bypassPermissions` |
| Max live sessions per user | based on RAM, max 8 | ~300-450 MB each |
| Keep sessions used within N days | 30 | |
| Keep the Mac awake (macOS) | yes | |
| Start now | yes | |
| How people use Claude (Linux) | 1 | 1 = own Linux user each, 2 = extra accounts on the same user |

## After install

```bash
# Link the machine to your Claude account: sign in once per user, with the
# SAME account as your Claude phone app. Open the link it prints, sign in,
# paste the code back. The device and sessions then start by themselves.
sudo -iu <user> claude auth login

# If the server had an older Claude autostart, stop it once
# (the script already disabled it for the next boot)
sudo systemctl stop claude-remote

# Check everything is running (as the user)
claude-live list
```

## More than one person on a server

The installer asks how people use Claude on the server:

| Choice | How it works | When to use |
|---|---|---|
| **1** – one account per Linux user | Each person gets their own Linux user (`sudo adduser ravi`) and signs in with their own Claude account | Best: separate files and permissions |
| **2** – several accounts on the same user | Extra people sign in with their own Claude account but work as the same Linux user (e.g. `ubuntu`), same home and files | When everyone must work in the same folders |

Either way, each person's sessions show **only in their own Claude app**,
and the server shows under their *Devices* (e.g. `edify03-ubuntu-ravi`).

With choice 2, as that Linux user:

```bash
claude-live account add ravi      # Ravi signs in with HIS Claude account
claude-live account list
claude-as ravi                    # Ravi uses Claude in a terminal
claude-live --account ravi list   # Ravi's live sessions
claude-live account remove ravi   # stop Ravi's device and sessions
```

Note: with choice 2 everyone's Claude can change everyone's files on that
user, and two people editing the same file at once can overwrite each other.

## Day-to-day (as each user)

| Command | What it does |
|---|---|
| `claude-live list` | Show sessions and whether they're running |
| `claude-live sync` | Pick up new sessions used recently |
| `claude-live add <id> [name]` | Keep a specific session live |
| `claude-live remove <name>` | Stop a session for good |
| `claude-live attach <name>` | Open a session's terminal (`Ctrl-b d` to leave) |
| `claude-live start` | Start any sessions that aren't running |
| `claude-live refresh` | What the 5-minute check runs: new sessions + restart stopped ones |

## ⚠️ Take care

- **Your Claude account is now a key to the server.** Anyone who can use it
  (phone, web) can run commands on the machine as those users. Turn on
  2-step verification.
- **`auto` mode acts without asking each time.** A safety check still
  blocks risky actions, but if a user has passwordless sudo, Claude effectively
  has root. Never choose `bypassPermissions` on a server.
- **This runs as root and comes from this repo.** Whoever can push here
  controls what runs on every server that installs it. Keep the GitHub account
  secure, and never commit passwords, keys or tokens (the repo is public).
- **Deleting a session in the app doesn't stop it on the server.** Use
  `claude-live remove <name>`.
- **RAM:** each live session uses about 300-450 MB. Lower "max sessions" on
  small VMs.
- **Login expiry:** if a user's Claude login expires, their sessions stop
  reconnecting until they sign in again (`sudo -iu <user> claude auth login`).
- **Each extra account (choice 2) can run anything that Linux user can.**
  Only add people you trust with that user's files.
- **Only pick real users.** Don't set it up for service accounts (webmin,
  monitoring tools, etc.).
- **macOS:** automatic login means anyone with physical access gets your
  desktop.

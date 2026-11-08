# wl — daily worklog + Jira helper

A tiny command-line tool for people who have to send a daily status like this:

```
Tickets / tasks worked on:
MAR-49126     PR comments for modernized hook
MAR-45531     Review React native upgrade to version 0.88

Still in progress:
MAR-45531     Review React native upgrade to version 0.88

Plan for tomorrow:
MAR-45531     Review React native upgrade to version 0.88

Blockers:
-
```

It fixes two habits:

1. **Jira never knows you started.** When you check out a branch whose name contains a
   ticket key (`feature/MAR-45531-rn-upgrade`), a git hook moves the ticket from *To Do*
   to *In Progress* in Jira and assigns it to you if it is unassigned. Tickets already in
   progress are left alone, so switching branches is harmless.
2. **You forget what you touched.** Every branch checkout and commit adds the ticket to
   today's log. Things without a branch (PR reviews, validation, meetings) you add with one
   line. `wl report` prints the form above, ready to paste.

Requirements: macOS or Linux, git, python3 (stdlib only, no pip). Jira Server / Data Center
with a Personal Access Token (Jira Cloud also works with `jira_user` + `jira_password` = API token).

---

## Setup (5 minutes)

### 1. Get the files

```bash
git clone <this repo> ~/worklog        # or copy the folder from a friend
cd ~/worklog
```

### 2. Install

```bash
sh install.sh
```

This copies `wl` to `~/.local/bin`, adds that folder to your PATH, and presets the Jira URL
to `https://jira.alinma.com`. Another Jira? `JIRA_URL=https://jira.example.com sh install.sh`.

You can also pass your repos to install the git hooks in the same step:

```bash
sh install.sh ~/code/app-one ~/code/app-two
```

Open a new terminal (or `source ~/.zshrc`) so `wl` is found.

### 3. Connect Jira

```bash
wl setup
```

Create the token in Jira: your avatar (top right) → **Profile** → **Personal Access Tokens** →
**Create token**. Paste it when asked. It is saved only in `~/.config/worklog/config.json`
(permissions 600, never leaves your machine). `wl config test` confirms the login.

### 4. Install the git hooks

Inside each repo you work in:

```bash
wl install-hooks
```

- Works with **husky** repos: when `core.hooksPath` points at `.husky/`, the hook files go there
  and are added to `.git/info/exclude`, so they never show up in `git status` or get committed.
- Existing `post-checkout` / `post-commit` hooks are kept; the wl call is appended.
- The hooks never fail a git command. If `wl` is missing they do nothing.

That's it. From now on `git checkout -b feature/MAR-12345-thing` logs the ticket and moves it in Jira.

---

## Daily use

| You did | Command |
|---|---|
| Created / switched to a ticket branch | nothing, the hook logs it |
| Reviewed a PR, tested something, no branch | `wl add MAR-49126 PR comments for modernized hook` |
| Started a task without a branch | `wl start MAR-45531 Review RN upgrade` (logs + Jira In Progress) |
| Finished something today | `wl done MAR-49126` |
| Will start something tomorrow | `wl plan DF-25589` |
| Got blocked | `wl block waiting on backend for X` (`wl block -` clears) |
| Forgot to log all day | `wl scan` (reads today's git activity in your repos) |
| Want Jira's view too | `wl sync` (tickets assigned to you updated today) |
| End of day | `wl report --copy` → paste into the form |

Other: `wl log` (what is recorded), `wl report yesterday`, `wl note KEY new text`, `wl rm KEY`,
`wl jira KEY` (status), `wl remind 17:30` (Sun–Thu macOS reminder that copies the report), `wl remind off`.

### How the report is built

- **Tickets / tasks worked on**: everything logged today, in the order first seen.
- **Still in progress**: the above minus `wl done`, minus tickets Jira reports as Done.
- **Plan for tomorrow**: `wl plan` tickets, plus everything still in progress (unless `wl unplan`).
- **Text**: your `wl add` note if you wrote one, otherwise the Jira summary.

### Settings

```bash
wl config show
wl config set auto_transition false     # log only, never touch Jira
wl config set assign_to_me false
wl config set in_progress_names '["In Progress","In Development"]'
wl config set insecure_ssl true         # only if python rejects a corporate certificate
```

Data lives in `~/.local/share/worklog/days/<date>.json`, one small JSON file per day.
Debug log: `~/.local/share/worklog/wl.log`.

---

## Sharing with your team

- Put this folder in a git repo (GitHub/Bitbucket) and send the link; everyone runs steps 1–4.
- Updating: `git pull && sh install.sh` (config and data are untouched).
- Uninstall: `rm ~/.local/bin/wl`, delete the two hook files `wl install-hooks` wrote
  (`.git/hooks/post-*` or `.husky/post-*`), and `rm -rf ~/.config/worklog ~/.local/share/worklog`.

## Files

| File | Purpose |
|---|---|
| `wl` | the whole tool (Python 3, stdlib only) |
| `install.sh` | copies `wl` to `~/.local/bin`, fixes PATH, optional hook install |
| `README.md` | this guide |

## Even better, if you can get a Jira admin

Jira Automation has a **Branch created** trigger when Jira is linked to the git host
(Bitbucket / GitHub for Jira). A rule *Branch created → Transition issue to In Progress* covers
every developer on push, no install needed. The local hook here works the moment you create
the branch and needs no admin rights, so the two complement each other.

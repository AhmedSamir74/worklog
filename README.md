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

1. **Jira never knows you started.** When you **create** a branch whose name contains a
   ticket key (`git checkout -b feature/MAR-45531-rn-upgrade`), a git hook moves the ticket
   from *To Do* to *In Progress* in Jira and assigns it to you if it is unassigned.
   Switching to a branch that already exists never touches Jira.
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

### When Jira is updated, and when it is not

| Command | Daily log | Jira |
|---|---|---|
| `git checkout -b feature/MAR-123-x` or `git switch -c feature/MAR-123-x` | logged | To Do → In Progress, assigned to you if unassigned |
| `git checkout feature/MAR-123-x` (branch already exists locally) | logged | untouched |
| `git checkout feature/MAR-123-x` (first local copy of a branch that is already on the remote, e.g. a colleague's) | logged | untouched |
| `git branch feature/MAR-123-x` now, check it out later | logged on checkout | untouched (use `wl start MAR-123`) |

Each created branch triggers Jira exactly once. A ticket that is already past *To Do* is never moved.
Prefer the old behaviour, where every switch can start a ticket? `wl config set jira_trigger any_checkout`.

---

## Daily use

| You did | Command |
|---|---|
| Created a ticket branch | nothing, the hook logs it and starts it in Jira |
| Switched to an existing ticket branch | nothing, the hook logs it (Jira untouched) |
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

### Stopping the automation when you don't want it

Sometimes you want a branch without Jira noticing (a spike, a branch for a colleague's ticket,
a quick experiment). From the narrowest to the widest switch:

| Scope | How |
|---|---|
| This one command, log the branch but leave Jira alone | `WL_NO_JIRA=1 git checkout -b feature/MAR-1-spike` |
| This one command, hooks do nothing at all | `WL_SKIP=1 git checkout -b feature/MAR-1-spike` |
| Until you say otherwise (default: Jira only, logging continues) | `wl pause` … `wl resume` (`wl pause all` turns the hooks off too) |
| This repo never touches Jira | `git config worklog.jira false` (`git config worklog.enabled false` disables the hooks here) |
| Never touch Jira from any repo | `wl config set auto_transition false` |

Already moved a ticket by mistake? Put it back:

```bash
wl jira transitions MAR-12345      # shows the moves Jira allows from the current status
wl jira move MAR-12345 "To Do"
```

Tip for zsh users: `alias gcbn='WL_NO_JIRA=1 git checkout -b'` gives you a one-word opt-out.

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

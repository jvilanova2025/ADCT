# AD Cleanup Tool

An interactive PowerShell tool for finding stale computer and user accounts in on-prem
Active Directory. Review what it finds, pick which accounts to disable, and
optionally move the disabled ones into an organizational unit (OU) of your
choice.

## Security and disclaimer

This script was checked with an AI-assisted code review for common bugs,
security issues, exposed secrets or personal data, and suspicious links. As a
best practice, read through it yourself and try it in a non-production
environment first. It is provided as-is, with no warranty. See the LICENSE
file for the full legal disclaimer.

The launcher runs the script with `-ExecutionPolicy Bypass`, which lifts
PowerShell's script-blocking for that single launch only. It changes no
system-wide setting.

Follow your organization's security practices and access controls when storing
the tool and its logs.

## Safety

- The tool contains no delete commands. It only disables and moves accounts.
- Accounts matching a service or admin account keyword are flagged during review
  but remain selectable. You choose whether to include them, and you can add your
  own keywords.
- The tool excludes critical built-in accounts from the list: `krbtgt`
  accounts, the built-in Administrator and Guest, domain controllers, managed
  service accounts, and other critical system accounts. Inspect the script for
  the full list.
- Every run writes its own time-stamped log file.
- Any step that disables or moves accounts requires typing "yes" in full.

## Requirements

- Windows with a desktop. The tool uses pop-up selection windows, so it will not
  run on a server without a desktop or in a text-only remote session.
- The RSAT Active Directory PowerShell tools. On Windows 11: Settings > System >
  Optional features > Add a feature > "RSAT: Active Directory Domain Services and
  Lightweight Directory Services Tools". This option is available only when you
  are signed in as an administrator.
- A domain-joined computer that can reach a domain controller, and a domain
  account with permission to disable and move accounts.

## How to run

The `Run-ADCleanupTool.bat` launcher handles Windows' script permissions and is
provided for convenience. Keep it in the same folder as the `adct.ps1` script and
run it as an administrator. Advanced users can run `adct.ps1` directly from
PowerShell instead.

## First run

The first run walks you through a one-time setup of four questions: where to look
for user accounts, where to move them once disabled, and the same two questions
for computers. Your answers are saved in `ADCleanupTool.settings.json`, in the
same folder as the script. Change them anytime from the Settings menu.

## Sharing

The script itself never retains any organizational data. Anything specific to
your environment lives only in the `ADCleanupTool.settings.json` settings file
and the log files it writes. To share the tool, point people to this project's
GitHub page rather than sending files, so no personal settings or logs travel by
mistake. The recipient runs their own first-run setup.

## Version

0.1.0 (September 2026)

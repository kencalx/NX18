# Security

## Reporting a problem

Please report a security problem privately, not in a public issue or discussion: use **[Report a vulnerability](https://github.com/kencalx/NX18/security/advisories/new)** on this repository's Security tab. You'll get a reply there, and the report stays private until a fix is out.

Useful to include: what the problem is, the NX 18 commit or release, the steps to reproduce it, and what someone could do with it.

## What counts

- The app or the host doing something it shouldn't with a player's device, files or accounts: reading or writing outside its own folders, running code from a game's files outside the guest, leaking data off the device.
- The build scripts or packing tools running something unexpected from a file they read.
- Secrets or personal data in the repository or in logs that "Share log" sends.

Game bugs, crashes and performance problems go in a normal issue.

## Never send

Game files, keys, title keys or saves, in a report or anywhere else. Only legally owned and acquired games are supported, and nothing from them is needed to report a security problem.

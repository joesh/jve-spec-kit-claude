# JVE Bug Reporter — Privacy Consent (v1)

JVE can send anonymous information to its developer so he can see how
many people use it, prioritize bugs by platform, and respond to
reproducible crashes.

## What JVE sends

Whenever you launch JVE (or press F12 to file a bug):

- An anonymous install ID (a UUID generated on this machine; never
  tied to your name, email, or account).
- The JVE build version (a 7-character git short SHA).
- Your operating system and version (e.g. "Darwin 24.6.0").
- Your CPU architecture (e.g. "arm64") and model (e.g. "Apple M2 Pro").
- The number of physical and logical CPU cores; on Apple Silicon, the
  performance- and efficiency-core counts.
- Your system memory size in MB.
- Your GPU vendor, model, memory size, and API (e.g. "Apple / Apple
  M2 Pro GPU / 22016 MB / Metal").
- Your country (e.g. "US") — resolved on the server from your IP
  address; the raw IP is hashed and not retained.
- Your timezone (e.g. "America/Los_Angeles") — also resolved on the
  server.

When you file a bug report, additionally:

- The title and description you typed.
- A 5-minute slideshow of your JVE window (the `Text only` checkbox
  on the submission dialog excludes this).
- A log of the last commands you ran in JVE.
- Recent log lines (5-minute window).
- A list of any file paths or URLs that appeared in those logs.

## What JVE does NOT send

- Your username, hostname, or any other identifier tied to a personal
  account.
- Your IP address (the server resolves country + timezone from it
  during the request and immediately discards it).
- The contents of any project file (`.jvp`), media file, or anything
  on your filesystem outside what the bug report explicitly captures.
- Telemetry of any kind beyond the items listed above.

## Choosing "Decline"

If you decline, JVE will not send any of the above. F12 will respond
with "Bug reporting is disabled" and no network traffic leaves your
machine on the bug-reporter's behalf. To re-enable bug reporting,
delete `~/.jve/install_id.json` and relaunch JVE (a future build will
expose this as a Preferences → Privacy toggle).

## Versioning

This is **v1** of the consent text. If JVE ever changes the set of
information it collects, the version bumps and you'll see this dialog
again before the new collection begins.

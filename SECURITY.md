# Security Policy

Marduk runs with deep hooks into your Mac — an event tap on your keyboard, the Accessibility API, and AppleScript control of your media apps. Security reports are taken seriously and handled with priority.

## Reporting a vulnerability

**Email [spencer@ssdollahite.com](mailto:spencer@ssdollahite.com).** Please do **not** open a public GitHub issue for security problems — public disclosure before a fix puts every user at risk, and Marduk's users are blind and low-vision people who may not see a warning notice quickly.

From inside Marduk, the `:security` command opens a pre-addressed email.

If you prefer GitHub, [private vulnerability reporting](https://github.com/spencer-dollahite/marduk/security/advisories/new) is enabled too — both routes reach the same person.

Include what you can: what you found, how to reproduce it, and what an attacker could do with it. Redact anything personal from logs (`~/Library/Logs/marduk.log` contains text Marduk has spoken).

## What to expect

Marduk is maintained by one person. You'll get a human reply, typically within a few days, and a fix prioritized ahead of feature work. You'll be credited in the release notes if you want to be.

## Supported versions

Only the [latest release](https://github.com/spencer-dollahite/marduk/releases/latest) receives fixes.

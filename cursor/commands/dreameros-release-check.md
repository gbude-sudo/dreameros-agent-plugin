---
name: dreameros-release-check
description: Prepare and verify a DreamerOS release path without crossing the Human Conductor's ship or production gate.
---

Read the repository deployment guide and current branch protection, workflow,
environment-name, and destination evidence. Run local build, lint, typecheck,
tests, and preview checks that are safe in the current scope. Produce a release
packet with exact commands, expected gates, rollback path, and held-back actions.
Do not branch, commit, push, open or merge a pull request, deploy, publish,
change credentials, or touch production unless the Human Conductor authorized
that exact action in the current task.

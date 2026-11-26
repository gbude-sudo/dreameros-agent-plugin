# Security

## Report a problem

If you find a security problem in this plugin or its installers, do not open a
public issue and do not post it in a pull request.

Use the contact page at https://dreameros.app/contact. Say that it is a
security report. Describe what you saw and the steps to see it again.

Do not send passwords, tokens or keys. If your report needs one, say so and
wait for a reply that tells you how to share it.

This file does not promise a reply time.

## What this repository holds

This repository holds installers, skills, boot rules and checks. It holds no
credentials. The plugin connects to the DreamerOS gateway, and the person signs
in through their own client. Nothing here embeds a key.

If you find a credential, a private path or an internal identifier in a file
here, report it the same way. CI runs `scripts/public_surface_gate.py` to catch
new ones.

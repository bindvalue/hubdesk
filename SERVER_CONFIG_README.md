# HubDesk - Server Configuration

Main configuration file:
- custom_client.json

Keys you must set:
- custom-rendezvous-server: HBBS host:port (usually 21116)
- relay-server: HBBR host:port (usually 21117)
- api-server: Pro API URL (HTTPS), if used
- key: public key from HBBS (id_ed25519.pub)

Where this file is loaded from:
- During local/debug run in repository root.
- In packaged app: same directory as hubdesk/rustdesk executable.

Code path that loads this config:
- src/common.rs -> load_custom_client()

Supported config inputs in this fork:
- custom.txt (official signed format)
- custom_client.json (plain JSON for manual customization)

Build output path (Flutter Windows):
- flutter/build/windows/x64/runner/Release/

To apply in final package:
1) Build app.
2) Copy custom_client.json to output folder (same folder as exe).
3) Launch app and verify Settings -> Network.

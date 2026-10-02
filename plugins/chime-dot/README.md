# Chime dot plugin template

This package is intentionally not registered, installed or connected to a server.
Follow [the bridge setup guide](../../docs/chatgpt-dot-bridge.md). In a private copy,
copy `mcp.json.example` to `mcp.json` and replace the reserved `.invalid` URL with
the authorized HTTPS resource URL after OAuth setup. Never add credentials here.

For ChatGPT, register the remote MCP endpoint with OAuth in developer mode and
connect it to a plugin using the supported packaging flow. A local portable MCP
manifest alone does not install a plugin into the existing dot or establish an
event subscription. No marketplace or account settings are changed by this PR.

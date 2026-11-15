# Remote CLI sessions

NotchLite can receive Claude Code and Codex hook events from Linux/macOS PCs over SSH.
The Mac displays each remote session with its machine name in the **Ora** tab and
in activity notifications. Remote sessions cannot approve requests, type into a
local terminal, interrupt processes, or open files on the Mac.

This is session monitoring, not transcript synchronization: token totals remain
local, while subscription limits are account-wide when the provider supplies them.
Prompts, responses, credentials, full tool inputs and transcripts are never sent.
Only agent, state, session ID, working directory, tool name and timestamp are sent.

## How Omarchy does it

[Agent Orchestrator](https://github.com/meviusisback/agent-orchestr#configuration)
uses registered Herdr machines via SSH snapshots and Hermes peer gateways; its
Claude hook records working/waiting/completed states. [Spaces](https://github.com/cyperx84/omarchy-spaces#agent-status)
uses Herdr or installed Claude hooks. Neither discovers arbitrary remote CLI
sessions simply from an account login. NotchLite uses its own small hook protocol
and SSH authentication, without requiring Herdr.

## Connect a remote PC

1. On the Mac, enable **Remote Login** in macOS Sharing and **Hook agenti** in
   NotchLite. Keep NotchLite running. Prefer a private network or VPN.
2. On the remote PC, create a dedicated SSH key (do not reuse a general login key).
   Add its public key to the Mac user's `~/.ssh/authorized_keys` with this prefix,
   replacing `linux-work` with a unique machine label (letters, digits, `.`, `_`, `-`):

   ```text
   restrict,command="/Applications/NotchLite.app/Contents/MacOS/NotchLite --receive-remote-event linux-work" ssh-ed25519 YOUR_PUBLIC_KEY
   ```

   Keep existing keys. `restrict` disables PTY and forwarding; the forced command
   ignores the remote client's requested command. Give each PC its own key and label.
3. On the remote PC, configure a dedicated SSH alias:

   ```sshconfig
   Host notchlite-mac
       HostName YOUR_MAC_ADDRESS
       User YOUR_MAC_USERNAME
       IdentityFile ~/.ssh/notchlite_ed25519
       IdentitiesOnly yes
   ```

   Verify the Mac's host-key fingerprint and register it in `known_hosts` before
   using the hooks. The sender refuses unknown or changed host keys and never prompts.
4. Copy `tools/notchlite-remote.py` to a permanent location on the remote PC.
   Python 3 and OpenSSH are required. Install the hooks:

   ```sh
   python3 /path/to/notchlite-remote.py install --target notchlite-mac --agent claude
   python3 /path/to/notchlite-remote.py install --target notchlite-mac --agent codex
   ```

   The installer backs up settings and preserves other hooks. `--settings PATH`
   supports custom configurations; otherwise it honors `CLAUDE_CONFIG_DIR` or
   `CODEX_HOME`. Repeat installation at the same script location safely.
5. Start a new CLI session, send a prompt, and check **Ora** on the Mac.
   Permission requests are informational: answer them on the remote PC.

## Delivery and limitations

The sender makes one bounded SSH attempt per event (maximum four seconds).
Failures are reported to stderr; they do not fail the agent tool. There is no
replay queue: clocks must be synchronized within 60 seconds. Events received
while NotchLite is closed or its hooks are disabled are not guaranteed to appear.
After a restart, the next hook event restores the session.

This does not inspect remote process IDs. Sessions without further events expire
using the existing 45-minute inactivity limit; completed sessions stay ten minutes.
A disconnected remote PC can therefore leave a temporarily stale session.
Use one machine label per physical source to prevent session ID collisions.

Remove the dedicated public key to revoke access. To remove hooks, remove entries
whose commands invoke this script, preserving all other hook entries (or restore
its backup if no subsequent settings changes need preserving).

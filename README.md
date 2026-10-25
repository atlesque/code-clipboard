# Code Clipboard

A tiny macOS menu bar app that subscribes to an [ntfy](https://ntfy.sh) topic and copies every new
message to the clipboard.

It was made for login codes: a service emails you a one-time code, something forwards it to an ntfy
topic, and by the time you switch windows the code is on your clipboard, ready to paste. It works
for anything short you push to a topic.

## Features

- Lives in the menu bar, starts at login (registered as a Login Item on first launch; toggle it in the menu).
- Streams the topic and reconnects on its own after network drops or sleep, picking up anything it missed.
- Ignores messages older than 10 minutes, so a reconnect never pastes a stale code.
- Shows a notification and flashes the menu bar icon on each copy; **Copy again** re-copies the last one.
- Keeps the access token in the macOS Keychain.
- Works with ntfy.sh or your own self-hosted ntfy server, public or access-controlled topics.

## Requirements

- macOS 13 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- An ntfy topic, and an access token if the topic is protected

## Install

```bash
git clone https://github.com/atlesque/code-clipboard.git
```

```bash
cd code-clipboard && cp .env.example .env
```

Edit `.env`:

| Variable         | Required | Description                                                              |
| ---------------- | -------- | ------------------------------------------------------------------------ |
| `NTFY_TOPIC_URL` | yes\*    | Full topic URL, e.g. `https://ntfy.example.com/email-codes`              |
| `BUNDLE_ID`      | no       | Your own reverse-DNS id (default `com.example.code-clipboard`); also the Keychain service name |
| `NTFY_TOKEN`     | no       | Access token for a protected topic; handed to the app once on install    |
| `SIGN_IDENTITY`  | no       | Code-signing identity; defaults to your first Apple Development / Developer ID certificate, else ad hoc |

\* If you leave it empty, the app asks for the topic URL on first launch.

Then build and install:

```bash
./build.sh
```

This compiles the single Swift file, ad-hoc signs the app, copies it to
`/Applications/Code Clipboard.app` and launches it. Allow notifications when macOS asks.

You can also set or change the topic URL and token later from the menu bar icon
(**Set Topic URL…**, **Set Access Token…**).

## Self-hosted ntfy with access control

If your server uses `auth-default-access: deny-all`, give the app its own read-only user so the
token on your Mac can't publish:

```bash
NTFY_PASSWORD="$(openssl rand -base64 32)" ntfy user add code-clipboard
```

```bash
ntfy access code-clipboard email-codes read-only
```

```bash
ntfy token add --label "Code Clipboard" code-clipboard
```

Put the printed `tk_…` token in `.env` as `NTFY_TOKEN`, or paste it into **Set Access Token…**.
Remove it from `.env` afterwards; the app keeps its copy in the Keychain.

## Test it

Publish a message with a user that has write access to the topic:

```bash
curl -u youruser -d "123456" https://ntfy.example.com/email-codes
```

`123456` should be on your clipboard within a second or two.

## Notes

- The whole message is copied as is (trimmed). Send just the code if you want just the code on the clipboard.
- `build.sh` signs with your Apple Development or Developer ID certificate if you have one (free with an Apple ID in Xcode → Settings → Accounts), or `SIGN_IDENTITY` from `.env`. Without one the app is signed ad hoc, and macOS will ask for Keychain access again after every rebuild. Click **Always Allow** once per build.
- To uninstall: turn off **Open at Login**, quit the app, and delete `/Applications/Code Clipboard.app`.

## License

MIT

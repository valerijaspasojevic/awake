<p align="center">
  <img src="icon/Awake.png" width="160" alt="Awake icon: a hand-drawn coffee cup">
</p>

<h1 align="center">Awake</h1>

<p align="center">A tiny, open-source menu bar app that keeps your Mac awake.<br>
One Swift file, no dependencies, no network access, no tracking.</p>

---

## What it does

Click the ☕ in your menu bar:

| Menu item | What happens |
|---|---|
| **Keep Awake** | Stops your Mac and display from going to sleep until you turn it off. The cup turns solid while it's on. |
| **Keep Awake For…** | Same, but switches off by itself after 30 min, 1, 2, 4 or 8 hours. |
| **Jiggle Mouse** | When you've been idle for ~25 s, nudges the pointer by 1 pixel and back, so chat apps (Slack, Teams…) keep showing you as *Active*. Never interferes while you're using the mouse. |

Awake remembers your choices between launches.

## Install

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/valerijaspasojevic/awake.git
cd awake
./build.sh                    # builds ~/Applications/Awake.app
open ~/Applications/Awake.app
```

To start it automatically, add **Awake** in **System Settings → General → Login Items**.

### Mouse jiggle permission

Moving the pointer requires Accessibility access. The first time you turn on **Jiggle Mouse**, macOS asks for it:
**System Settings → Privacy & Security → Accessibility → enable Awake**, then turn Jiggle on again.
"Keep Awake" alone needs no permissions.

## How it works

- **Keep Awake** holds a power assertion (`kIOPMAssertionTypePreventUserIdleDisplaySleep`), the same mechanism as the built-in `caffeinate -d` command. Releasing it (or quitting the app) lets your Mac sleep normally again. You can check it with `pmset -g assertions`.
- **Jiggle Mouse** checks the system idle time every 30 s and, only if you've been idle, posts two tiny `mouseMoved` events.

Prefer no app at all? macOS has this built in:

```sh
caffeinate -d            # keep awake until Ctrl+C
caffeinate -d -t 3600    # keep awake for 1 hour
```

## Project layout

```
main.swift            the whole app (~150 lines)
build.sh              compiles, bundles and ad-hoc signs Awake.app
icon/make_icon.swift  draws the hand-drawn app icon in code
icon/Awake.png        the rendered icon
```

The app is ad-hoc signed (not notarized), which is fine for apps you build yourself.

## License

[MIT](LICENSE)

# Screenshots

The README expects five PNGs in this folder: `menubar.png`, `projects.png`, `docker.png`,
`ports.png`, `general.png`. Replace one in place to refresh it; the README needs no edit.

`screencapture` needs Screen Recording permission: System Settings → Privacy & Security →
Screen Recording → enable your terminal, then restart it.

## Menu bar popover

The popover closes as soon as it loses focus, so capture the whole screen on a delay and crop
afterwards rather than using interactive mode.

```sh
screencapture -T 6 -x /tmp/portlybar-full.png   # click the menu bar icon during the countdown
```

Crop to the popover, keeping a little of the menu bar above it for context:

```sh
# x,y,w,h in points -- adjust to where the popover landed
screencapture -x -R 1500,20,420,520 docs/screenshots/menubar.png
```

## Settings windows

Open the tab you want, then pick the window interactively. `-o` drops the drop shadow, which
otherwise pads the image with a wide transparent border.

```sh
screencapture -o -w docs/screenshots/projects.png   # press space, then click the window
screencapture -o -w docs/screenshots/docker.png
screencapture -o -w docs/screenshots/ports.png
screencapture -o -w docs/screenshots/general.png
```

## Before committing

Shots are Retina, so they land around 2--4 MB. Shrink them to a sane width for a README:

```sh
sips --resampleWidth 1400 docs/screenshots/*.png
```

Show real projects and containers rather than an empty app, and check the frames for anything
private -- paths under `~`, hostnames, container names, and environment values are all visible
in these views.

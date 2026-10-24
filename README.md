# Sun Dial

A tiny macOS menu bar app. Instead of numbers, it shows the Earth seen from above the North Pole, with the sun and moon circling it at their real positions. Your home sits at the top, so the sun is overhead there at true solar noon, and you can see at a glance which of your places are in daylight and which are asleep.

- **Menu bar icon:** a small ring whose dark half is the night side, with a dot where the sun is.
- **Click it:** the Earth, sun and moon float over your desktop with no window around them. Click elsewhere or press Esc to hide.
- **Drag** the Earth, sun or moon to move the dial anywhere. Right-click the menu bar icon to move it back under the menu bar, or to quit.
- **Places:** hover over the Earth to find your places, add new ones, or change home.

Positions use longitude and real solar time, not time zones. Every place is treated as having 12 hours of light, as if it were always the equinox. The moon uses a low-precision formula good to about a degree.

## Build and run

Needs only the Xcode command line tools (`xcode-select --install`), macOS 13 or later. Builds for Apple silicon Macs.

```sh
./build.sh
open "Sun Dial.app"
```

To install, copy `Sun Dial.app` into `/Applications`.

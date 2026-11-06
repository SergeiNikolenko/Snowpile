# Snowpile

Snow for your Mac. Flakes drift down over everything, pile up on the tops of your windows, on the Dock and along the bottom of the screen, and brush aside as your pointer passes through. Move a window gently and the snow rides along; jerk it and the snow shakes loose. Each Space keeps its own snow.

Hold **Option** and move the pointer along a drift to roll a snowball; it picks snow up and grows as it goes. Let go of Option to set it down. Roll the next ball up to it and it goes on top: two or three balls make a snowman, with a carrot nose, coal eyes and buttons, and twig arms. Snowmen ride along on windows you move gently, fall apart when you jerk the window or swipe through them, and melt when the snow stops or it thaws. **Build a Snowman** in the menu puts a ready one at the bottom of the screen.

Click a drift to scoop up a snowball, or click a snowman to pick the whole thing up, and throw it with a flick. Thrown snow flies under gravity, splats against the sides of windows and the Dock, and knocks over the snowman it hits, ball by ball depending on where it lands. A hard landing bursts a snowball back into loose snow.

Where snow drifts deep, little fir trees grow out of it; they sink back as the drift goes.

Snowpile lives in the menu bar. From the snowflake you can pause the snow, shake it all off, open Settings and check for updates.

## Install

Download `Snowpile-<version>.dmg` from the [latest release](https://github.com/SergeiNikolenko/Snowpile/releases/latest) and drag Snowpile to Applications.

Snowpile is not notarized by Apple yet, so the first launch needs one extra step: open it, then go to System Settings → Privacy & Security and click **Open Anyway**. After that it updates itself.

To let snow settle on the Dock, allow Snowpile in System Settings → Privacy & Security → Accessibility (Settings → Dock → Allow… takes you there). It only reads where the Dock is.

## Settings

- Snow on or off and its mode: flurries, snow, heavy snow, drifting snow, blowing snow, a blizzard, or your own intensity and wind
- Snow like outside: it snows only when it snows in the chosen city, and the mode follows the weather there: flurries to heavy snow by how hard it falls, blowing snow and a blizzard when the wind picks up, drifting snow when the wind lifts snow that already lies. Weather comes from Open-Meteo, or from Yandex Weather when you paste a key for its (paid) Weather API
- Which displays it snows on
- Where snow settles: windows, the Dock, the bottom of the screen
- Brushing snow with the pointer
- Open at login
- Automatic updates

## Build

Requires macOS 13 or later and Xcode 15 or later.

```sh
swift test
./scripts/bundle.sh          # build/Snowpile.app for this Mac
SNOWPILE_UNIVERSAL=1 ./scripts/bundle.sh   # Apple silicon and Intel
```

## Releases

Releases are built by the **Release** workflow (Actions → Release → Run workflow on `main`). It reads the version from `VERSION`, builds a universal app, publishes a DMG and a ZIP to a GitHub release and adds the release to the Sparkle feed kept on the `update-feed` release. Bump `VERSION` before each release.

Updates are signed with an EdDSA key: the public half is in `Resources/sparkle-public-key.txt`, the private half is the `SNOWPILE_SPARKLE_PRIVATE_KEY` repository secret.

## License

MIT

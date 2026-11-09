# Snowpile

Snow for your Mac. Flakes drift down over everything, pile up on the tops of your windows, on text fields inside them, on desktop widgets, on the Dock and along the bottom of the screen, and brush aside as your pointer passes through. Move a window gently and the snow rides along; jerk it and the snow shakes loose. Each Space keeps its own snow.

Snow slides with inertia when a window accelerates, and repeated shaking loosens more of the drift. Lower a window quickly and its snow briefly hangs in the air before falling back. Closing or minimizing a window drops its drift; narrowing one sheds the overhanging edge. Falling sheets break into clumps and powder, while fast flakes leave short trails and swirl around the pointer.

The **Effect** menu also offers rain with splashes and occasional lightning, tumbling sakura petals, autumn leaves, glowing fireflies, and shooting stars. Rain wets window ledges; petals and leaves settle on windows, the Dock, and the screen edge, and lift when brushed. Reduce Motion suppresses lightning.

Hold **Option** and move the pointer along a drift to roll a snowball; it picks snow up and grows as it goes. Let go of Option to set it down. Roll the next ball up to it and it goes on top: two or three balls make a snowman, with a carrot nose, coal eyes and buttons, and twig arms. Snowmen ride along on windows you move gently, fall apart when you jerk the window or swipe through them, and melt when the snow stops or it thaws. **Build a Snowman** in the menu puts a ready one at the bottom of the screen.

Click a drift to scoop up a snowball, or click a snowman to pick the whole thing up, and throw it with a flick. Thrown snow flies under gravity, splats against the sides of windows and the Dock, and knocks over the snowman it hits, ball by ball depending on where it lands. A hard landing bursts a snowball back into loose snow.

Where snow drifts deep, little fir trees grow out of it; they sink back as the drift goes.

Snowpile lives in the menu bar. From the snowflake you can select or pause an effect, shake off snow, open Settings and check for updates.

## Install

Download `Snowpile-<version>.dmg` from the [latest release](https://github.com/SergeiNikolenko/Snowpile/releases/latest) and drag Snowpile to Applications.

Snowpile is not notarized by Apple yet, so the first launch needs one extra step: open it, then go to System Settings → Privacy & Security and click **Open Anyway**. After that it updates itself.

To let snow settle on the Dock and on text fields inside windows, and detect minimized windows, allow Snowpile in System Settings → Privacy & Security → Accessibility (Settings → General → Allow Accessibility… takes you there). It reads window minimization state, Dock geometry, and text-field geometry in the app in front.

## Settings

- Effects: one picker includes Like Outside, all seven snow presets, and all five other effects. Custom Snow exposes intensity and wind
- Like Outside: automatically selects snow or rain from the chosen city's weather, follows precipitation intensity and wind, and enables lightning only for thunderstorms. Dry weather produces no precipitation. Snow can drift when wind lifts snow already on the ground, and positive temperatures accelerate thawing. Decorative effects remain manual
- Weather comes from Open-Meteo, or from Yandex Weather when you supply a key in General → Yandex Weather
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
./script/build_and_run.sh --verify   # build, launch, and check the process
SNOWPILE_UNIVERSAL=1 ./scripts/bundle.sh   # Apple silicon and Intel
```

## Releases

Releases are built by the **Release** workflow (Actions → Release → Run workflow on `main`). It reads the version from `VERSION`, builds a universal app, publishes a DMG and a ZIP to a GitHub release and adds the release to the Sparkle feed kept on the `update-feed` release. Bump `VERSION` before each release.

Updates are signed with an EdDSA key: the public half is in `Resources/sparkle-public-key.txt`, the private half is the `SNOWPILE_SPARKLE_PRIVATE_KEY` repository secret.

## License

MIT

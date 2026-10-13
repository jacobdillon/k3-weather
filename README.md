# k3-weather

Full-screen 3-day weather display for a jailbroken Kindle 3 (Keyboard), written in Zig.

- Today: current temperature, feels-like, high/low, conditions, rain chance, wind, humidity, sunrise/sunset
- Tomorrow and the day after: icon, high/low, conditions, rain chance
- Battery level under the header, which turns bold with "charge me" at 20% or below
- `battery.csv` in the extension folder: one row per poll (`time_utc,epoch,battery_pct,charging,fetch,wifi_ms`) for tracking battery drain over time
- Refreshes every 30 minutes (`INTERVAL` in `weather.conf`) with a full e-ink refresh to clear ghosting
- Wifi saver (on by default): wifi is switched on only while fetching, then off again
- Data from [Open-Meteo](https://open-meteo.com), with no API key. It uses plain HTTP, so the Kindle's outdated TLS and certificate store don't matter.
- Blends three forecast models from one request: NOAA GFS/HRRR, ECMWF and DWD ICON. Numbers are the average of the models that returned data, and weather conditions go to a plurality vote (on a three-way tie, GFS wins). Open-Meteo has no server-side cross-model average; its default `best_match` picks a single model per location.
- Single static ARM binary (musl, soft-float, ARM1136). It needs nothing on the device besides a jailbreak.

## Build

Requires Zig 0.16.

```sh
zig build --release=small
```

This produces a ready-to-copy KUAL extension in `zig-out/extensions/weather/`.

Run the unit tests with `zig build test`.

## Credits and third-party notices

```sh
zig build preview -- --png out.png --lat 40.71 --lon -74.01 --name "New York" --units imperial
```

## Install

1. Install [KUAL](https://www.mobileread.com/forums/showthread.php?t=203326) on the Kindle (needs the jailbreak and the developer-key Kindlet patch).
2. Plug the Kindle in over USB and copy `zig-out/extensions/weather` to `extensions/weather` on the Kindle drive.
3. Edit `extensions/weather/weather.conf` to set your latitude, longitude, display name and units.
4. Eject, open KUAL, and choose **Weather → Start weather display**.

Without KUAL, over SSH or usbnet, run:

```sh
sh /mnt/us/extensions/weather/bin/weather.sh start   # or: stop
```

## Using it

| Key | Action |
| --- | --- |
| Home or Back | exit and return to the normal Kindle UI. Press a key once more if the old screen doesn't repaint. In sleep mode, slide the power switch first. |
| M | switch the bottom half between the next two days and MBTA departures (only when MBTA rows are configured) |
| Any other key | refresh now |

While it runs, the launcher:

- stops the screensaver from triggering (`preventScreenSaver`), so the Kindle stays awake
- pauses the stock UI process (`killall -STOP cvm`) so it doesn't draw over the forecast

Both are undone when the app exits, and wifi is switched back on.

With `WIFI_SAVER=1`, the app runs `lipc-set-prop com.lab126.wifid enable 1` before each fetch and retries for up to 60 seconds while the network comes up. It switches wifi off again afterwards. The log records how long each connection took. Set `WIFI_SAVER=0` to leave wifi on all the time.

### Sleep mode (`SLEEP=1`, experimental, off by default)

Sleep mode is off by default because wake-ups are unreliable so far: with the stock UI paused, powerd sometimes suspends before the wake-up alarm can be set, and then the Kindle oversleeps until powerd's own alarm about 9 minutes later. The rest of this section describes how it works when it does.

Between updates the Kindle goes into deep sleep and wakes itself on a timer. The forecast stays on screen while it sleeps, because e-ink holds its image without power.

1. After each update the app puts the Kindle into its screensaver, using the same command a power-switch press sends.
2. About a minute later powerd reports "ready to suspend". In that window the app asks powerd for a wake-up (`rtcWakeup`) at the next update time, then redraws the forecast.
3. powerd suspends the Kindle. The timer wakes it, the app fetches and redraws, and the cycle repeats.

While the Kindle sleeps, the keyboard does nothing. To use it:

- Slide the power switch. The app refreshes the forecast, then waits a minute for a key press.
- Press Home within that minute to exit the app. Any other key refreshes again.

`sleeptest.sh` (**Weather → Sleep/wake test** in KUAL) records how this was worked out. Setting the alarm directly doesn't work: as powerd suspends the device, it overwrites the alarm with its own. Asking powerd through `rtcWakeup` does work. Measured on a Kindle 3, powerd wakes the device about 64 seconds after the requested time, counted from when it suspends, so the app requests a little early.

If a fetch fails, the last good forecast stays on screen with an `OFFLINE (reason)` note under the header. If no data has loaded yet, the app retries every minute.

## Troubleshooting

The log is at `extensions/weather/weather.log`. Its first line describes the framebuffer, and every key press is logged with its key code.

- **Screen looks like a photo negative:** add `EXTRA_ARGS="--no-invert"` to `weather.conf`. The K3's 4-bit framebuffer stores white as 0 and the app assumes that by default.
- **Image drawn but the screen never changes:** the app tries the `FBIO_EINK_UPDATE_DISPLAY` ioctl first, then `/proc/eink_fb/update_display`. Check the log for errors.
- **Home doesn't exit:** look up the key code in the log and add it to the `.quit` case in `Inputs.wait` in `src/main.zig`.
- **`No data yet (Resolve)`:** wifi isn't connected. Connect once from the normal UI before starting.

## Layout

```
src/main.zig     config/args, key input, the App: update + the awake/asleep run loops
src/forecast.zig weather model, Open-Meteo fetch, multi-model blend
src/mbta.zig     MBTA rows, predictions fetch/parse, the Board shown on screen
src/ui.zig       screen layout: renders a plain Screen value, no I/O
src/kindle.zig   Kindle integration: battery, wifi, powerd sleep/wake, battery CSV
src/sys.zig      libc helpers: logging, clocks, files, shell commands
src/canvas.zig   600x800 grayscale canvas, anti-aliased shapes, TrueType text
src/icons.zig    procedural weather icons + WMO code descriptions
src/net.zig      minimal HTTP/1.0 client on libc sockets, plain and TLS (std.crypto.tls)
src/display.zig  einkfb framebuffer output (4/8 bpp) and a PNG writer for previews
src/ttf.c        shim over vendor/stb_truetype.h
assets/          DejaVu Sans fonts and MBTA root certificates (embedded in the binary)
kindle/          KUAL extension: menu, launcher script, config
```

`std.net` is avoided on purpose. The K3's 2.6.26 kernel rejects `SOCK_CLOEXEC` in `socket()`. musl's libc wrappers retry without it, but Zig's raw-syscall networking doesn't.

## MBTA departures

Press **M** to switch the bottom half of the screen between the next two days and live MBTA departures. Each configured row shows the next 3 departure times. Configure up to 3 rows in `weather.conf`:

```sh
MBTA1="place-cntsq Red 1 Red to Alewife @ Central"
MBTA2="place-cntsq Red 0 Red to Ashmont/Braintree @ Central"
MBTA_INTERVAL=300   # refresh every 5 min while the MBTA view is showing
VIEW=mbta           # bottom half at start: mbta or days
```

Each row is `STOP ROUTE DIRECTION LABEL`:

- Stop IDs come from `https://api-v3.mbta.com/stops?filter[route]=<route>`. Subway stations use their `place-…` ID.
- Direction is `0` or `1`. On the Red Line, `0` is Ashmont/Braintree and `1` is Alewife. On buses, `0` is outbound and `1` is inbound.

In sleep mode the Kindle still sleeps between refreshes, so the times can be up to about 5 minutes old. They're shown as clock times, which stay correct even when the screen is a few minutes old.

Some technical details:

- **HTTPS.** MBTA's API is HTTPS-only. The app uses Zig's own TLS client (`std.crypto.tls`) on its libc socket code. It verifies the certificate against Amazon's root certificates plus the Starfield root that cross-signs them, all embedded in `assets/mbta-roots.pem`; the Kindle's own certificate store is years out of date. If MBTA changes certificate authority, update that file.
- **No API key.** Without a key, MBTA allows 20 requests a minute, and the app makes 3 per refresh, plus one stop lookup per row at startup.
- **Unknown stop IDs.** The predictions endpoint silently ignores an unknown stop and returns departures for other stops on the route. So the app looks up each stop once, and a typo shows up on screen as `Unavailable (UnknownStop)` instead of wrong times.

## License

The code is MIT-licensed; see [`LICENSE`](LICENSE). The bundled fonts, `stb_truetype.h` and root certificates keep their own terms, listed below.

## Credits and third-party notices

- **Weather data:** [Weather data by Open-Meteo.com](https://open-meteo.com/), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The app uses the free API, which is for non-commercial use; see [Open-Meteo's terms](https://open-meteo.com/en/terms). The forecast shown is a blend of the NOAA GFS/HRRR, ECMWF IFS and DWD ICON models, all served by Open-Meteo.
- **Transit data:** departure predictions come from the [MBTA V3 API](https://www.mbta.com/developers/v3-api), used under the [MassDOT Developers License Agreement](https://www.mass.gov/files/documents/2017/10/27/develop_license_agree_0.pdf). This project is not affiliated with, endorsed by, or supported by the MBTA or MassDOT.
- **Fonts:** DejaVu Sans and DejaVu Sans Bold (`assets/DejaVuSans*.ttf`) are embedded in the binary. They are derived from Bitstream Vera, © Bitstream, Inc.; DejaVu's own changes are public domain. Their full license is in [`assets/DejaVu-LICENSE`](assets/DejaVu-LICENSE).
- **Font rendering:** [`stb_truetype.h`](vendor/stb_truetype.h) by Sean Barrett, under MIT or public domain at your choice. Its license text is at the end of the file.
- **Root certificates:** `assets/mbta-roots.pem` contains Amazon's and Starfield's publicly distributed root CA certificates, taken from the standard CA bundle.

Kindle is a trademark of Amazon.com, Inc. This project is not affiliated with Amazon.

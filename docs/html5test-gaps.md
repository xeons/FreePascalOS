# html5test.co: results and the gaps left

[html5test.co](https://html5test.co/) (release 9 of the test, 588 points)
detects the HTML features a browser has and scores them. This file
records how the engine does on it, what was fixed to get there, and
what is still missing, by size, so that follow-up work can be planned.

How to measure: `make webbrowse`, then

    build/tools/webbrowse -t 30 -e 'document.querySelector("#score h2").textContent' https://html5test.co/

For the per-feature list, serve a copy of the page whose `showResults`
also runs the page's own `Calculate` per item and logs the misses (the
coordinator's scratch copy did that); `scripts/compare-sites.py` with a
one-line list (`html5test https://html5test.co/`) compares the
rendering with the installed Firefox.

## Score

| | Score | Notes |
|---|---|---|
| Before | none | The page never showed a score: its inline script was a syntax error (`<!--` after a tab), and once that was fixed the test waited forever for images made by `new Image()` |
| After the two blockers | 241 / 588 | The test runs to the end and shows every result |
| After this work | 273 / 588 | |
| After Canvas 2D, OffscreenCanvas and ImageBitmap | 300 / 588 | canvas 24 of 25 (all but hit regions, which the standard dropped), offscreen 3 of 3 |
| Firefox 160 on the same machine | 547 / 588 | the reference `compare-sites.py` uses |

The page renders close to Firefox's (`compare-sites.py`: 2.2 at 1280 x
800, 6.6 at 400 x 800 where most of the difference is the text that
differs: the score and the browser's name). What is left visibly: the
"5" of the logo sits 7 px higher (relative positioning of inline boxes,
`position: relative; top: 7px` on a `<strong>`, is not done), and rows
are a few pixels shorter because Firefox on this machine takes Noto
Sans Mono for `monospace` (the system takes Liberation Mono).

Per category after this work (canvas and offscreen after the canvas
work that followed):

| Category | Points | Category | Points |
|---|---|---|---|
| parsing | 5 / 5 | elements | 31 / 33 |
| form | 65 / 66 | components | 2 / 10 |
| location | 0 / 20 | sensors | 0 / 5 |
| hardware | 0 / 10 | output | 0 / 10 |
| input | 5 / 10 | video | 0 / 33 |
| audio | 2 / 30 | streaming | 0 / 5 |
| responsive | 15 / 15 | svg | 2 / 4 |
| canvas | 24 / 25 | 3d | 0 / 25 |
| offscreen | 3 / 3 | animation | 5 / 8 |
| communication | 25 / 40 | streams | 6 / 6 |
| rtc | 0 / 45 | interaction | 5 / 19 |
| performance | 11 / 12 | native | 0 / 1 |
| resource | 7 / 7 | security | 21 / 32 |
| payments | 0 / 5 | offline | 0 / 13 |
| storage | 10 / 35 | files | 15 / 15 |
| scripting | 32 / 32 | other | 9 / 9 |

## What was fixed

Blockers (the page could not finish):

- **HTML-like comments** (libjavascript, `Js.Lexer`): the fast path for
  ASCII above `/` skipped the `<!--` check, so `<!--` after white space
  was a syntax error. JavaScriptTest `27-html-like-comments.js`.
- **Images outside the document** (libweb, `Web.Loading.Images`,
  `Web.Loading.Observers`): `new Image()` never loaded, so its load or
  error event never came and the test's background tasks never ended.
  Nodes gained pending activity (`TNode.BeginPendingActivity`), which
  keeps their wrappers and listeners alive outside the document until
  the event fires. WebLoadTest `detached images`.

Rendering:

- Table columns: a cell spanning columns gives what it needs beyond
  them in proportion to the columns' widths, its maximum to columns
  without a fixed width first (`Web.Layout.Table`; render fixture
  `tables-colspan`).
- Helvetica and Helvetica Neue are Nimbus Sans (URW's Helvetica clone,
  as fontconfig and Firefox take them); webbrowse reads the system font
  configuration (`userland/etc/fonts.conf`).
- The preload scanner no longer fetches again what the parser already
  asked for (main.css and base.js came twice).

Features (each a real implementation with tests):

| Feature | Points | Where |
|---|---|---|
| Value sanitization of number, range, date, month, week, time, datetime-local; valueAsNumber for them, valueAsDate, stepUp, stepDown; typed entry for the date and time fields | 14 (form.*.ui) | `Web.Dom.InputValues`, `Web.Dom.FormControls`, `73-input-dates.js` |
| Range inputs as sliders (pointer and keys), meters and progress bars showing their values | (part of the above) | `WebView.Engine.Ranges.inc`, `Web.Paint.Raster` |
| fieldset.elements | 1 | `Web.Bindings.HtmlElements` |
| Images' natural size, complete, currentSrc, width/height of an image not rendered; getComputedStyle's resolved width and height | 1 (svg.image) | `Web.Dom.ImageRequests`, `Web.Script.Layout` |
| EventSource | 5 | `62-eventsource.js` |
| Pointer events, pointer capture, mouseenter/mouseleave | 5 | `WebView.MouseEvents`, `Web.Dom.PointerCapture` |
| ClipboardEvent, DataTransfer (string data), copy/cut/paste events | 5 | `Web.Dom.DataTransfer`, `WebView.ClipboardEvents` |
| Access keys (Alt+Shift) and accessKeyLabel | 1 | `Web.Dom.AccessKeys` |
| Canvas 2D: the whole CanvasRenderingContext2D (paths and Path2D, transforms, fill rules, strokes, dashes, gradients incl. conic, patterns, shadows, every compositing operator and blend mode, clips, text, drawImage, ImageData, filters), toDataURL (PNG, JPEG, WebP) and toBlob | 24 (canvas.*) | `Web.Canvas.*`, `Web.Bindings.Canvas`, `76-canvas.js`; docs/Architecture.md "Canvas" |
| OffscreenCanvas (workers too), ImageBitmap and createImageBitmap, ImageBitmapRenderingContext | 3 (offscreen.*) | `Web.Canvas.Elements`, `Web.Script.NativeCanvas` |

The date and time "custom user interface" points are the test's
inference from sanitization: the fields can be typed into (their edit
text kept apart from the value as browsers do) but there is no picker
yet (see below).

## Credited by the test with less behind it

- `audio.loop`, `audio.preload` (2 points): the attributes reflect, but
  media do not play (see Video and audio).
- `elements.semantic.ping` (1 point): the attribute reflects, no pings
  are sent.

## Lost to the test's browser detection, not to the engine

The test asks WhichBrowser what browser it runs in; our user agent
(`Mozilla/5.0 (X11; FreePascalOS x86_64) AppleWebKit/537.36 (KHTML,
like Gecko) libweb/1.0 Safari/537.36`) is "an unknown browser based on
Webkit" and not a desktop, so every result under `interaction.dragdrop`
and `interaction.editing` is marked unconfirmed and scores nothing,
whatever the engine does (12 points: contentEditable 5,
isContentEditable 1, draggable 1, designMode 1, execCommand and
queryCommand* 2, :read-write/:read-only 2). The user agent is not
changed to pass as another browser. Real gaps behind these: designMode,
execCommand and the queryCommand* methods, drag and drop events, and
editing of contenteditable content beyond what the web view does.

## The gaps left, by size

Points are what each costs on html5test (588 in all).

### Small (a day or less)

- `form.file.files` (1): input type=file has no `files`: needs the file
  chooser in the browser (`ChooseFileToOpen` exists), a FileList of
  File objects, and multipart/form-data submission. (Medium with the
  upload part.)
- `performance.sharedWorker` (1): SharedWorker; workers are realms on
  the window's thread, so one shared by several windows needs a worker
  thread or a host realm per site.
- `svg.foreignobject` (1): SVGForeignObjectElement and HTML content
  inside SVG drawn by the layout (only once it is drawn).
- Date and time pickers (no points of their own): the fields are typed;
  a calendar and a time spinner in the web view would complete them.

### Medium (days)

- **CSP enforcement** (`security.csp10` 3, `security.csp11` 2):
  Content-Security-Policy is parsed (`Web.Fetch.ContentSecurityPolicy`)
  but only upgrade-insecure-requests is applied. Needs script-src
  (inline, nonces, hashes, 'strict-dynamic', eval through a libjavascript
  host hook), style-src, img-src, connect-src, default-src fallback,
  report-only, violation reports and SecurityPolicyViolationEvent.
- **WebSocket** (`communication.websocket.*` 15): RFC 6455 over
  libhttp's connections (TLS, HTTP/1.1 upgrade; RFC 8441 over HTTP/2
  later); in the browser it has to go through the network service
  process like fetch.
- **Custom elements** (`components.custom` 4): CustomElementRegistry
  (define, get, whenDefined, upgrade), constructors through HTMLElement,
  the reactions (connected, disconnected, adopted, attributeChanged),
  is="".
- **Web Animations** (`animation.webanimation` 3): Element.animate,
  Animation, KeyframeEffect, document.getAnimations over the CSS
  animation engine (`Web.Style.Animations`), CSSAnimation and
  CSSTransition objects.
- **Fullscreen API** (`output.requestFullScreen` 5): element and
  document fullscreen, :fullscreen, events; the browser window going
  fullscreen through the web view's IPC.
- **Pointer Lock** (`input.pointerLock` 3): needs relative pointer
  motion and a pointer grab from the display server.
- **Notifications** (`output.notifications` 5): needs a desktop
  notification service in the OS first.
- **Relative positioning of inline boxes** (no points; the visible
  difference on this page): `position: relative` offsets on inline
  boxes in layout, painting and hit testing.
- **registerProtocolHandler** (`offline.registerProtocolHandler` 1):
  browser settings and the navigation hook.
- **Spell checking** (`interaction.spellcheck` 2): the spellcheck
  attribute with a dictionary and the web view's underlines.

### Large (weeks)

- **Canvas hit regions** (`canvas.hittest` 1): addHitRegion was dropped
  from the standard (no browser has it); not done.
- **Shadow DOM** (`components.shadowdom` 4): attachShadow, slots,
  retargeting, :host and ::slotted, shadow-including tree order in
  style, layout and events.
- **IndexedDB** (`storage.indexedDB.*` 25): the database engine on
  disk (per origin), transactions, key ranges, cursors, indexes,
  structured clone of values (Blob, ArrayBuffer).
- **Video and audio** (`video.*` 33, `audio.element` 18,
  `streaming.mediasource` 5): media elements that play: demuxers (MP4,
  WebM, Ogg), codecs (H.264, VP8/VP9, AV1, AAC, Opus, Vorbis, FLAC, MP3,
  PCM), audio output through the OS mixer, canPlayType, text tracks
  (WebVTT), Media Source Extensions.
- **Web Audio** (`audio.webaudio` 5): the audio graph on top of audio
  output.
- **WebGL and WebGL 2** (`3d.webgl*` 20) and **WebXR** (5): needs the
  OS's 3D graphics (see "Planned: 3D graphics" in TODO.md).
- **WebRTC and media capture** (`rtc.*` 22, `media.*` 23): peer
  connections (ICE, DTLS, SRTP, SCTP data channels), getUserMedia
  (camera and microphone drivers), getDisplayMedia, MediaRecorder.
- **Service workers and push** (`offline.*` 12): service worker
  registration, the fetch interception in the network service, the
  Cache API, push messages.
- **WebAssembly** (`native.webassembly` 1): a Wasm engine in
  libjavascript.
- **MathML** (`elements.mathml` 2): MathML Core layout.
- **SVG filters** (`svg.filters` 1): the filter effects in libsvg and
  CSS filter().
- **Web Authentication, Credential Management, Payment Request**
  (`security.authentication` 3, `security.credential` 3, `payments` 5).
- **Speech** (`audio.speechrecognition` 3, `audio.speechsynthesis` 2).
- **Device APIs** (`location.*` 20, `sensors.api` 5,
  `hardware.bluetooth` 5, `hardware.usb` 5, `input.getGamepads` 2):
  each needs the OS service or driver behind it (location, sensors,
  Bluetooth, USB device access, game controllers) before the web API
  can be honest.

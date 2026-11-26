{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The display server's protocol: what programs and the display server
  say to each other over a channel.

  A program connects to the port WindowingPortName and sends
  RequestHello; the server answers EventWelcome with the screen's size,
  DPI and scale. Every message, either way, is one TWindowMessage; the
  fields a kind uses are listed with it.

  A window's contents are the program's to draw: in a section (shared
  memory) of SurfaceWidth x SurfaceHeight pixels ($AARRGGBB, a line
  after another), whose handle goes with RequestCreateWindow or
  RequestSetSurface. After drawing, the program sends RequestDamage with
  the rectangle it changed; the server puts it on the screen. The frame
  around it (title bar, borders, buttons) is the server's.

  Positions on the screen are in logical units (1/96 inch), turned into
  pixels with the scale (LogicalToPixels); sizes of surfaces and
  positions within a window are in pixels, which is what is drawn.

  There may be several displays, side by side in one desktop: display 0
  (the first, whose size, DPI and scale EventWelcome gives) at the left,
  then the others. Each has its own scale, and a place on the desktop
  in logical units is on the display it falls on, at that display's
  scale (RequestDescribeDisplay tells where each is). A window is at the
  scale of the display it is on: moved onto another it is told
  (EventScaleChanged for it) and gives itself a surface for that scale.

  A window can have an owner, another window of the same program: it
  stays above it. A disabled window (RequestEnableWindow) is never
  activated and gets no input; a click on it activates the window it
  owns instead (a modal dialog). The owner can be changed later
  (RequestSetOwner). When a display's scale or mode changes each window
  on it hears EventScaleChanged and gives itself a new surface; every
  program hears when display 0 changes. A program hears when its window
  is shown or hidden, whoever did it (EventVisibilityChanged: its owner
  was hidden, or it was minimized).

  The pointer's shape over a window's client area is the program's to
  choose (RequestSetPointerShape: for the whole client area, or for up to
  MaximumPointerAreas rectangles of it); over the frame the server picks
  it (resize arrows on the borders). The mouse's settings (speed,
  acceleration, left-handed buttons) are the server's, read and changed
  with RequestGetMouseSettings and RequestSetMouseSettings; the
  keyboards' layout and repeat with RequestGetKeyboardSettings and
  RequestSetKeyboardSettings (the server passes them to the kernel).

  One program may be the shell (RequestRegisterShell; a second is
  refused while the first lives): it hears about the top-level windows
  of every other program (EventShellWindowChanged, EventShellWindowGone)
  and may activate, minimize, restore, maximize or ask to close any of
  them (RequestManageWindow, which other programs may use on their own
  windows). It reserves strips of the displays for itself (a taskbar:
  RequestSetWorkArea); what is left is a display's work area, which
  maximized windows fill and new windows are placed in
  (RequestDescribeWorkArea). A window can be a desktop (WindowDesktop):
  it stays below every other window. Any program may put a small icon
  with a tooltip in the shell's notification area
  (RequestSetNotificationIcon); the shell hears of it
  (EventNotificationIconChanged) and draws it.

  The shell may also take keys for the whole desktop (RequestRegisterHotkey:
  Ctrl+Shift+Escape opens the task manager): pressed, whichever window
  is active, such a key goes to the shell (EventHotkey) and to no window.
  Any program may list the other programs' top-level windows with the
  process each belongs to (RequestListWindows: a task manager), and
  manage those of programs of the same user (root: all of them) as the
  shell does.

  The clipboard is the server's: a program offers data in one or more
  formats (RequestOfferData) and gives each when it is first asked for
  (EventDataRender, RequestProvideData), so nothing is made that nobody
  pastes; the server keeps what it was given, also after the program
  ends. Others ask which formats there are and for one of them
  (RequestDescribeClipboard, RequestAskData); programs may watch it
  change (RequestWatchClipboard). A drag between windows works the same
  way (DataSourceDrag): the program starting it gives its data at once
  and the server follows the pointer, telling the windows under it
  (EventDragEnter, EventDragOver, EventDragLeave, EventDrop), which
  answer what a drop would do.

  The session manager (running as root) may lock the screen
  (RequestLockScreen): then only its windows - the lock screen - are
  drawn and get input, whatever other programs do, until it unlocks it.
  Any program may ask how long nobody has touched the keyboard or the
  pointer (RequestDescribeIdle), which is what locks the screen after a
  while.

  A window may have an icon, drawn at the left of its title bar and on
  the shell's taskbar button: a name of the icon theme
  (RequestSetWindowIcon: the server reads /usr/share/icons/NAME.ico and
  draws the size nearest the frame's, shrunk or grown to it), or
  pictures the program gives (RequestSetWindowIconPictures: a few sizes
  in a section). A window with none shows its owner's (a dialog its
  main window's), else that of the program's first window owned by
  none that has one, else the theme's generic picture (or nothing). The
  shell and the window list hear a number that changes whenever a
  window's icon does (the icon's version), and ask for the icon itself
  (RequestDescribeWindowIcon).
}
unit Windowing.Protocol;

{$mode objfpc}
{$H+}

interface

const
  WindowingPortName: PChar = 'display';
  ProtocolVersion = 1;
  TitleCapacity = 96;

  { --- Requests: program to server ------------------------------------- }

  { Value: ProtocolVersion; Flags: HelloAnswersPings if the program
    answers EventPing from its message loop. Answered by EventWelcome. }
  RequestHello = 1;
  { Left, Top: where (logical units, the client area's top left);
    SurfaceWidth, SurfaceHeight: the client area's size in pixels; Flags:
    Window*; Text: the title; Code: the window that owns it (0: none),
    which it stays above. Handle: the surface's section. Answered by
    EventWindowCreated (Window: its number). It starts hidden. }
  RequestCreateWindow = 2;
  RequestDestroyWindow = 3;
  { Value: 1 to show (and activate, unless WindowNoActivate), 0 to hide. }
  RequestShowWindow = 4;
  { Left, Top: the client area's new place (logical units). }
  RequestMoveWindow = 5;
  { Text: the new title. }
  RequestSetTitle = 6;
  { SurfaceWidth, SurfaceHeight: a new surface for the window (after
    EventResized). Handle: its section. }
  RequestSetSurface = 7;
  { Left, Top, Width, Height: what changed, in surface pixels. }
  RequestDamage = 8;
  { Brings the window to the front and gives it the keyboard. }
  RequestActivate = 9;
  { Value 1: the window gets every pointer event until Value 0 (while a
    button is held on a control, say). }
  RequestSetCapture = 10;
  { Value 0: the window is disabled (not activated, no input: the owner
    of a modal dialog); 1: enabled again. }
  RequestEnableWindow = 11;
  { Window 0; Code: a new scale in percent (100 to 400) for the display
    numbered Value; Flags: DisplayRemember to keep it. Its windows are
    told (EventScaleChanged); answered by EventDisplayDescribed for that
    display. }
  RequestSetScale = 12;
  { Window 0; Code: a display's number. Answered by EventDisplayDescribed. }
  RequestDescribeDisplay = 13;
  { Window 0; Code: a display's number; Width, Height: a mode from its
    list, in pixels; Flags: DisplayRemember to keep it. Windows on it keep their places (moved onto it if it
    shrank) and hear if their scale changes; answered by
    EventDisplayDescribed (the size it has then). }
  RequestSetDisplayMode = 14;
  { Window 0; Code: a display's number; Value: the number of one of its
    modes (from 0, smallest first). Answered by EventDisplayMode. }
  RequestDescribeDisplayMode = 15;
  { Code: the window that owns it from now on (0: none), another window
    of the same program that is not owned by it. The server raises the
    window above its new owner if it was below. }
  RequestSetOwner = 16;
  { Code: Pointer*, the shape; Value: the area (0: the whole client
    area, 1 to MaximumPointerAreas: a rectangle of it, which wins over
    area 0 where it lies, a higher number over a lower); Left, Top,
    Width, Height: that rectangle in surface pixels (an empty one takes
    the area away). }
  RequestSetPointerShape = 17;
  { Window 0. Answered by EventMouseSettings. }
  RequestGetMouseSettings = 18;
  { Window 0; Code, Value, Flags as in EventMouseSettings: the new
    settings (any program may change them, as the display's settings
    would be; they last until the server ends: they are the user's, and
    the user's own settings keep them, Windowing.MouseSettings).
    Answered by EventMouseSettings with what they are now. }
  RequestSetMouseSettings = 19;
  { Window 0: this program asks to be the shell. Answered by
    EventShellRegistered; then the program hears about every other
    program's top-level windows (EventShellWindowChanged for each one
    there is, and as they change) and the notification icons. }
  RequestRegisterShell = 20;
  { Window 0, from the shell only; Code: a display's number; Left, Top,
    Width, Height: its work area from now on (logical units of the
    desktop): the rest is the shell's (a taskbar). Kept as the strips
    left at each edge, in logical units, so it follows a new scale or
    mode. Maximized windows on it are maximized again. Not answered. }
  RequestSetWorkArea = 21;
  { Window 0; Code: a display's number. Answered by EventWorkArea. }
  RequestDescribeWorkArea = 22;
  { Window: a window of this program, for the shell any top-level window
    of another, and for any program a top-level window of a program of
    the same user (root: any); Code: Manage*, what to do with it. }
  RequestManageWindow = 23;
  { Window 0; Code: a number this program picks for the icon; Value: 1
    shows it (or changes it), 0 takes it away; Flags: NotificationPicture*,
    what it shows; Text: its tooltip. A program's icons go when it ends. }
  RequestSetNotificationIcon = 24;
  { Window 0. Answered by EventWindowListed for each top-level window
    (framed, owned by no window, not a desktop) of the other programs of
    the same user (root: of every program), then one with Window 0 to
    end the list. }
  RequestListWindows = 25;
  { Window 0, from the shell only; Code: a key (as in EventKey);
    Modifiers: the ones that must be held with it (ModifierShift,
    ModifierControl, ModifierAlt, ModifierAltGr, ModifierSuper of
    Abi.SystemCalls; the locks are ignored); Value: 1 to
    take the key, 0 to give it back. From then on the key pressed with
    exactly those modifiers goes to the shell (EventHotkey), not to the
    active window. Not answered; the keys go when the shell does. }
  RequestRegisterHotkey = 26;
  { Window 0. Answered by EventKeyboardSettings. }
  RequestGetKeyboardSettings = 27;
  { Window 0; Text, Code, Value as in EventKeyboardSettings: the
    keyboards' new layout and repeat (any program may change them, as
    the mouse's; the server asks the kernel, where keys become
    characters, so they last until changed again: the session manager
    gives the user's at login and the system's after,
    Windowing.KeyboardSettings). Answered by EventKeyboardSettings with
    what they are now (the old layout if the kernel has no such one). }
  RequestSetKeyboardSettings = 28;
  { The screen lock (Server.ScreenLock; numbered from 40, a range of its
    own). Window 0, from a program running as root only (the session
    manager); Value 1 locks the screen, 0 unlocks it. While it is
    locked only this program's windows are drawn and get input; every
    other window is hidden behind the lock, cannot be activated or take
    the pointer, and the shell's keys for the whole desktop are
    swallowed. Locking a screen another program has locked is refused,
    unless that program has ended (the screen stays locked until a
    program running as root takes the lock over or unlocks it).
    Answered by EventScreenLock. }
  RequestLockScreen = 40;
  { Window 0. Answered by EventIdleDescribed: how long since the last
    input (a key, the pointer, a button or the wheel). }
  RequestDescribeIdle = 41;
  { Window 0: draws every display again from the windows (after waking
    from suspend, when the display's memory may not have kept its
    picture). Not answered. }
  RequestRepaintDisplays = 42;
  { Window icons (Server.WindowIcons). Window: one of this program's;
    Text: the icon theme's name for its icon (app-terminal: the server
    reads /usr/share/icons/app-terminal.ico; letters, digits, '-', '_'
    and '.' only), '' for none. Replaces pictures given before. Not
    answered; a name with no file shows as no icon. }
  RequestSetWindowIcon = 43;
  { Window: one of this program's; Code: how many pictures (0: none, up
    to MaximumIconPictures); Width: their length in bytes (at most
    MaximumIconPictureBytes); Handle: a section holding them, one after
    another, each as DataFormatBgra (its width and height, each 1 to
    MaximumIconSide, then its pixels). The server copies them (the
    program may close its section) and draws the one nearest the size
    it wants, shrunk or grown to it. Replaces a name given before. Not
    answered. }
  RequestSetWindowIconPictures = 44;
  { Window: one of this program's, or a window it may list or manage
    (RequestListWindows; the shell: any); Code: the size wanted, in
    pixels (1 to MaximumIconSide). Answered by EventWindowIconDescribed. }
  RequestDescribeWindowIcon = 45;

  { The clipboard and drag and drop (Windowing.DataTransfer): data in
    formats (DataFormat*), offered by one program and asked for by
    others. Each offer is one of two sources (DataSource*): the
    clipboard, or the drag going on. Bytes travel in sections, of at
    most MaximumDataBytes. }

  { Window 0; Value: DataSource*; Flags: the formats offered
    (DataFormatBit of each; 0 empties the clipboard); Code: the
    program's own number for the offer (EventClipboardLost names it). For the clipboard
    this program owns it from now on, and the previous owner hears
    EventClipboardLost: a format is asked of it (EventDataRender) the
    first time someone wants it, unless it gave it already
    (RequestProvideData). For a drag: what the RequestStartDrag that
    follows carries. }
  RequestOfferData = 29;
  { Window 0; Value: DataSource*; Code: a DataFormat* of the program's
    offer; Width: its length in bytes (0 to MaximumDataBytes); Handle: a
    section holding them (none for 0 bytes). The server keeps a copy (the
    program may close its section), so the clipboard keeps what was given
    after the program ends. Not answered. }
  RequestProvideData = 30;
  { Window 0; Value: DataSource*; Code: a DataFormat*. Answered by
    EventDataDelivered, at once if the server has the data, or once the
    owner gave it. }
  RequestAskData = 31;
  { Window 0; Value: 1 to hear EventClipboardChanged from now on, 0 to
    stop. }
  RequestWatchClipboard = 32;
  { Window 0. Answered by EventClipboardFormats. }
  RequestDescribeClipboard = 33;
  { Window: the window the drag starts from (button 1 held on it, the
    window captured or not); Code: the effects allowed (DropEffect*);
    Text: what is dragged, shown beside the pointer. The formats are the
    drag offer's (RequestOfferData and RequestProvideData with
    DataSourceDrag, just before). From then on the server follows the
    pointer: windows under it hear EventDragEnter, EventDragOver and
    EventDragLeave (and no pointer events), the one it is let go over
    EventDrop, and this window EventDragFinished. Escape cancels. If
    button 1 is up already, the drop is where the pointer is. }
  RequestStartDrag = 34;
  { Window: the window under a drag; Value: the drag's number; Code: the
    effect a drop there would have (one DropEffect* of those allowed, 0:
    none), shown beside the pointer. }
  RequestAnswerDrag = 35;
  { Window: the window a drag was dropped on; Value: the drag's number;
    Code: what the drop does (a DropEffect*, 0: refused). The window the
    drag came from hears it (EventDragFinished). }
  RequestFinishDrop = 36;
  { Window 0; Value: the number of the EventPing answered. Sent by the
    message loop, so an answer means the program still serves its
    windows. }
  RequestAnswerPing = 46;
  { The pointer lock (Pointer Lock API, games): Value 1 asks for the
    pointer to be locked to the window, which must be active; 0 lets it
    go. While locked the pointer is hidden and stays where it was, and
    the window gets every motion as EventPointerMove with Flags
    PointerMoveLocked and Width, Height the motion in pixels (Left, Top
    staying put); its button and wheel events too. Answered by
    EventPointerLock; the lock ends when the window stops being active,
    is hidden or goes, or the screen locks (EventPointerLock Value 0). }
  RequestSetPointerLock = 47;

  { --- Events: server to program ---------------------------------------- }

  { Width, Height: the screen in pixels; Value: its DPI; Code: its scale
    in percent. }
  EventWelcome = 101;
  { Window: the new window's number. }
  EventWindowCreated = 102;
  { Code: the key (scan code set 1, plus KeyCodeExtended), Value: 1
    pressed, 0 released; Character, Modifiers as in input events. }
  EventKey = 103;
  { Left, Top: the pointer in the window's surface (pixels); Code: the
    buttons held (bit N for button N); Modifiers: the keyboard's (as in
    input events), for every pointer event. }
  EventPointerMove = 104;
  { Left, Top as above; Code: the button; Value: 1 pressed, 0 released. }
  EventPointerButton = 105;
  { Value: wheel steps, positive away from the user. }
  EventWheel = 106;
  { The pointer went out of the window. }
  EventPointerLeave = 107;
  { SurfaceWidth, SurfaceHeight: the size the client area has now (the
    frame was dragged, or the window maximized): a new surface is due. }
  EventResized = 108;
  { Value: 1 the window is active (has the keyboard), 0 not any more. }
  EventActivated = 109;
  { The close button was pressed: the program decides. }
  EventCloseRequested = 110;
  { Left, Top: where the client area is now (logical units): the window
    was moved (by the user, or maximized). }
  EventMoved = 111;
  { Width, Height: a display in pixels; Value: its DPI now; Code: its
    scale in percent. Window 0: display 0 changed (its scale or its mode;
    what new windows start at). Otherwise that window is at this scale
    and DPI now (it moved to another display, or its display's scale or
    mode changed): it wants a new surface of its logical size at the new
    scale (RequestSetSurface). }
  EventScaleChanged = 112;
  { The answer to RequestDescribeDisplay, RequestSetScale and
    RequestSetDisplayMode. Flags: DisplayExists, or 0 if there is no
    such display (nothing else is filled in). Width, Height: its size in
    pixels; Value: its DPI; Code: its scale in percent; Left, Top,
    SurfaceWidth, SurfaceHeight: its place and size on the desktop in
    logical units. }
  EventDisplayDescribed = 113;
  { The answer to RequestDescribeDisplayMode. Width, Height: the mode in
    pixels, 0 if there is no such mode; Flags: DisplayModeCurrent if the
    display has it now. }
  EventDisplayMode = 114;
  { Value: 1 the window is shown now, 0 hidden: by the program, or by the
    server (hidden or shown with its owner, minimized). }
  EventVisibilityChanged = 115;
  { Window 0. Code: the speed, MinimumMouseSpeed to MaximumMouseSpeed
    (NormalMouseSpeed moves the pointer as far as the mouse says);
    Value: the acceleration, 0 (none) to MaximumMouseAcceleration;
    Flags: MouseLeftHanded if the left and right buttons are swapped. }
  EventMouseSettings = 116;
  { The answer to RequestRegisterShell. Value: 1 this program is the
    shell now, 0 another program is. }
  EventShellRegistered = 117;
  { To the shell. Window: a top-level window (framed, owned by no window)
    of another program, which is new or changed; Text: its title; Flags:
    ShellWindow*; Code: the display it is on; Value: the process of the
    program it belongs to; Width: its icon's version (a number that
    changes whenever its icon does, 0 if it never had one: ask for the
    icon with RequestDescribeWindowIcon). }
  EventShellWindowChanged = 118;
  { To the shell. Window: a window it was told about is gone (or is no
    longer a top-level window: it was given an owner). }
  EventShellWindowGone = 119;
  { The answer to RequestDescribeWorkArea. Flags: DisplayExists, or 0 if
    there is no such display; Code: the display's number; Left, Top,
    Width, Height: its work area (logical units of the desktop). }
  EventWorkArea = 120;
  { Window 0, to the shell: the displays were laid out again (a scale or
    a mode changed); their places, sizes and work areas may be new. }
  EventDisplaysChanged = 121;
  { Window 0, to the shell. Code: the icon's number (the server's, the
    same for as long as the icon lives); Value: 1 shown or changed, 0
    gone; Flags: NotificationPicture*; Text: its tooltip. }
  EventNotificationIconChanged = 122;
  { The answer to RequestListWindows, one per window. Window: the
    window (0: the list is over); Text: its title; Flags: ShellWindow*;
    Code: the display it is on; Value: the process its program runs as;
    Width: its icon's version, as in EventShellWindowChanged. }
  EventWindowListed = 123;
  { Window 0, to the shell: a key it took (RequestRegisterHotkey) was
    pressed. Code: the key; Modifiers: as in EventKey. }
  EventHotkey = 124;
  { Window 0. Text: the keyboards' layout (us, uk, de, fr); Code: the
    delay before a held key repeats, in milliseconds; Value: the
    repeats a second. }
  EventKeyboardSettings = 125;
  { Window 0; Value: DataSource*; Code: a format this program offered,
    which someone asks for: it answers with RequestProvideData. }
  EventDataRender = 126;
  { The answer to RequestAskData. Value and Code as asked; Flags:
    DataAvailable if there is such data (else nothing more is filled
    in); Width: its length in bytes; Handle: a section holding them
    (none for 0 bytes), the program's to close. }
  EventDataDelivered = 127;
  { Window 0, to programs watching the clipboard: what it holds changed.
    Flags: the formats on it now (0: empty); Code: 1 if this program owns
    it; Value: the number of changes so far. }
  EventClipboardChanged = 128;
  { The answer to RequestDescribeClipboard, as EventClipboardChanged. }
  EventClipboardFormats = 129;
  { Window 0: another program owns the clipboard now (or it was
    emptied): what this program offered (Code: the offer's number, as
    the program gave it) will not be asked for again. }
  EventClipboardLost = 130;
  { Window: the window under the pointer, which a drag came into. Left,
    Top: the pointer (surface pixels); Flags: the formats; Code: the
    effects allowed; Modifiers: the keyboard's; Value: the drag's number;
    Text: what is dragged. Answered by RequestAnswerDrag. }
  EventDragEnter = 131;
  { As EventDragEnter: the pointer moved over the window, or the
    modifiers changed. Answered by RequestAnswerDrag. }
  EventDragOver = 132;
  { Window; Value: the drag's number: the pointer went out of the window
    (or the drag was cancelled). }
  EventDragLeave = 133;
  { As EventDragOver: the drag was let go over the window. It reads the
    data (RequestAskData with DataSourceDrag) and says what it did
    (RequestFinishDrop). }
  EventDrop = 134;
  { Window: the window a drag started from; Value: the drag's number;
    Code: what the drop did (a DropEffect*; 0: nothing - refused,
    cancelled with Escape, or let go over no window that takes it). }
  EventDragFinished = 135;
  { The answer to RequestLockScreen. Value: 1 the screen is locked now,
    0 not; Code: 1 if this program holds the lock. }
  EventScreenLock = 140;
  { The answer to RequestDescribeIdle. Value: the milliseconds since the
    last input (at most High(LongInt)). }
  EventIdleDescribed = 141;
  { The answer to RequestDescribeWindowIcon. Window: as asked (0 if the
    program may not see it); Flags: WindowIconNamed or
    WindowIconPictures, which the window's icon is (its own, or the
    owner's it shows), 0 if it has none; Text: the icon's name, if
    named; Value: the icon's version; Width, Height: its picture at the
    size asked (0 if none could be made: no icon, or a name with no
    file); Handle: a section of Width x Height pixels (blue, green, red,
    alpha), the program's to close. }
  EventWindowIconDescribed = 142;
  { Window 0; Value: a number for RequestAnswerPing to give back. Sent
    now and then to programs that said they answer (HelloAnswersPings):
    one that has not answered for a while is not responding (its
    windows' titles say so, ShellWindowNotResponding). }
  EventPing = 143;
  { Value: 1 the pointer is locked to the window now, 0 it is not (any
    more, or the request was refused). }
  EventPointerLock = 144;
  { To the shell: the user asked to close Window (its close button,
    Alt+F4, the taskbar), but its program does not respond (it would
    not hear the request): the shell offers to end it. Value: the
    program's process; Text: the window's title. }
  EventShellEndTaskOffered = 145;

  { EventPointerMove's Flags: the motion of a locked pointer. }
  PointerMoveLocked = $01;

  { RequestHello's Flags. }
  HelloAnswersPings = $01;

  DisplayExists = $01;
  DisplayModeCurrent = $01;
  { Flags of RequestSetScale and RequestSetDisplayMode: the server keeps
    the new scale or mode in the system's settings (Display/N/Scale,
    Display/N/Mode) and gives the display it the next time it starts.
    Without it the change lasts until the server ends. }
  DisplayRemember = $01;

  { --- Data: the clipboard, drag and drop -------------------------------- }

  DataSourceClipboard = 0;
  DataSourceDrag = 1;

  { Text, UTF-8. }
  DataFormatText = 1;
  { An image as a PNG file. }
  DataFormatPng = 2;
  { An image as raw pixels: its width and height (32 bits each, little
    endian), then each pixel as blue, green, red, alpha (straight alpha),
    a line after another from the top. }
  DataFormatBgra = 3;
  { Files: a file list (Controls.FileLists: "file-list copy" or
    "file-list cut", then a file URI a line). }
  DataFormatFileList = 4;
  DataFormatCount = 4;

  DataAvailable = $01;
  { The most one format may hold: 64 MiB (a 4096 x 4096 image). }
  MaximumDataBytes = 64 * 1024 * 1024;

  { What a drop does: copies the data, moves it (the place it came from
    loses it), or links to it. }
  DropEffectCopy = $01;
  DropEffectMove = $02;
  DropEffectLink = $04;

  { --- Window icons ------------------------------------------------------ }

  WindowIconNamed = $01;
  WindowIconPictures = $02;
  MaximumIconPictures = 8;
  MaximumIconSide = 256;
  MaximumIconPictureBytes = 1024 * 1024;
  { The longest icon name (it travels in Text). }
  MaximumIconNameLength = TitleCapacity - 1;

  { --- Window flags ----------------------------------------------------- }

  { A title bar and borders. }
  WindowFramed = $01;
  { The borders can be dragged and the window maximized. }
  WindowResizable = $02;
  { Above every other window (a taskbar). }
  WindowTopmost = $04;
  { Showing it, or clicking it, does not take the keyboard. }
  WindowNoActivate = $08;
  { Below every other window, always (the shell's desktop). It can have
    the keyboard but is never raised over other windows. }
  WindowDesktop = $10;

  { --- The shell ---------------------------------------------------------- }

  { What RequestManageWindow does. Activate brings the window forward
    and gives it the keyboard (restoring it if minimized); Minimize hides
    it, the shell keeping it in its list; Restore shows a minimized
    window again, or else gives a maximized one its size back; Maximize
    shows it if minimized and fills its display's work area; Close asks
    its program to close it (EventCloseRequested). A program may manage
    its own windows, the shell any, and any program the windows of the
    programs of its user (root: of all). }
  ManageActivate = 1;
  ManageMinimize = 2;
  ManageRestore = 3;
  ManageMaximize = 4;
  ManageClose = 5;

  { EventShellWindowChanged's Flags. Visible: on the screen; Minimized:
    hidden by minimizing (it comes back from the taskbar); Active: it or
    a window it owns has the keyboard. }
  ShellWindowVisible = $01;
  ShellWindowMinimized = $02;
  ShellWindowActive = $04;
  ShellWindowMaximized = $08;
  ShellWindowResizable = $10;
  { Its program has not answered the server's EventPing for a while: it
    has stopped serving its windows (busy or stuck). }
  ShellWindowNotResponding = $20;

  { What a notification icon shows (drawn by the shell; a click on a
    volume picture opens the shell's volume control, on a network
    picture its list of the network's interfaces). }
  NotificationPictureInformation = 1;
  NotificationPictureWarning = 2;
  NotificationPictureVolume = 3;
  { The network, connected: two linked screens. }
  NotificationPictureNetwork = 4;
  { The volume, muted: the loudspeaker crossed out. }
  NotificationPictureVolumeMuted = 5;
  { The network: obtaining an address (dots of waiting); the link up
    but no address (a warning sign over it); no link (no cable: the
    link crossed out); no network adapter at all (grey screens). }
  NotificationPictureNetworkConnecting = 6;
  NotificationPictureNetworkLimited = 7;
  NotificationPictureNetworkNoLink = 8;
  NotificationPictureNetworkNone = 9;

  { --- Pointer shapes ---------------------------------------------------- }

  PointerArrow = 0;
  { Left and right (a vertical border). }
  PointerResizeHorizontal = 1;
  { Up and down (a horizontal border). }
  PointerResizeVertical = 2;
  { Top left and bottom right. }
  PointerResizeDiagonalDown = 3;
  { Top right and bottom left. }
  PointerResizeDiagonalUp = 4;
  { Where text is typed or selected. }
  PointerTextBeam = 5;
  { The program is busy. }
  PointerBusy = 6;
  { A link or something else to click. }
  PointerHand = 7;
  { Something being moved any way. }
  PointerMove = 8;
  { What is dragged cannot go here. }
  PointerNotAllowed = 9;
  { Picking a point precisely. }
  PointerCrosshair = 10;
  PointerShapeCount = 11;
  { Areas of a window with a shape of their own (RequestSetPointerShape). }
  MaximumPointerAreas = 15;

  { --- Mouse settings ---------------------------------------------------- }

  MinimumMouseSpeed = 1;
  NormalMouseSpeed = 10;
  MaximumMouseSpeed = 20;
  MaximumMouseAcceleration = 10;
  MouseLeftHanded = $01;

type
  TWindowMessage = record
    Kind: LongWord;
    Window: LongWord;
    Left: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    SurfaceWidth: LongInt;
    SurfaceHeight: LongInt;
    Code: LongWord;
    Value: LongInt;
    Character: LongWord;
    Modifiers: LongWord;
    Flags: LongWord;
    { Not sent: where a message received with a handle keeps it
      (Windowing.Connection, TakeMessageHandle). }
    Reserved: LongWord;
    Text: array[0..TitleCapacity - 1] of Char;
  end;
  PWindowMessage = ^TWindowMessage;

{ A length in logical units in pixels at ScalePercent, rounded. }
function LogicalToPixels(Value: LongInt; ScalePercent: LongWord): LongInt;
function PixelsToLogical(Value: LongInt; ScalePercent: LongWord): LongInt;
{ A format's bit in a set of formats (Flags of RequestOfferData). }
function DataFormatBit(Format: LongWord): LongWord;
{ A message of Kind for Window, every other field zero. }
function NewMessage(Kind, Window: LongWord): TWindowMessage;
{ Copies Text into the message (cut short if it does not fit). }
procedure SetMessageText(var Message: TWindowMessage; const Text: string);
{ The message's text, up to its terminating zero (at most
  TitleCapacity - 1 characters). }
function MessageText(const Message: TWindowMessage): string;
{ Whether Name may name a window's icon (RequestSetWindowIcon): not
  empty, at most MaximumIconNameLength characters, of letters, digits,
  '-', '_' and '.', and not starting with '.' (so never a path). }
function IsValidIconName(const Name: string): Boolean;

implementation

function LogicalToPixels(Value: LongInt; ScalePercent: LongWord): LongInt;
begin
  if Value >= 0 then
    Result := (Value * LongInt(ScalePercent) + 50) div 100
  else
    Result := -((-Value * LongInt(ScalePercent) + 50) div 100);
end;

function PixelsToLogical(Value: LongInt; ScalePercent: LongWord): LongInt;
begin
  if ScalePercent = 0 then
    Exit(Value);
  if Value >= 0 then
    Result := (Value * 100 + LongInt(ScalePercent) div 2) div LongInt(ScalePercent)
  else
    Result := -((-Value * 100 + LongInt(ScalePercent) div 2) div LongInt(ScalePercent));
end;

function DataFormatBit(Format: LongWord): LongWord;
begin
  if (Format = 0) or (Format > 31) then
    Exit(0);
  Result := LongWord(1) shl (Format - 1);
end;

function NewMessage(Kind, Window: LongWord): TWindowMessage;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Kind;
  Result.Window := Window;
end;

procedure SetMessageText(var Message: TWindowMessage; const Text: string);
var
  Count: Integer;
begin
  Count := Length(Text);
  if Count > TitleCapacity - 1 then
    Count := TitleCapacity - 1;
  if Count > 0 then
    Move(Text[1], Message.Text[0], Count);
  Message.Text[Count] := #0;
end;

function MessageText(const Message: TWindowMessage): string;
var
  Count: Integer;
begin
  Count := 0;
  while (Count < TitleCapacity - 1) and (Message.Text[Count] <> #0) do
    Inc(Count);
  SetString(Result, PChar(@Message.Text[0]), Count);
end;

function IsValidIconName(const Name: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Name = '') or (Length(Name) > MaximumIconNameLength) or (Name[1] = '.') then
    Exit;
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.']) then
      Exit;
  Result := True;
end;

end.

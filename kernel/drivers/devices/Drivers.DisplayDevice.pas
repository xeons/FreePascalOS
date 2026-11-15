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
  The display devices (/dev/display, /dev/display1, ...): the screens
  for a graphical program.

  A display driver describes each screen it has (TDisplayAdapter: the
  framebuffer, the mode it has, its EDID, what modes it can make and how
  to set one) and RegisterDisplay makes a device of it. The first one
  registered is /dev/display, the one the firmware showed the boot on
  and the text console draws on; the others are numbered from 1.

  Opening a device gives the screen to one program at a time. The
  console's is taken from the console, which goes on drawing into its
  copy of the screen only; closing it, as when the program ends however
  it ends, gives the screen back and the console draws itself again.

  Control requests tell the size, the pitch, the pixel format, the
  physical size, the DPI and the scale, list the modes and set one; the
  framebuffer is mapped into the program (CallMapHandle, offset 0) with
  writes combined.

  Modes: the list is the EDID's timings, the common sizes and the mode
  the display has, as far as the adapter can make them
  (Drivers.DisplayModes). A program may set any of them; closing the
  device gives back the mode the display had when it was opened. So the
  console, which draws at the boot mode's size, always finds the boot
  mode again (a kernel panic taking the screen back sets it too).

  The DPI follows the mode: the display's physical width (from its EDID)
  against the mode's width in pixels; else 96. The kernel option dpi=N
  gives the first display's DPI at its boot mode instead (other modes
  have it in proportion to their width). The scale is the DPI against
  96, to the nearest quarter, at least 100%.
}
unit Drivers.DisplayDevice;

{$mode objfpc}

interface

uses
  Boot.Information;

type
  PDisplayAdapter = ^TDisplayAdapter;
  { Sets the adapter to Width x Height at 4 bytes a pixel; True if it
    took it, with Pitch the bytes from one line to the next. }
  TSetDisplayModeRoutine = function(Adapter: PDisplayAdapter; Width, Height: LongWord; out Pitch: QWord): Boolean;

  TDisplayAdapter = record
    FramebufferPhysical: QWord;
    { The framebuffer memory there is (what limits the modes). }
    FramebufferBytes: QWord;
    { DisplayFormat*. }
    PixelFormat: LongWord;
    { The mode it has now. }
    Width: LongWord;
    Height: LongWord;
    Pitch: QWord;
    HasEdid: Boolean;
    Edid: array[0..EdidBlockSize - 1] of Byte;
    { The largest mode it can make. }
    MaximumWidth: LongWord;
    MaximumHeight: LongWord;
    { nil if the mode cannot be changed (only the one it has is listed). }
    SetMode: TSetDisplayModeRoutine;
    { The driver's own. }
    Context: Pointer;
  end;

{ Makes a display device of Adapter (copied). The first one registered
  is the console's. False if it could not be made. }
function RegisterDisplay(const Adapter: TDisplayAdapter): Boolean;
{ How many displays there are. }
function DisplayCount: LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Memory.Layout,
  Kernel.Options,
  Io.Manager,
  Debug.Output,
  Debug.FramebufferConsole,
  Drivers.Edid,
  Drivers.DisplayModes;

const
  OwnerOnly = $180; { rw------- }
  MinimumDpi = 48;
  MaximumDpi = 960;
  ScaleStepPercent = 25;
  MaximumDisplays = 8;

type
  PDisplay = ^TDisplay;
  TDisplay = record
    Number: LongInt;
    Adapter: TDisplayAdapter;
    Modes: TDisplayModeList;
    Dpi: LongWord;
    ScalePercent: LongWord;
    WidthMillimetres: LongWord;
    HeightMillimetres: LongWord;
    { The dpi kernel option at the boot mode's width (0: not given). }
    OptionDpi: LongWord;
    BootWidth: LongWord;
    { The mode when it was opened, given back on closing. }
    OpenedWidth: LongWord;
    OpenedHeight: LongWord;
    IsOpen: Boolean;
  end;

var
  DisplayDriver: PDriverObject;
  Displays: array[0..MaximumDisplays - 1] of PDisplay;
  RegisteredCount: LongInt;

function DisplayCount: LongInt;
begin
  Result := RegisteredCount;
end;

function DisplayOfDevice(Device: PDeviceObject): PDisplay;
begin
  Result := PDisplay(Device^.Extension);
end;

{ --- DPI ------------------------------------------------------------------ }

procedure ChoosePhysicalSize(Display: PDisplay);
var
  Size: TEdidSize;
begin
  if not Display^.Adapter.HasEdid or not ParseEdid(@Display^.Adapter.Edid[0], Size) then
    Exit;
  Display^.WidthMillimetres := Size.WidthMillimetres;
  Display^.HeightMillimetres := Size.HeightMillimetres;
end;

procedure ChooseDpi(Display: PDisplay);
var
  Width: QWord;
begin
  Width := Display^.Adapter.Width;
  Display^.Dpi := DisplayBaseDpi;
  if Display^.OptionDpi > 0 then
    Display^.Dpi := LongWord((QWord(Display^.OptionDpi) * Width + Display^.BootWidth div 2) div Display^.BootWidth)
  else if Display^.WidthMillimetres > 0 then
    { Pixels per millimetre times 25.4, rounded. }
    Display^.Dpi := LongWord((Width * 254 + QWord(Display^.WidthMillimetres) * 5) div
      (QWord(Display^.WidthMillimetres) * 10));
  if (Display^.Dpi < MinimumDpi) or (Display^.Dpi > MaximumDpi) then
    Display^.Dpi := DisplayBaseDpi;
  Display^.ScalePercent := (Display^.Dpi * 100 + DisplayBaseDpi * ScaleStepPercent div 2) div
    (DisplayBaseDpi * ScaleStepPercent) * ScaleStepPercent;
  if Display^.ScalePercent < 100 then
    Display^.ScalePercent := 100;
end;

procedure ReadDpiOption(Display: PDisplay);
var
  Number: QWord;
begin
  Display^.BootWidth := Display^.Adapter.Width;
  if (Display^.Number = 0) and GetKernelOptionNumber('dpi', Number) and (Number >= MinimumDpi) and
     (Number <= MaximumDpi) then
    Display^.OptionDpi := LongWord(Number);
end;

{ --- Modes ------------------------------------------------------------------ }

procedure ListModes(Display: PDisplay);
var
  Limits: TDisplayModeLimits;
begin
  Limits.MaximumWidth := Display^.Adapter.MaximumWidth;
  Limits.MaximumHeight := Display^.Adapter.MaximumHeight;
  Limits.FramebufferBytes := Display^.Adapter.FramebufferBytes;
  BeginModeList(Display^.Modes, Limits);
  if Display^.Adapter.SetMode <> nil then
  begin
    if Display^.Adapter.HasEdid then
      AddEdidModes(@Display^.Adapter.Edid[0], Display^.Modes);
    AddCommonDisplayModes(Display^.Modes);
  end;
  AddCurrentDisplayMode(Display^.Modes, Display^.Adapter.Width, Display^.Adapter.Height);
  SortDisplayModes(Display^.Modes);
end;

function SetMode(Display: PDisplay; Width, Height: LongWord): LongInt;
var
  Pitch: QWord;
begin
  if (Width = Display^.Adapter.Width) and (Height = Display^.Adapter.Height) then
    Exit(ErrorNone);
  if Display^.Adapter.SetMode = nil then
    Exit(ErrorUnsupported);
  if not DisplayModeIsListed(Display^.Modes, Width, Height) then
    Exit(ErrorInvalidArgument);
  if not Display^.Adapter.SetMode(@Display^.Adapter, Width, Height, Pitch) then
    Exit(ErrorIo);
  Display^.Adapter.Width := Width;
  Display^.Adapter.Height := Height;
  Display^.Adapter.Pitch := Pitch;
  ChooseDpi(Display);
  Result := ErrorNone;
end;

procedure GiveBackOpenedMode(Display: PDisplay);
begin
  if Display <> nil then
    SetMode(Display, Display^.OpenedWidth, Display^.OpenedHeight);
end;

{ The console takes the screen back (a program closed it, or a panic):
  it draws at the boot mode. }
procedure RestoreConsoleMode;
begin
  if (RegisteredCount > 0) and Displays[0]^.IsOpen then
    GiveBackOpenedMode(Displays[0]);
end;

{ --- The device ------------------------------------------------------------- }

function OpenDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Display: PDisplay;
begin
  Display := DisplayOfDevice(Device);
  Display^.OpenedWidth := Display^.Adapter.Width;
  Display^.OpenedHeight := Display^.Adapter.Height;
  Display^.IsOpen := True;
  if Display^.Number = 0 then
  begin
    { Between messages, so no line is half drawn over the program's screen. }
    DebugBeginMessage;
    SuspendConsoleDrawing;
    DebugEndMessage;
  end;
  Result := ErrorNone;
end;

function CloseDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Display: PDisplay;
begin
  Display := DisplayOfDevice(Device);
  if Display^.Number = 0 then
  begin
    { Resuming sets the boot mode again (RestoreConsoleMode). }
    DebugBeginMessage;
    ResumeConsoleDrawing;
    DebugEndMessage;
  end
  else
    GiveBackOpenedMode(Display);
  Display^.IsOpen := False;
  Result := ErrorNone;
end;

function PackPair(Low, High: LongWord): Int64;
begin
  Result := Int64(QWord(Low) or (QWord(High) shl 32));
end;

function ControlDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Display: PDisplay;
  Index: QWord;
begin
  Display := DisplayOfDevice(Device);
  Result := ErrorNone;
  case Request.ControlCode of
    ControlDisplayGetSize:
      Request.Information := PackPair(Display^.Adapter.Width, Display^.Adapter.Height);
    ControlDisplayGetPitch:
      Request.Information := Int64(Display^.Adapter.Pitch);
    ControlDisplayGetFormat:
      Request.Information := Display^.Adapter.PixelFormat;
    ControlDisplayGetDpi:
      Request.Information := Display^.Dpi;
    ControlDisplayGetScale:
      Request.Information := Display^.ScalePercent;
    ControlDisplayGetPhysicalSize:
      Request.Information := PackPair(Display^.WidthMillimetres, Display^.HeightMillimetres);
    ControlDisplayGetModeCount:
      Request.Information := Display^.Modes.Count;
    ControlDisplayGetMode:
      begin
        Index := Request.ControlArgument;
        if Index >= QWord(Display^.Modes.Count) then
          Exit(ErrorInvalidArgument);
        Request.Information := PackPair(Display^.Modes.Modes[Index].Width, Display^.Modes.Modes[Index].Height);
      end;
    ControlDisplaySetMode:
      Result := SetMode(Display, LongWord(Request.ControlArgument and $FFFFFFFF),
        LongWord(Request.ControlArgument shr 32));
  else
    Result := ErrorUnsupported;
  end;
end;

function MapDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Display: PDisplay;
  Size: QWord;
begin
  Display := DisplayOfDevice(Device);
  Size := RoundUpToPage(Display^.Adapter.Pitch * Display^.Adapter.Height);
  if (Request.Offset >= Size) or (Request.Length > Size - Request.Offset) then
    Exit(ErrorInvalidArgument);
  Request.MapPhysical := Display^.Adapter.FramebufferPhysical + Request.Offset;
  Request.MapWriteCombining := True;
  Result := ErrorNone;
end;

{ --- Registering ------------------------------------------------------------ }

procedure CreateDisplayDriver;
var
  Dispatch: TDispatchTable;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionOpen] := @OpenDisplay;
  Dispatch[IoFunctionClose] := @CloseDisplay;
  Dispatch[IoFunctionControl] := @ControlDisplay;
  Dispatch[IoFunctionMap] := @MapDisplay;
  DisplayDriver := CreateDriver('display', Dispatch);
end;

{ "display", then "display1", "display2"... }
procedure MakeDeviceName(Number: LongInt; var Name: array of Char);
var
  Digits: TNumberText;
  Used: PtrUInt;
begin
  CopyText(@Name[0], 'display', Length(Name));
  if Number = 0 then
    Exit;
  Used := TextLength(@Name[0]);
  CopyText(@Name[Used], FormatDecimal(Number, Digits), PtrUInt(Length(Name)) - Used);
end;

procedure LogDisplay(Display: PDisplay; Name: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('display');
  DebugWrite(Name);
  DebugWrite(' ');
  DebugWriteDecimal(Display^.Adapter.Width);
  DebugWrite('x');
  DebugWriteDecimal(Display^.Adapter.Height);
  if Display^.WidthMillimetres > 0 then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(Display^.WidthMillimetres);
    DebugWrite('x');
    DebugWriteDecimal(Display^.HeightMillimetres);
    DebugWrite(' mm');
  end;
  DebugWrite(', ');
  DebugWriteDecimal(Display^.Dpi);
  DebugWrite(' DPI, scale ');
  DebugWriteDecimal(Display^.ScalePercent);
  DebugWrite('%, ');
  DebugWriteDecimal(Display^.Modes.Count);
  DebugWriteLine(' modes');
  DebugEndMessage;
end;

function RegisterDisplay(const Adapter: TDisplayAdapter): Boolean;
var
  Device: PDeviceObject;
  Display: PDisplay;
  Name: array[0..15] of Char;
begin
  Result := False;
  if (RegisteredCount = MaximumDisplays) or (Adapter.FramebufferPhysical = 0) or (Adapter.Width = 0) or
     ((Adapter.FramebufferPhysical and PageOffsetMask) <> 0) then
    Exit;
  if DisplayDriver = nil then
    CreateDisplayDriver;
  MakeDeviceName(RegisteredCount, Name);
  Device := CreateDevice(DisplayDriver, @Name[0], DeviceKindCharacter, OwnerOnly, SizeOf(TDisplay));
  if Device = nil then
    Exit;
  Device^.IsExclusive := True;
  Display := DisplayOfDevice(Device);
  Display^.Number := RegisteredCount;
  Display^.Adapter := Adapter;
  ReadDpiOption(Display);
  ChoosePhysicalSize(Display);
  ChooseDpi(Display);
  ListModes(Display);
  Displays[RegisteredCount] := Display;
  Inc(RegisteredCount);
  if Display^.Number = 0 then
    SetConsoleModeRestorer(@RestoreConsoleMode);
  LogDisplay(Display, @Name[0]);
  Result := True;
end;

end.

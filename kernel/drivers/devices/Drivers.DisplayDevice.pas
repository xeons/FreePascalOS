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
  The display device (/dev/display): the screen for a graphical program.

  The framebuffer is the one the firmware set up (the loader passes it
  on). Opening the device takes the screen from the text console, which
  goes on drawing into its copy of the screen only; closing it, as when
  the program ends however it ends, gives the screen back and the
  console draws itself again. One program has it at a time.

  Control requests tell the size, the pitch, the pixel format, the
  physical size and the DPI; the framebuffer is mapped into the program
  (CallMapHandle, offset 0) with writes combined.

  The DPI: the kernel option dpi=N if given; else from the display's
  EDID (the firmware's, or QEMU's Bochs display's), its physical width
  against the framebuffer's width in pixels; else 96. The scale is the
  DPI against 96, to the nearest quarter, at least 100%.
}
unit Drivers.DisplayDevice;

{$mode objfpc}

interface

uses
  Boot.Information;

{ Creates /dev/display if the firmware left a framebuffer. }
procedure InitializeDisplayDevice(const Framebuffer: TFramebufferInformation);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Memory.Layout,
  Kernel.Options,
  Io.Manager,
  Debug.Output,
  Debug.FramebufferConsole,
  Drivers.Edid,
  Drivers.BochsDisplay;

const
  OwnerOnly = $180; { rw------- }
  BytesPerPixel = 4;
  MinimumDpi = 48;
  MaximumDpi = 960;
  ScaleStepPercent = 25;

type
  TDisplay = record
    Framebuffer: TFramebufferInformation;
    Pitch: QWord;
    Dpi: LongWord;
    ScalePercent: LongWord;
    WidthMillimetres: LongWord;
    HeightMillimetres: LongWord;
  end;

var
  Display: TDisplay;

{ --- DPI ------------------------------------------------------------------ }

procedure ChoosePhysicalSize;
var
  Block: array[0..EdidBlockSize - 1] of Byte;
  Size: TEdidSize;
  Found: Boolean;
begin
  Found := (Display.Framebuffer.HasEdid <> 0) and ParseEdid(@Display.Framebuffer.Edid[0], Size);
  if not Found then
    Found := ReadBochsEdid(@Block[0]) and ParseEdid(@Block[0], Size);
  if not Found then
    Exit;
  Display.WidthMillimetres := Size.WidthMillimetres;
  Display.HeightMillimetres := Size.HeightMillimetres;
end;

procedure ChooseDpi;
var
  Number: QWord;
begin
  Display.Dpi := DisplayBaseDpi;
  if GetKernelOptionNumber('dpi', Number) and (Number >= MinimumDpi) and (Number <= MaximumDpi) then
    Display.Dpi := LongWord(Number)
  else if Display.WidthMillimetres > 0 then
    { Pixels per millimetre times 25.4, rounded. }
    Display.Dpi := LongWord((QWord(Display.Framebuffer.Width) * 254 + QWord(Display.WidthMillimetres) * 5) div
      (QWord(Display.WidthMillimetres) * 10));
  if (Display.Dpi < MinimumDpi) or (Display.Dpi > MaximumDpi) then
    Display.Dpi := DisplayBaseDpi;
  Display.ScalePercent := (Display.Dpi * 100 + DisplayBaseDpi * ScaleStepPercent div 2) div
    (DisplayBaseDpi * ScaleStepPercent) * ScaleStepPercent;
  if Display.ScalePercent < 100 then
    Display.ScalePercent := 100;
end;

{ --- The device ------------------------------------------------------------- }

function OpenDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  { Between messages, so no line is half drawn over the program's screen. }
  DebugBeginMessage;
  SuspendConsoleDrawing;
  DebugEndMessage;
  Result := ErrorNone;
end;

function CloseDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  DebugBeginMessage;
  ResumeConsoleDrawing;
  DebugEndMessage;
  Result := ErrorNone;
end;

function PackPair(Low, High: LongWord): Int64;
begin
  Result := Int64(QWord(Low) or (QWord(High) shl 32));
end;

function ControlDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ErrorNone;
  case Request.ControlCode of
    ControlDisplayGetSize:
      Request.Information := PackPair(Display.Framebuffer.Width, Display.Framebuffer.Height);
    ControlDisplayGetPitch:
      Request.Information := Int64(Display.Pitch);
    ControlDisplayGetFormat:
      if Display.Framebuffer.PixelFormat = PixelFormatRedGreenBlue then
        Request.Information := DisplayFormatRedGreenBlue
      else
        Request.Information := DisplayFormatBlueGreenRed;
    ControlDisplayGetDpi:
      Request.Information := Display.Dpi;
    ControlDisplayGetScale:
      Request.Information := Display.ScalePercent;
    ControlDisplayGetPhysicalSize:
      Request.Information := PackPair(Display.WidthMillimetres, Display.HeightMillimetres);
  else
    Result := ErrorUnsupported;
  end;
end;

function MapDisplay(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Size: QWord;
begin
  Size := RoundUpToPage(Display.Pitch * Display.Framebuffer.Height);
  if (Request.Offset >= Size) or (Request.Length > Size - Request.Offset) then
    Exit(ErrorInvalidArgument);
  Request.MapPhysical := Display.Framebuffer.PhysicalBase + Request.Offset;
  Request.MapWriteCombining := True;
  Result := ErrorNone;
end;

procedure InitializeDisplayDevice(const Framebuffer: TFramebufferInformation);
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
  Device: PDeviceObject;
begin
  if (Framebuffer.PhysicalBase = 0) or (Framebuffer.Width = 0) or ((Framebuffer.PhysicalBase and PageOffsetMask) <> 0) then
    Exit;
  Display.Framebuffer := Framebuffer;
  Display.Pitch := QWord(Framebuffer.PixelsPerScanLine) * BytesPerPixel;
  ChoosePhysicalSize;
  ChooseDpi;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionOpen] := @OpenDisplay;
  Dispatch[IoFunctionClose] := @CloseDisplay;
  Dispatch[IoFunctionControl] := @ControlDisplay;
  Dispatch[IoFunctionMap] := @MapDisplay;
  Driver := CreateDriver('display', Dispatch);
  Device := CreateDevice(Driver, 'display', DeviceKindCharacter, OwnerOnly, 0);
  if Device = nil then
    Exit;
  Device^.IsExclusive := True;
  DebugBeginMessage;
  DebugWriteTag('display');
  DebugWriteDecimal(Framebuffer.Width);
  DebugWrite('x');
  DebugWriteDecimal(Framebuffer.Height);
  if Display.WidthMillimetres > 0 then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(Display.WidthMillimetres);
    DebugWrite('x');
    DebugWriteDecimal(Display.HeightMillimetres);
    DebugWrite(' mm');
  end;
  DebugWrite(', ');
  DebugWriteDecimal(Display.Dpi);
  DebugWrite(' DPI, scale ');
  DebugWriteDecimal(Display.ScalePercent);
  DebugWriteLine('%');
  DebugEndMessage;
end;

end.

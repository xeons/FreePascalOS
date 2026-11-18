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
  USB pointing devices: mice, tablets, anything HID with X and Y. The
  pointer half of a HID interface (Drivers.UsbHid finds the interface,
  parses its report descriptor and hands the pointer's reports here,
  only those: a receiver's consumer and system control reports, by
  their report ids, go elsewhere or nowhere).

  The layout (Drivers.HidReports) says where X, Y, the wheel and the
  buttons are in a report. A mouse (relative X and Y) gives motion
  events, a tablet (absolute, like QEMU's usb-tablet) position events
  normalized to 0-65535; button changes and wheel steps give their
  events too.
}
unit Drivers.UsbPointer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.HidReports;

type
  PUsbPointer = ^TUsbPointer;
  TUsbPointer = record
    Layout: THidPointerLayout;
    Source: Word;
    ButtonsHeld: LongWord;
    LastX: LongInt;
    LastY: LongInt;
  end;

{ A new pointing device with this layout (logged as a USB mouse or
  tablet); nil if there are too many already. }
function CreateUsbPointer(const Layout: THidPointerLayout): PUsbPointer;
{ One of its reports (called at dispatch level). }
procedure HandleUsbPointerReport(Pointer: PUsbPointer; Report: PByte; Length: LongWord);
{ Every button counts as released (after waking from suspend to RAM). }
procedure ResetUsbPointer(Pointer: PUsbPointer);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Io.InputEvents,
  Debug.Output;

const
  MaximumPointers = 4;

var
  PointerCount: Integer;

procedure SendEvent(Pointer: PUsbPointer; Kind: Word; Code: LongWord; Value, X, Y: LongInt);
var
  Event: TAbiInputEvent;
begin
  FillMemory(@Event, SizeOf(Event), 0);
  Event.Kind := Kind;
  Event.Source := Pointer^.Source;
  Event.Code := Code;
  Event.Value := Value;
  Event.X := X;
  Event.Y := Y;
  AddInputEvent(Event);
end;

{ An absolute value as 0 to InputPositionMaximum across the field's
  range. }
function Normalized(const Field: THidField; Value: LongInt): LongInt;
var
  Span: Int64;
begin
  Span := Int64(Field.LogicalMaximum) - Field.LogicalMinimum;
  if Span <= 0 then
    Exit(0);
  Result := LongInt((Int64(Value) - Field.LogicalMinimum) * InputPositionMaximum div Span);
  if Result < 0 then
    Result := 0;
  if Result > InputPositionMaximum then
    Result := InputPositionMaximum;
end;

procedure SendMotion(Pointer: PUsbPointer; const State: THidPointerState);
var
  X: LongInt;
  Y: LongInt;
begin
  if Pointer^.Layout.X.Relative then
  begin
    if (State.X <> 0) or (State.Y <> 0) then
      SendEvent(Pointer, InputEventMotion, 0, 0, State.X, State.Y);
    Exit;
  end;
  X := Normalized(Pointer^.Layout.X, State.X);
  Y := Normalized(Pointer^.Layout.Y, State.Y);
  if (X <> Pointer^.LastX) or (Y <> Pointer^.LastY) then
    SendEvent(Pointer, InputEventPosition, 0, 0, X, Y);
  Pointer^.LastX := X;
  Pointer^.LastY := Y;
end;

procedure HandleUsbPointerReport(Pointer: PUsbPointer; Report: PByte; Length: LongWord);
var
  State: THidPointerState;
  Button: Integer;
  Mask: LongWord;
begin
  ReadPointerState(Pointer^.Layout, Report, Length, State);
  SendMotion(Pointer, State);
  for Button := 1 to MaximumPointerButtons do
  begin
    Mask := LongWord(1) shl Button;
    if ((State.Buttons xor Pointer^.ButtonsHeld) and Mask) <> 0 then
      SendEvent(Pointer, InputEventButton, Button, Ord((State.Buttons and Mask) <> 0), 0, 0);
  end;
  Pointer^.ButtonsHeld := State.Buttons;
  if State.Wheel <> 0 then
    SendEvent(Pointer, InputEventWheel, 0, State.Wheel, 0, 0);
end;

procedure ResetUsbPointer(Pointer: PUsbPointer);
begin
  Pointer^.ButtonsHeld := 0;
end;

function CreateUsbPointer(const Layout: THidPointerLayout): PUsbPointer;
begin
  Result := nil;
  if PointerCount = MaximumPointers then
    Exit;
  Result := PUsbPointer(AllocateZeroedKernelMemory(SizeOf(TUsbPointer)));
  if Result = nil then
    Exit;
  Result^.Layout := Layout;
  Result^.Source := NewInputSource;
  Result^.LastX := -1;
  Result^.LastY := -1;
  Inc(PointerCount);
  DebugBeginMessage;
  DebugWriteTag('input');
  if Layout.X.Relative then
    DebugWrite('USB mouse')
  else
    DebugWrite('USB tablet');
  if Layout.Wheel.Present then
    DebugWrite(', with a wheel');
  DebugWriteLine('');
  DebugEndMessage;
end;

end.

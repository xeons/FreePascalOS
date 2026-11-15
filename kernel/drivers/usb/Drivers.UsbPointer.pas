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
  USB pointing devices: mice, tablets, anything HID with X and Y.

  The device's HID interface (not a keyboard: that driver takes those
  first) has a report descriptor, read with GET_DESCRIPTOR and parsed
  (Drivers.HidReports) for where X, Y, the wheel and the buttons are in
  its reports. A mouse (relative X and Y) gives motion events, a tablet
  (absolute, like QEMU's usb-tablet) position events normalized to
  0-65535; button changes and wheel steps give their events too. Boot
  mice are put in report protocol, the format the descriptor describes.
}
unit Drivers.UsbPointer;

{$mode objfpc}
{$pointermath on}

interface

{ Offers the driver to the USB core (after the keyboard's). }
procedure RegisterUsbPointerDriver;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Io.InputEvents,
  Drivers.Xhci,
  Drivers.HidReports,
  Debug.Output;

const
  ClassHid = 3;
  SubclassBoot = 1;
  DescriptorHid = $21;
  DescriptorReport = $22;
  EndpointTransferInterrupt = 3;
  RequestGetDescriptor = 6;
  RequestSetProtocol = $0B;
  StandardFromInterface = $81;
  ClassRequestToInterface = $21;
  ReportProtocol = 1;
  MaximumReportDescriptor = 1024;
  MaximumPointers = 4;

type
  PUsbPointer = ^TUsbPointer;
  TUsbPointer = record
    Usb: PUsbDevice;
    InterfaceNumber: Byte;
    IsBootDevice: Boolean;
    Layout: THidPointerLayout;
    Source: Word;
    ButtonsHeld: LongWord;
    LastX: LongInt;
    LastY: LongInt;
  end;

var
  PointerCount: Integer;

{ --- Reports ------------------------------------------------------------------ }

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

procedure HandleReport(Device: PUsbDevice; Data: PByte; Length: LongWord; Context: Pointer);
var
  Pointer: PUsbPointer;
  Layout: ^THidPointerLayout;
  X: LongInt;
  Y: LongInt;
  Wheel: LongInt;
  Button: Integer;
  Held: LongWord;
begin
  Pointer := PUsbPointer(Context);
  Layout := @Pointer^.Layout;
  if Layout^.UsesReportIds and ((Length = 0) or (Data[0] <> Layout^.ReportId)) then
    Exit;
  X := ReadHidField(Layout^, Layout^.X, Data, Length);
  Y := ReadHidField(Layout^, Layout^.Y, Data, Length);
  if Layout^.X.Relative then
  begin
    if (X <> 0) or (Y <> 0) then
      SendEvent(Pointer, InputEventMotion, 0, 0, X, Y);
  end
  else
  begin
    X := Normalized(Layout^.X, X);
    Y := Normalized(Layout^.Y, Y);
    if (X <> Pointer^.LastX) or (Y <> Pointer^.LastY) then
      SendEvent(Pointer, InputEventPosition, 0, 0, X, Y);
    Pointer^.LastX := X;
    Pointer^.LastY := Y;
  end;
  Held := 0;
  for Button := 1 to MaximumPointerButtons do
    if Layout^.Buttons[Button].Present and (ReadHidField(Layout^, Layout^.Buttons[Button], Data, Length) <> 0) then
      Held := Held or (LongWord(1) shl Button);
  for Button := 1 to MaximumPointerButtons do
    if ((Held xor Pointer^.ButtonsHeld) and (LongWord(1) shl Button)) <> 0 then
      SendEvent(Pointer, InputEventButton, Button, Ord((Held and (LongWord(1) shl Button)) <> 0), 0, 0);
  Pointer^.ButtonsHeld := Held;
  if Layout^.Wheel.Present then
  begin
    Wheel := ReadHidField(Layout^, Layout^.Wheel, Data, Length);
    if Wheel <> 0 then
      SendEvent(Pointer, InputEventWheel, 0, Wheel, 0, 0);
  end;
end;

{ --- Finding the interface ---------------------------------------------------- }

{ The first HID interface's number, its report descriptor's length, its
  interrupt IN endpoint, and whether it is a boot device. }
function FindPointerInterface(Usb: PUsbDevice; out InterfaceNumber: Byte; out ReportLength: Word;
  out Endpoint: Byte; out MaximumPacket: Word; out Interval: Byte; out IsBootDevice: Boolean): Boolean;
var
  Position: LongWord;
  Descriptor: PByte;
  InHid: Boolean;
begin
  Result := False;
  InHid := False;
  InterfaceNumber := 0;
  ReportLength := 0;
  IsBootDevice := False;
  Position := 0;
  while Position + 2 <= Usb^.ConfigurationLength do
  begin
    Descriptor := Usb^.Configuration + Position;
    if (Descriptor[0] < 2) or (Position + Descriptor[0] > Usb^.ConfigurationLength) then
      Break;
    if (Descriptor[1] = UsbDescriptorInterface) and (Descriptor[0] >= 9) then
    begin
      if InHid and (ReportLength > 0) then
        Break;
      InHid := Descriptor[5] = ClassHid;
      InterfaceNumber := Descriptor[2];
      IsBootDevice := Descriptor[6] = SubclassBoot;
      ReportLength := 0;
    end
    else if InHid and (Descriptor[1] = DescriptorHid) and (Descriptor[0] >= 9) and (Descriptor[6] = DescriptorReport) then
      ReportLength := Descriptor[7] or (Word(Descriptor[8]) shl 8)
    else if InHid and (Descriptor[1] = UsbDescriptorEndpoint) and (Descriptor[0] >= 7) and
            ((Descriptor[2] and $80) <> 0) and ((Descriptor[3] and 3) = EndpointTransferInterrupt) then
    begin
      Endpoint := Descriptor[2];
      MaximumPacket := Descriptor[4] or (Word(Descriptor[5]) shl 8);
      Interval := Descriptor[6];
      Result := ReportLength > 0;
      if Result then
        Exit;
    end;
    Position := Position + Descriptor[0];
  end;
end;

procedure ChooseReportProtocol(Pointer: PUsbPointer);
begin
  if Pointer^.IsBootDevice then
    UsbControlTransfer(Pointer^.Usb, ClassRequestToInterface, RequestSetProtocol, ReportProtocol,
      Pointer^.InterfaceNumber, nil, 0);
end;

{ After waking from suspend to RAM. }
procedure ResumePointer(Usb: PUsbDevice; Context: Pointer);
begin
  PUsbPointer(Context)^.ButtonsHeld := 0;
  ChooseReportProtocol(PUsbPointer(Context));
end;

function ProbeUsbPointer(Usb: PUsbDevice): Boolean;
var
  Pointer: PUsbPointer;
  InterfaceNumber: Byte;
  ReportLength: Word;
  Endpoint: Byte;
  MaximumPacket: Word;
  Interval: Byte;
  IsBootDevice: Boolean;
  Descriptor: PByte;
  Layout: THidPointerLayout;
begin
  Result := False;
  if (PointerCount = MaximumPointers) or
     not FindPointerInterface(Usb, InterfaceNumber, ReportLength, Endpoint, MaximumPacket, Interval, IsBootDevice) or
     (ReportLength > MaximumReportDescriptor) then
    Exit;
  Descriptor := PByte(AllocateKernelMemory(ReportLength));
  if Descriptor = nil then
    Exit;
  if not UsbControlTransfer(Usb, StandardFromInterface, RequestGetDescriptor, Word(DescriptorReport) shl 8,
       InterfaceNumber, Descriptor, ReportLength) or not ParsePointerLayout(Descriptor, ReportLength, Layout) then
  begin
    FreeKernelMemory(Descriptor);
    Exit;
  end;
  FreeKernelMemory(Descriptor);
  Result := True;
  Pointer := PUsbPointer(AllocateZeroedKernelMemory(SizeOf(TUsbPointer)));
  if Pointer = nil then
    Exit;
  Pointer^.Usb := Usb;
  Pointer^.InterfaceNumber := InterfaceNumber;
  Pointer^.IsBootDevice := IsBootDevice;
  Pointer^.Layout := Layout;
  Pointer^.Source := NewInputSource;
  Pointer^.LastX := -1;
  Pointer^.LastY := -1;
  ChooseReportProtocol(Pointer);
  UsbSetResumeHandler(Usb, @ResumePointer, Pointer);
  if not UsbStartInterruptIn(Usb, Endpoint, MaximumPacket, Interval, @HandleReport, Pointer) then
    Exit;
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

procedure RegisterUsbPointerDriver;
begin
  RegisterUsbClassDriver(@ProbeUsbPointer);
end;

end.

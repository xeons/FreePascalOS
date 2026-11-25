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
  The ACPI embedded controller: finding it, and talking to it.

  The embedded controller (a small microcontroller on laptops) holds
  what AML reads for batteries, thermal zones, fans and buttons: an
  operation region of the EmbeddedControl space, 256 bytes reached
  through two I/O ports, data and command/status:
  - read byte A: wait until its input buffer is empty (status IBF
    clear), write RD_EC (80h) to the command port, wait, write A to the
    data port, wait until its output buffer is full (OBF), read the
    data port;
  - write byte A: WR_EC (81h), A, then the value, each after IBF clears;
  - an event (status SCI_EVT, with the EC's general purpose event): QR_EC
    (84h) gives a query number n (0: none), whose method _Qnn (two
    hexadecimal digits) under the EC device the caller runs.
  Each wait is bounded: a controller that does not answer fails the
  access (AML sees the read fail) instead of hanging.

  The controller is found as the device PNP0C09 (_CRS: the data port,
  then the command port; _GPE: its event), or from the ECDT table
  before the namespace is loaded. Once the kernel handles the space,
  _REG(3, 1) tells the firmware it may use it.

  The protocol runs over port routines the caller gives, so the host
  test (tools/AcpiPowerTest) plays a controller in memory.
}
unit Firmware.AcpiEmbeddedController;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

const
  EmbeddedControllerStatusOutputFull = $01;
  EmbeddedControllerStatusInputFull = $02;
  EmbeddedControllerStatusEvent = $20;
  EmbeddedControllerRead = $80;
  EmbeddedControllerWrite = $81;
  EmbeddedControllerQuery = $84;
  NoEmbeddedControllerGpe = High(LongWord);

type
  TEmbeddedControllerPorts = record
    ReadPort: function(Port: Word): Byte;
    WritePort: procedure(Port: Word; Value: Byte);
    { Waits a microsecond (between status reads). }
    Stall: procedure;
  end;

  TAcpiEmbeddedController = record
    Node: PAmlNode;
    DataPort: Word;
    CommandPort: Word;
    GpeNumber: LongWord;
    Ports: TEmbeddedControllerPorts;
    { Status reads a wait may take before it gives up. }
    WaitLimit: LongWord;
    Timeouts: LongWord;
  end;

{ The PNP0C09 device and its ports and event; False if there is none. }
function FindAcpiEmbeddedController(out Controller: TAcpiEmbeddedController): Boolean;
function ReadEmbeddedControllerByte(var Controller: TAcpiEmbeddedController; Address: Byte;
  out Value: Byte): Boolean;
function WriteEmbeddedControllerByte(var Controller: TAcpiEmbeddedController; Address: Byte;
  Value: Byte): Boolean;
{ A field access of Width bits at Address (little endian, byte by byte). }
function ReadEmbeddedControllerSpace(var Controller: TAcpiEmbeddedController; Address: QWord; Width: Byte;
  out Value: QWord): Boolean;
function WriteEmbeddedControllerSpace(var Controller: TAcpiEmbeddedController; Address: QWord; Width: Byte;
  Value: QWord): Boolean;
{ If the controller has an event pending: its query number (0 if none,
  or it did not answer). }
function QueryEmbeddedController(var Controller: TAcpiEmbeddedController): Byte;
{ Runs _Qnn for query Number under the controller's device; False if
  there is no such method. }
function RunEmbeddedControllerQuery(constref Controller: TAcpiEmbeddedController; Number: Byte): Boolean;
{ _REG(3, Connected) on the controller's device. }
procedure ConnectEmbeddedControllerRegion(constref Controller: TAcpiEmbeddedController; Connected: Boolean);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Firmware.AmlValues,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceWalk;

const
  DefaultWaitLimit = 100000;
  EmbeddedControlSpace = 3;
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';

type
  TSearch = record
    Found: Boolean;
    Controller: ^TAcpiEmbeddedController;
  end;
  PSearch = ^TSearch;

procedure NoteController(var Description: TAcpiDeviceDescription; Context: Pointer);
var
  Search: PSearch;
begin
  Search := PSearch(Context);
  if not Search^.Found and TextIsEqual(@Description.HardwareId[0], 'PNP0C09') and
     (Description.Resources.IoCount >= 2) then
  begin
    Search^.Found := True;
    Search^.Controller^.Node := Description.Node;
    Search^.Controller^.DataPort := Word(Description.Resources.Io[0].Start);
    Search^.Controller^.CommandPort := Word(Description.Resources.Io[1].Start);
    Search^.Controller^.GpeNumber := LongWord(ChildInteger(Description.Node, '_GPE', NoEmbeddedControllerGpe));
  end;
  ReleaseValue(Description.Properties);
end;

function FindAcpiEmbeddedController(out Controller: TAcpiEmbeddedController): Boolean;
var
  Search: TSearch;
begin
  ZeroMemory(@Controller, SizeOf(Controller));
  Controller.GpeNumber := NoEmbeddedControllerGpe;
  Controller.WaitLimit := DefaultWaitLimit;
  Search.Found := False;
  Search.Controller := @Controller;
  if NamespaceRoot <> nil then
    WalkAcpiDevices(@NoteController, @Search);
  Result := Search.Found;
end;

function WaitForStatus(var Controller: TAcpiEmbeddedController; Mask, Wanted: Byte): Boolean;
var
  Count: LongWord;
begin
  Count := 0;
  while (Controller.Ports.ReadPort(Controller.CommandPort) and Mask) <> Wanted do
  begin
    Inc(Count);
    if Count >= Controller.WaitLimit then
    begin
      Inc(Controller.Timeouts);
      Exit(False);
    end;
    Controller.Ports.Stall();
  end;
  Result := True;
end;

function SendCommand(var Controller: TAcpiEmbeddedController; Command: Byte): Boolean;
begin
  Result := WaitForStatus(Controller, EmbeddedControllerStatusInputFull, 0);
  if Result then
    Controller.Ports.WritePort(Controller.CommandPort, Command);
end;

function SendData(var Controller: TAcpiEmbeddedController; Value: Byte): Boolean;
begin
  Result := WaitForStatus(Controller, EmbeddedControllerStatusInputFull, 0);
  if Result then
    Controller.Ports.WritePort(Controller.DataPort, Value);
end;

function ReceiveData(var Controller: TAcpiEmbeddedController; out Value: Byte): Boolean;
begin
  Value := 0;
  Result := WaitForStatus(Controller, EmbeddedControllerStatusOutputFull, EmbeddedControllerStatusOutputFull);
  if Result then
    Value := Controller.Ports.ReadPort(Controller.DataPort);
end;

function ReadEmbeddedControllerByte(var Controller: TAcpiEmbeddedController; Address: Byte;
  out Value: Byte): Boolean;
begin
  Value := 0;
  Result := SendCommand(Controller, EmbeddedControllerRead) and SendData(Controller, Address) and
    ReceiveData(Controller, Value);
end;

function WriteEmbeddedControllerByte(var Controller: TAcpiEmbeddedController; Address: Byte;
  Value: Byte): Boolean;
begin
  Result := SendCommand(Controller, EmbeddedControllerWrite) and SendData(Controller, Address) and
    SendData(Controller, Value);
end;

function ReadEmbeddedControllerSpace(var Controller: TAcpiEmbeddedController; Address: QWord; Width: Byte;
  out Value: QWord): Boolean;
var
  Index: LongWord;
  Part: Byte;
begin
  Value := 0;
  Result := (Width mod 8 = 0) and (Width > 0) and (Address + Width div 8 <= 256);
  Index := 0;
  while Result and (Index < LongWord(Width div 8)) do
  begin
    Result := ReadEmbeddedControllerByte(Controller, Byte(Address + Index), Part);
    Value := Value or (QWord(Part) shl (8 * Index));
    Inc(Index);
  end;
end;

function WriteEmbeddedControllerSpace(var Controller: TAcpiEmbeddedController; Address: QWord; Width: Byte;
  Value: QWord): Boolean;
var
  Index: LongWord;
begin
  Result := (Width mod 8 = 0) and (Width > 0) and (Address + Width div 8 <= 256);
  Index := 0;
  while Result and (Index < LongWord(Width div 8)) do
  begin
    Result := WriteEmbeddedControllerByte(Controller, Byte(Address + Index), Byte(Value shr (8 * Index)));
    Inc(Index);
  end;
end;

function QueryEmbeddedController(var Controller: TAcpiEmbeddedController): Byte;
begin
  Result := 0;
  if (Controller.Ports.ReadPort(Controller.CommandPort) and EmbeddedControllerStatusEvent) = 0 then
    Exit;
  if not SendCommand(Controller, EmbeddedControllerQuery) or not ReceiveData(Controller, Result) then
    Result := 0;
end;

function RunEmbeddedControllerQuery(constref Controller: TAcpiEmbeddedController; Number: Byte): Boolean;
var
  Name: array[0..4] of Char;
  Ignored: TAmlValue;
begin
  Name[0] := '_';
  Name[1] := 'Q';
  Name[2] := HexDigits[Number shr 4];
  Name[3] := HexDigits[Number and $F];
  Name[4] := #0;
  Result := (Controller.Node <> nil) and (FindChild(Controller.Node, SegmentOf(@Name[0])) <> nil) and
    EvaluatePath(Controller.Node, @Name[0], nil, 0, Ignored);
  if Result then
    ReleaseValue(Ignored);
end;

procedure ConnectEmbeddedControllerRegion(constref Controller: TAcpiEmbeddedController; Connected: Boolean);
var
  Arguments: array[0..1] of TAmlValue;
  Ignored: TAmlValue;
begin
  if (Controller.Node = nil) or (FindChild(Controller.Node, SegmentOf('_REG')) = nil) then
    Exit;
  Arguments[0] := MakeInteger(EmbeddedControlSpace);
  Arguments[1] := MakeInteger(Ord(Connected));
  if EvaluatePath(Controller.Node, '_REG', @Arguments[0], 2, Ignored) then
    ReleaseValue(Ignored);
end;

end.

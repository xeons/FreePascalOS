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
  The kernel's side of the ACPI embedded controller
  (Firmware.AcpiEmbeddedController): the ports, the EmbeddedControl
  address space for AML (Io.AcpiNamespace's host routines come here),
  and its events.

  It is connected right after the tables are loaded and before the
  devices' _INI run (which often read it): the ECDT gives its ports
  early where the firmware has one, the PNP0C09 device otherwise (or
  as well: its node is where _REG and the _Qnn methods are). Then
  _REG(3, 1) says the space is there, and its GPE gets a handler of its
  own (Io.AcpiEvents): on each event, in the event thread with the
  interpreter's lock, every pending query is taken (QR_EC) and its _Qnn
  run, which is where laptops Notify their thermal zones, batteries and
  buttons. AML runs under the interpreter's lock, so accesses never
  overlap.
}
unit Io.AcpiEmbeddedController;

{$mode objfpc}

interface

{ After the tables are loaded (before the devices' _INI). }
procedure ConnectEmbeddedController;
function EmbeddedControllerIsPresent: Boolean;
{ The EmbeddedControl space for AML. }
function ReadEmbeddedControllerAddress(Address: QWord; Width: Byte; out Value: QWord): Boolean;
function WriteEmbeddedControllerAddress(Address: QWord; Width: Byte; Value: QWord): Boolean;

implementation

uses
  Firmware.Acpi,
  Firmware.AmlNamespace,
  Firmware.AcpiEmbeddedController,
  Firmware.AmlHost,
  Hal.PortIo,
  Io.AcpiEvents,
  Io.AcpiNamespace,
  Debug.Output;

const
  MaximumQueriesPerEvent = 32;
  { ECDT: the control and data registers (Generic Address Structures),
    the GPE bit and the device's path. }
  EcdtControlAddressOffset = 36 + 4;
  EcdtDataAddressOffset = 48 + 4;
  EcdtGpeOffset = 64;
  EcdtIdOffset = 65;
  EcdtMinimumLength = 66;

var
  Controller: TAcpiEmbeddedController;
  Present: Boolean = False;

function EmbeddedControllerIsPresent: Boolean;
begin
  Result := Present;
end;

function ReadPortValue(Port: Word): Byte;
begin
  Result := ReadPortByte(Port);
end;

procedure WritePortValue(Port: Word; Value: Byte);
begin
  WritePortByte(Port, Value);
end;

procedure StallMicrosecond;
begin
  AmlHost.Stall(1);
end;

function ReadEmbeddedControllerAddress(Address: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  Value := 0;
  Result := Present and ReadEmbeddedControllerSpace(Controller, Address, Width, Value);
end;

function WriteEmbeddedControllerAddress(Address: QWord; Width: Byte; Value: QWord): Boolean;
begin
  Result := Present and WriteEmbeddedControllerSpace(Controller, Address, Width, Value);
end;

{ The event thread, interpreter unlocked. }
procedure HandleEmbeddedControllerEvent(Number: LongWord);
var
  Query: Byte;
  Count: Integer;
begin
  LockAmlInterpreter;
  Count := 0;
  repeat
    Query := QueryEmbeddedController(Controller);
    if Query = 0 then
      Break;
    DebugBeginMessage;
    DebugWriteTag('acpi');
    DebugWrite('embedded controller query 0x');
    DebugWriteHex(Query, 2);
    if not RunEmbeddedControllerQuery(Controller, Query) then
      DebugWrite(' (no method)');
    DebugWriteLine('');
    DebugEndMessage;
    Inc(Count);
  until Count >= MaximumQueriesPerEvent;
  UnlockAmlInterpreter;
end;

{ The ECDT's ports, before the namespace says (False if there is none). }
function ReadEcdt: Boolean;
var
  Table: PByte;
begin
  Result := False;
  Table := PByte(FindAcpiTable('ECDT', 0));
  if (Table = nil) or (PAcpiTableHeader(Table)^.Length < EcdtMinimumLength) then
    Exit;
  Controller.CommandPort := Word(PQWord(Table + EcdtControlAddressOffset)^);
  Controller.DataPort := Word(PQWord(Table + EcdtDataAddressOffset)^);
  Controller.GpeNumber := Table[EcdtGpeOffset];
  Controller.Node := LookupText(NamespaceRoot, PChar(Table + EcdtIdOffset));
  Result := (Controller.CommandPort <> 0) and (Controller.DataPort <> 0);
end;

procedure ConnectEmbeddedController;
var
  Found: TAcpiEmbeddedController;
  FromTable: Boolean;
begin
  FromTable := ReadEcdt;
  if FindAcpiEmbeddedController(Found) then
  begin
    if not FromTable then
    begin
      Controller.CommandPort := Found.CommandPort;
      Controller.DataPort := Found.DataPort;
      Controller.GpeNumber := Found.GpeNumber;
    end;
    if Controller.Node = nil then
      Controller.Node := Found.Node;
    if Controller.GpeNumber = NoEmbeddedControllerGpe then
      Controller.GpeNumber := Found.GpeNumber;
  end
  else if not FromTable then
    Exit;
  Controller.WaitLimit := Found.WaitLimit;
  if Controller.WaitLimit = 0 then
    Controller.WaitLimit := 100000;
  Controller.Ports.ReadPort := @ReadPortValue;
  Controller.Ports.WritePort := @WritePortValue;
  Controller.Ports.Stall := @StallMicrosecond;
  Present := True;
  ConnectEmbeddedControllerRegion(Controller, True);
  if Controller.GpeNumber <> NoEmbeddedControllerGpe then
    RegisterGpeHandler(Controller.GpeNumber, @HandleEmbeddedControllerEvent);
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('embedded controller: ports 0x');
  DebugWriteHex(Controller.DataPort, 2);
  DebugWrite(' and 0x');
  DebugWriteHex(Controller.CommandPort, 2);
  if Controller.GpeNumber <> NoEmbeddedControllerGpe then
  begin
    DebugWrite(', GPE ');
    DebugWriteDecimal(Controller.GpeNumber);
  end;
  if FromTable then
    DebugWrite(' (ECDT)');
  DebugWriteLine('');
  DebugEndMessage;
end;

end.

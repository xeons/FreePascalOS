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
  A processor's idle states as ACPI's _CST lists them.

  _CST belongs to the processor objects (Processor, or devices ACPI0007)
  and returns Package (Count, State...), each state a Package (Register,
  Type, Latency, Power): the register a Generic Register descriptor
  (82h) saying how to enter it, the C-state type (1-3), the worst exit
  latency in microseconds and the power in milliwatts. Only states
  entered through functional fixed hardware are taken here (address
  space 7Fh, class 2 in the bit offset: "native C-state beyond halt"),
  whose address is the MWAIT hint; and states entered by reading an I/O
  port (address space 1, the older way: the read enters the state, the
  chipset ends it), whose address is the port. Firmware waits for _PDC
  or _OSC to hear what the processor driver can do
  (Firmware.AcpiProcessorControl, evaluated first) and answers with
  port states, MWAIT states or nothing accordingly.

  Plain Pascal over the interpreter, built by the host test
  (tools/AcpiPowerTest).
}
unit Firmware.AcpiProcessorIdle;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

const
  MaximumAcpiIdleStates = 8;
  { TAcpiIdleState.Entry. }
  AcpiIdleEntryMonitorWait = 0;
  AcpiIdleEntryPortRead = 1;
  MaximumAcpiProcessors = 64;

type
  TAcpiIdleState = record
    { 1, 2 or 3. }
    CStateType: LongWord;
    { How it is entered: the MWAIT hint, or the port to read. }
    Entry: LongWord;
    MonitorWaitHint: LongWord;
    Port: LongWord;
    LatencyMicroseconds: LongWord;
    PowerMilliwatts: LongWord;
  end;

{ The first processor's _CST states entered with MWAIT or a port read
  (type 2 or deeper: C1 is the halt), in the order listed; returns how
  many. }
function ReadAcpiIdleStates(var States: array of TAcpiIdleState): Integer;
{ The first processor object (Processor, or a device ACPI0007); nil if
  none. }
function FirstAcpiProcessor: PAmlNode;
{ Every processor object (up to Length(Nodes)); returns how many. }
function ListAcpiProcessors(var Nodes: array of PAmlNode): Integer;
{ The first processor object (in the namespace's order) that has the
  object Name; nil if none. }
function FirstProcessorWith(Name: PChar): PAmlNode;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Firmware.AmlValues,
  Firmware.AcpiDeviceWalk;

const
  GenericRegisterTag = $82;
  FixedHardwareSpace = $7F;
  SystemIoSpace = $01;
  NativeCStateClass = 2;
  ProcessorDeviceId = 'ACPI0007';
  MaximumDepth = 24;

type
  TProcessorSearch = record
    Found: PAmlNode;
  end;
  PProcessorSearch = ^TProcessorSearch;

function FindProcessorObject(Scope: PAmlNode; Depth: Integer): PAmlNode;
var
  Child: PAmlNode;
begin
  Result := nil;
  if Depth >= MaximumDepth then
    Exit;
  Child := Scope^.FirstChild;
  while (Child <> nil) and (Result = nil) do
  begin
    if Child^.Kind = NodeProcessor then
      Exit(Child);
    if Child^.Kind in [NodeScope, NodeDevice] then
      Result := FindProcessorObject(Child, Depth + 1);
    Child := Child^.NextSibling;
  end;
end;

procedure NoteProcessorDevice(var Description: TAcpiDeviceDescription; Context: Pointer);
var
  Search: PProcessorSearch;
begin
  Search := PProcessorSearch(Context);
  if (Search^.Found = nil) and TextIsEqual(@Description.HardwareId[0], ProcessorDeviceId) then
    Search^.Found := Description.Node;
  ReleaseValue(Description.Properties);
end;

type
  TProcessorList = record
    Nodes: ^PAmlNode;
    Capacity: Integer;
    Count: Integer;
  end;
  PProcessorList = ^TProcessorList;

procedure AddProcessor(var List: TProcessorList; Node: PAmlNode);
begin
  if List.Count < List.Capacity then
  begin
    List.Nodes[List.Count] := Node;
    Inc(List.Count);
  end;
end;

procedure CollectProcessorObjects(Scope: PAmlNode; Depth: Integer; var List: TProcessorList);
var
  Child: PAmlNode;
begin
  if Depth >= MaximumDepth then
    Exit;
  Child := Scope^.FirstChild;
  while Child <> nil do
  begin
    if Child^.Kind = NodeProcessor then
      AddProcessor(List, Child)
    else if Child^.Kind in [NodeScope, NodeDevice] then
      CollectProcessorObjects(Child, Depth + 1, List);
    Child := Child^.NextSibling;
  end;
end;

procedure NoteEveryProcessorDevice(var Description: TAcpiDeviceDescription; Context: Pointer);
begin
  if TextIsEqual(@Description.HardwareId[0], ProcessorDeviceId) then
    AddProcessor(PProcessorList(Context)^, Description.Node);
  ReleaseValue(Description.Properties);
end;

function ListAcpiProcessors(var Nodes: array of PAmlNode): Integer;
var
  List: TProcessorList;
begin
  Result := 0;
  if (NamespaceRoot = nil) or (Length(Nodes) = 0) then
    Exit;
  List.Nodes := @Nodes[0];
  List.Capacity := Length(Nodes);
  List.Count := 0;
  CollectProcessorObjects(NamespaceRoot, 0, List);
  if List.Count = 0 then
    WalkAcpiDevices(@NoteEveryProcessorDevice, @List);
  Result := List.Count;
end;

function FirstProcessorWith(Name: PChar): PAmlNode;
var
  Nodes: array[0..MaximumAcpiProcessors - 1] of PAmlNode;
  Count: Integer;
  Index: Integer;
begin
  Result := nil;
  Count := ListAcpiProcessors(Nodes);
  for Index := 0 to Count - 1 do
    if FindChild(Nodes[Index], SegmentOf(Name)) <> nil then
      Exit(Nodes[Index]);
end;

function FirstAcpiProcessor: PAmlNode;
var
  Search: TProcessorSearch;
begin
  Result := nil;
  if NamespaceRoot = nil then
    Exit;
  Result := FindProcessorObject(NamespaceRoot, 0);
  if Result <> nil then
    Exit;
  Search.Found := nil;
  WalkAcpiDevices(@NoteProcessorDevice, @Search);
  Result := Search.Found;
end;

function ElementInteger(const Package: TAmlValue; Index: LongWord; out Number: QWord): Boolean;
begin
  Result := (Package.Kind = AmlPackage) and (Index < Package.Package^.Count) and
    (Package.Package^.Elements[Index].Kind = AmlInteger);
  if Result then
    Number := Package.Package^.Elements[Index].Integer
  else
    Number := 0;
end;

{ One state package: True if it is entered through MWAIT. }
function DescribeState(const Entry: TAmlValue; out State: TAcpiIdleState): Boolean;
var
  Register: PAmlValue;
  Data: PByte;
  Number: QWord;
begin
  Result := False;
  ZeroMemory(@State, SizeOf(State));
  if (Entry.Kind <> AmlPackage) or (Entry.Package^.Count < 4) then
    Exit;
  Register := @Entry.Package^.Elements[0];
  if (Register^.Kind <> AmlBuffer) or (ValueLength(Register^) < 15) then
    Exit;
  Data := ValueData(Register^);
  if Data[0] <> GenericRegisterTag then
    Exit;
  if (Data[3] = FixedHardwareSpace) and (Data[5] = NativeCStateClass) then
  begin
    State.Entry := AcpiIdleEntryMonitorWait;
    State.MonitorWaitHint := PLongWord(@Data[7])^;
  end
  else if (Data[3] = SystemIoSpace) and (PQWord(@Data[7])^ <> 0) and (PQWord(@Data[7])^ <= $FFFF) then
  begin
    State.Entry := AcpiIdleEntryPortRead;
    State.Port := LongWord(PQWord(@Data[7])^);
  end
  else
    Exit;
  if ElementInteger(Entry, 1, Number) then
    State.CStateType := LongWord(Number);
  if ElementInteger(Entry, 2, Number) then
    State.LatencyMicroseconds := LongWord(Number);
  if ElementInteger(Entry, 3, Number) then
    State.PowerMilliwatts := LongWord(Number);
  Result := State.CStateType >= 2;
end;

function ReadAcpiIdleStates(var States: array of TAcpiIdleState): Integer;
var
  Processor: PAmlNode;
  Value: TAmlValue;
  Index: LongWord;
  State: TAcpiIdleState;
begin
  Result := 0;
  Processor := FirstProcessorWith('_CST');
  if Processor = nil then
    Exit;
  if not EvaluateChild(Processor, '_CST', Value) or (Value.Kind <> AmlPackage) then
  begin
    ReleaseValue(Value);
    Exit;
  end;
  { Element 0 is the count. }
  Index := 1;
  while (Index < Value.Package^.Count) and (Result <= High(States)) do
  begin
    if DescribeState(Value.Package^.Elements[Index], State) then
    begin
      States[Result] := State;
      Inc(Result);
    end;
    Inc(Index);
  end;
  ReleaseValue(Value);
end;

end.

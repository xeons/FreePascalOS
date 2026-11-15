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
  PCI interrupt routing from the ACPI namespace.

  Every PCI device signals on one of four lines (INTA to INTD). Where
  each line of each slot ends up is in the _PRT of the bridge the slot
  is on: one entry per slot and line, naming either a global system
  interrupt directly, or a link device whose current resources (_CRS)
  say which interrupt it is connected to (and how: level or edge
  triggered, active high or low).

  BuildPciRouting tells the firmware the I/O APICs are in use
  (\_PIC(1)), finds the PCI root bridges (PNP0A03, PNP0A08), and reads
  the _PRT of each and of the bridges below them that have one (their
  bus is the secondary bus in their configuration space). A link that
  is not connected yet (its _CRS has no interrupt) is given the first
  interrupt its _PRS offers, through _SRS.

  Interrupts given directly default to level triggered, active low, as
  PCI lines are. A link described by an IRQ descriptor names an ISA IRQ
  (the route says so), one by an extended interrupt descriptor a global
  system interrupt.
}
unit Firmware.AcpiPciRouting;

{$mode objfpc}
{$pointermath on}

interface

type
  PPciRoute = ^TPciRoute;
  TPciRoute = record
    Segment: Word;
    Bus: Byte;
    Device: Byte;
    { 0 for INTA ... 3 for INTD. }
    Pin: Byte;
    { A global system interrupt, or (IsaInterrupt) an ISA IRQ number,
      which the MADT's overrides turn into one. }
    GlobalInterrupt: LongWord;
    IsaInterrupt: Boolean;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
  end;

{ Builds the routing table from the loaded namespace; the number of
  routes found. }
function BuildPciRouting: Integer;
function PciRouteCount: Integer;
function PciRouteAt(Index: Integer): PPciRoute;
{ The route of Device's line Pin on Bus, or nil if no _PRT lists it. }
function FindPciRoute(Segment: Word; Bus, Device, Pin: Byte): PPciRoute;

implementation

uses
  Runtime.Memory,
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiResources;

const
  MaximumRoutes = 512;
  SecondaryBusRegister = $19;

var
  Routes: array[0..MaximumRoutes - 1] of TPciRoute;
  RouteCount: Integer;

function IsPciRootBridge(Node: PAmlNode): Boolean;
begin
  Result := DeviceHasId(Node, 'PNP0A03') or DeviceHasId(Node, 'PNP0A08');
end;

{ --- Links ------------------------------------------------------------------- }

function ReadLinkResource(Link: PAmlNode; Method: PChar; out Resource: TInterruptResource): Boolean;
var
  Value: TAmlValue;
begin
  Result := False;
  ZeroMemory(@Resource, SizeOf(Resource));
  if not EvaluatePath(Link, Method, nil, 0, Value) then
    Exit;
  if Value.Kind = AmlBuffer then
    Result := FindInterruptResource(Value.Bytes^.Data, Value.Bytes^.Length, Resource);
  ReleaseValue(Value);
end;

{ The interrupt a link device is connected to (connecting it if it is
  not yet). }
function LinkInterrupt(Link: PAmlNode; SourceIndex: LongWord; var Route: TPciRoute): Boolean;
var
  Current: TInterruptResource;
  Possible: TInterruptResource;
  Template: array[0..15] of Byte;
  Length: LongWord;
  Argument: TAmlValue;
  Ignored: TAmlValue;
begin
  Result := False;
  if not ReadLinkResource(Link, '_CRS', Current) or (Current.Count = 0) or (Current.Interrupts[0] = 0) then
  begin
    { Not connected: the first interrupt it can have. }
    if not ReadLinkResource(Link, '_PRS', Possible) or (Possible.Count = 0) then
      Exit;
    Length := MakeInterruptTemplate(Possible, Possible.Interrupts[0], @Template[0]);
    Argument := MakeBufferFrom(@Template[0], Length);
    if EvaluatePath(Link, '_SRS', @Argument, 1, Ignored) then
      ReleaseValue(Ignored);
    ReleaseValue(Argument);
    if not ReadLinkResource(Link, '_CRS', Current) or (Current.Count = 0) then
      Exit;
  end;
  if SourceIndex >= LongWord(Current.Count) then
    SourceIndex := 0;
  Route.GlobalInterrupt := Current.Interrupts[SourceIndex];
  { The small IRQ descriptor names ISA IRQs. }
  Route.IsaInterrupt := not Current.Extended;
  Route.LevelTriggered := Current.LevelTriggered;
  Route.ActiveLow := Current.ActiveLow;
  Result := True;
end;

{ --- Routing tables ------------------------------------------------------------ }

function ResolveSource(const Source: TAmlValue): PAmlNode;
begin
  case Source.Kind of
    AmlNodeReference:
      Result := PAmlNode(Source.Node);
    AmlNamePath:
      Result := LookupNameString(PAmlNode(Source.Node), Source.Bytes^.Data, Source.Bytes^.Length);
    AmlString:
      Result := LookupText(NamespaceRoot, PChar(Source.Bytes^.Data));
  else
    Result := nil;
  end;
end;

function ElementInteger(Package: PAmlPackage; Index: LongWord; out Number: QWord): Boolean;
begin
  Result := (Index < Package^.Count) and ValueToInteger(Package^.Elements[Index], True, Number);
end;

{ Adds the entries of Bridge's _PRT for bus Bus. }
procedure ReadRoutingTable(Bridge: PAmlNode; Segment: Word; Bus: Byte);
var
  Table: TAmlValue;
  Index: LongWord;
  Entry: PAmlValue;
  Address: QWord;
  Pin: QWord;
  SourceIndex: QWord;
  Route: TPciRoute;
  Link: PAmlNode;
begin
  if not EvaluatePath(Bridge, '_PRT', nil, 0, Table) then
    Exit;
  if Table.Kind = AmlPackage then
    for Index := 1 to Table.Package^.Count do
    begin
      Entry := @Table.Package^.Elements[Index - 1];
      if (Entry^.Kind <> AmlPackage) or (Entry^.Package^.Count < 4) or
         not ElementInteger(Entry^.Package, 0, Address) or not ElementInteger(Entry^.Package, 1, Pin) or
         not ElementInteger(Entry^.Package, 3, SourceIndex) or (RouteCount >= MaximumRoutes) then
        Continue;
      ZeroMemory(@Route, SizeOf(Route));
      Route.Segment := Segment;
      Route.Bus := Bus;
      Route.Device := Byte(Address shr 16);
      Route.Pin := Byte(Pin and 3);
      if Entry^.Package^.Elements[2].Kind = AmlInteger then
      begin
        { No link: the interrupt itself. }
        Route.GlobalInterrupt := LongWord(SourceIndex);
        Route.LevelTriggered := True;
        Route.ActiveLow := True;
      end
      else
      begin
        Link := ResolveSource(Entry^.Package^.Elements[2]);
        if (Link = nil) or not LinkInterrupt(Link, LongWord(SourceIndex), Route) then
          Continue;
      end;
      Routes[RouteCount] := Route;
      Inc(RouteCount);
    end;
  ReleaseValue(Table);
end;

{ The bridges below Parent (on bus Bus) that have a _PRT of their own. }
procedure ReadBridgesBelow(Parent: PAmlNode; Segment: Word; Bus: Byte; Depth: Integer);
var
  Child: PAmlNode;
  Address: QWord;
  SecondaryBus: QWord;
begin
  if Depth > 8 then
    Exit;
  Child := Parent^.FirstChild;
  while Child <> nil do
  begin
    if (Child^.Kind = NodeDevice) and (FindChild(Child, SegmentOf('_PRT')) <> nil) and
       (FindChild(Child, SegmentOf('_ADR')) <> nil) then
    begin
      Address := EvaluateInteger(Child, '_ADR', 0);
      if AmlHost.ReadSpace(AmlSpacePciConfiguration, PciConfigurationAddress(Segment, Bus, Byte(Address shr 16),
        Byte(Address and $FFFF), SecondaryBusRegister), 8, SecondaryBus) and (SecondaryBus <> 0) and
        (SecondaryBus <> $FF) then
      begin
        ReadRoutingTable(Child, Segment, Byte(SecondaryBus));
        ReadBridgesBelow(Child, Segment, Byte(SecondaryBus), Depth + 1);
      end;
    end;
    Child := Child^.NextSibling;
  end;
end;

procedure VisitRootBridge(Node: PAmlNode; Context: Pointer);
var
  Segment: QWord;
  Bus: QWord;
begin
  if not IsPciRootBridge(Node) then
    Exit;
  Segment := EvaluateInteger(Node, '_SEG', 0);
  Bus := EvaluateInteger(Node, '_BBN', 0);
  ReadRoutingTable(Node, Word(Segment), Byte(Bus));
  ReadBridgesBelow(Node, Word(Segment), Byte(Bus), 0);
end;

function BuildPciRouting: Integer;
var
  Mode: TAmlValue;
  Ignored: TAmlValue;
begin
  RouteCount := 0;
  if NamespaceRoot = nil then
    Exit(0);
  { The interrupt model: 1, the I/O APICs. }
  Mode := MakeInteger(1);
  if EvaluatePath(NamespaceRoot, '\_PIC', @Mode, 1, Ignored) then
    ReleaseValue(Ignored);
  VisitNodes(NamespaceRoot, @VisitRootBridge, nil);
  Result := RouteCount;
end;

function PciRouteCount: Integer;
begin
  Result := RouteCount;
end;

function PciRouteAt(Index: Integer): PPciRoute;
begin
  if (Index < 0) or (Index >= RouteCount) then
    Exit(nil);
  Result := @Routes[Index];
end;

function FindPciRoute(Segment: Word; Bus, Device, Pin: Byte): PPciRoute;
var
  Index: Integer;
begin
  for Index := 0 to RouteCount - 1 do
    if (Routes[Index].Segment = Segment) and (Routes[Index].Bus = Bus) and (Routes[Index].Device = Device) and
       (Routes[Index].Pin = Pin) then
      Exit(@Routes[Index]);
  Result := nil;
end;

end.

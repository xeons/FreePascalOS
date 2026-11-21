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
  Walking the ACPI namespace for devices that have a hardware id, and
  describing each from its objects.

  The walk goes down from the root through scopes and devices. A device
  whose _STA says it is neither present nor working is skipped with
  everything below it. Each device with a _HID is described: _CID (an id
  or a package of them), _UID, _STA, _CRS (decoded by
  Firmware.AcpiResourceList), _CCA and _DMA (each from the device or the
  nearest device above that has one, as ACPI has children inherit
  them), _DSD (as it is, for Firmware.AcpiProperties) and _SEG.

  An object is looked for among the device's own children only (a bare
  name would otherwise be searched for upwards and find the parent's).

  Plain Pascal over the interpreter, so the host test
  (tools/AcpiDeviceTest) runs it on a table of its own; the kernel's
  Io.AcpiDevices turns the descriptions into platform devices.
}
unit Firmware.AcpiDeviceWalk;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AcpiResourceList;

const
  AcpiIdLength = 16;
  AcpiMaximumCompatibleIds = 4;
  AcpiPathLength = 64;

  { _STA bits. }
  AcpiStatusPresent = 1;
  AcpiStatusFunctioning = 8;

type
  TAcpiIdText = array[0..AcpiIdLength - 1] of Char;

  TAcpiDeviceDescription = record
    Node: PAmlNode;
    { "\_SB_.GDV0.SDC3" }
    Path: array[0..AcpiPathLength - 1] of Char;
    HardwareId: TAcpiIdText;
    CompatibleIdCount: Integer;
    CompatibleIds: array[0..AcpiMaximumCompatibleIds - 1] of TAcpiIdText;
    UniqueId: QWord;
    Status: LongWord;
    Resources: TAcpiResourceList;
    { _CCA found (on the device or above), and what it said. }
    HasCoherency: Boolean;
    Coherent: Boolean;
    { _DMA found, and its memory ranges: Start the processor's address,
      BusStart the device's. }
    HasDma: Boolean;
    DmaRanges: TAcpiResourceList;
    { What _DSD returned (AmlNone if nothing). The visitor keeps it (and
      releases it in the end) or releases it. }
    Properties: TAmlValue;
    { PCI root bridges: _SEG (0 without one). }
    Segment: Word;
  end;

  TAcpiDeviceVisitor = procedure(var Description: TAcpiDeviceDescription; Context: Pointer);

{ Calls Visit for every present device with a _HID, parents first. }
procedure WalkAcpiDevices(Visit: TAcpiDeviceVisitor; Context: Pointer);
{ Evaluates the child Name of Node (not searching upwards). }
function EvaluateChild(Node: PAmlNode; Name: PChar; out Value: TAmlValue): Boolean;
{ The integer the child Name of Node evaluates to, or Default. }
function ChildInteger(Node: PAmlNode; Name: PChar; Default: QWord): QWord;
{ Node's path, "\_SB_.PCI0.BAT0". }
procedure BuildPath(Node: PAmlNode; var Path: array of Char);

implementation

uses
  Runtime.Memory,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds;

const
  { The walk stops this deep (namespaces nest a handful of levels). }
  MaximumDepth = 24;

{ Evaluates the child Name of Node (not searching upwards). }
function EvaluateChild(Node: PAmlNode; Name: PChar; out Value: TAmlValue): Boolean;
var
  Child: PAmlNode;
begin
  ZeroMemory(@Value, SizeOf(Value));
  Child := FindChild(Node, SegmentOf(Name));
  if Child = nil then
    Exit(False);
  Result := EvaluateNode(Child, nil, 0, Value);
end;

function ChildInteger(Node: PAmlNode; Name: PChar; Default: QWord): QWord;
var
  Value: TAmlValue;
begin
  Result := Default;
  if not EvaluateChild(Node, Name, Value) then
    Exit;
  if Value.Kind = AmlInteger then
    Result := Value.Integer;
  ReleaseValue(Value);
end;

{ An id value (EISA integer or string) as text; False if it is neither. }
function IdText(constref Value: TAmlValue; var Text: TAcpiIdText): Boolean;
var
  Length: LongWord;
begin
  Result := True;
  case Value.Kind of
    AmlInteger:
      EisaIdText(LongWord(Value.Integer), @Text[0]);
    AmlString:
      begin
        Length := ValueLength(Value);
        if Length > AcpiIdLength - 1 then
          Length := AcpiIdLength - 1;
        CopyMemory(@Text[0], ValueData(Value), Length);
        Text[Length] := #0;
      end;
  else
    Result := False;
  end;
end;

procedure ReadCompatibleIds(Node: PAmlNode; var Device: TAcpiDeviceDescription);
var
  Value: TAmlValue;
  Index: LongWord;
begin
  if not EvaluateChild(Node, '_CID', Value) then
    Exit;
  if Value.Kind = AmlPackage then
  begin
    for Index := 1 to Value.Package^.Count do
      if (Device.CompatibleIdCount < AcpiMaximumCompatibleIds) and
         IdText(Value.Package^.Elements[Index - 1], Device.CompatibleIds[Device.CompatibleIdCount]) then
        Inc(Device.CompatibleIdCount);
  end
  else if IdText(Value, Device.CompatibleIds[0]) then
    Device.CompatibleIdCount := 1;
  ReleaseValue(Value);
end;

function ReadResources(Node: PAmlNode; Name: PChar; out List: TAcpiResourceList): Boolean;
var
  Value: TAmlValue;
begin
  ZeroMemory(@List, SizeOf(List));
  Result := False;
  if not EvaluateChild(Node, Name, Value) then
    Exit;
  if Value.Kind = AmlBuffer then
  begin
    ParseResourceTemplate(ValueData(Value), ValueLength(Value), List);
    Result := True;
  end;
  ReleaseValue(Value);
end;

{ _CCA of the device or the nearest device above that has one. }
procedure ReadCoherency(Node: PAmlNode; var Device: TAcpiDeviceDescription);
var
  Value: TAmlValue;
begin
  while Node <> nil do
  begin
    if EvaluateChild(Node, '_CCA', Value) then
    begin
      if Value.Kind = AmlInteger then
      begin
        Device.Coherent := Value.Integer <> 0;
        Device.HasCoherency := True;
      end;
      ReleaseValue(Value);
      if Device.HasCoherency then
        Exit;
    end;
    Node := Node^.Parent;
  end;
end;

{ _DMA of the device or the nearest device above that has one. }
procedure ReadDmaRanges(Node: PAmlNode; var Device: TAcpiDeviceDescription);
begin
  while Node <> nil do
  begin
    if ReadResources(Node, '_DMA', Device.DmaRanges) then
    begin
      Device.HasDma := True;
      Exit;
    end;
    Node := Node^.Parent;
  end;
end;

procedure BuildPath(Node: PAmlNode; var Path: array of Char);
var
  Segments: array[0..MaximumDepth - 1] of PAmlNode;
  Count: Integer;
  Length: Integer;
  Index: Integer;
  Character: Integer;
begin
  Count := 0;
  while (Node <> nil) and (Node^.Parent <> nil) and (Count < MaximumDepth) do
  begin
    Segments[Count] := Node;
    Inc(Count);
    Node := Node^.Parent;
  end;
  Path[0] := '\';
  Length := 1;
  Index := Count;
  while Index > 0 do
  begin
    Dec(Index);
    if (Index < Count - 1) and (Length < High(Path)) then
    begin
      Path[Length] := '.';
      Inc(Length);
    end;
    for Character := 0 to 3 do
      if Length < High(Path) then
      begin
        Path[Length] := Segments[Index]^.Name[Character];
        Inc(Length);
      end;
  end;
  Path[Length] := #0;
end;

procedure DescribeDevice(Node: PAmlNode; Status: LongWord; Visit: TAcpiDeviceVisitor; Context: Pointer);
var
  Device: TAcpiDeviceDescription;
  Value: TAmlValue;
  Found: Boolean;
begin
  if not EvaluateChild(Node, '_HID', Value) then
    Exit;
  ZeroMemory(@Device, SizeOf(Device));
  Found := IdText(Value, Device.HardwareId);
  ReleaseValue(Value);
  if not Found then
    Exit;
  Device.Node := Node;
  Device.Status := Status;
  BuildPath(Node, Device.Path);
  ReadCompatibleIds(Node, Device);
  Device.UniqueId := ChildInteger(Node, '_UID', 0);
  ReadResources(Node, '_CRS', Device.Resources);
  ReadCoherency(Node, Device);
  ReadDmaRanges(Node, Device);
  if EvaluateChild(Node, '_DSD', Value) then
  begin
    if Value.Kind = AmlPackage then
      Device.Properties := Value
    else
      ReleaseValue(Value);
  end;
  Device.Segment := Word(ChildInteger(Node, '_SEG', 0));
  Visit(Device, Context);
end;

procedure WalkScope(Scope: PAmlNode; Depth: Integer; Visit: TAcpiDeviceVisitor; Context: Pointer);
var
  Child: PAmlNode;
  Status: LongWord;
begin
  if Depth >= MaximumDepth then
    Exit;
  Child := Scope^.FirstChild;
  while Child <> nil do
  begin
    case Child^.Kind of
      NodeDevice:
        begin
          Status := LongWord(ChildInteger(Child, '_STA', $F));
          if (Status and (AcpiStatusPresent or AcpiStatusFunctioning)) <> 0 then
          begin
            DescribeDevice(Child, Status, Visit, Context);
            WalkScope(Child, Depth + 1, Visit, Context);
          end;
        end;
      NodeScope:
        WalkScope(Child, Depth + 1, Visit, Context);
    end;
    Child := Child^.NextSibling;
  end;
end;

procedure WalkAcpiDevices(Visit: TAcpiDeviceVisitor; Context: Pointer);
begin
  if NamespaceRoot <> nil then
    WalkScope(NamespaceRoot, 0, Visit, Context);
end;

end.

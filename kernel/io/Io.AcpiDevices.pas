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
  Finding the platform devices in the ACPI namespace (Io.PlatformDevices
  keeps them and binds drivers).

  The walk goes down from the root through scopes and devices. A device
  whose _STA says it is neither present nor working is skipped with
  everything below it. Each device with a _HID is recorded with what its
  objects say: _CID (an id or a package of them), _UID, _STA, _CRS (the
  resource template, decoded by Firmware.AcpiResourceList), _CCA and
  _DMA (each from the device or the nearest device above it that has
  one, as ACPI has children inherit them; without _CCA the
  architecture's default holds, see Hal.DmaCoherency), _DSD (kept as it
  is for the drivers' property lookups, Firmware.AcpiProperties), and
  for PCI root bridges _SEG.

  An object is looked for among the device's own children only (a bare
  name would otherwise be searched for upwards and find the parent's).

  Runs while the namespace loads (Io.AcpiNamespace), on its thread with
  the large stack, before anybody else uses the interpreter.
}
unit Io.AcpiDevices;

{$mode objfpc}
{$pointermath on}

interface

{ Records every platform device; returns how many there are. }
function EnumerateAcpiDevices: Integer;

implementation

uses
  Runtime.Memory,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiResourceList,
  Io.Dma,
  Io.PlatformDevices;

const
  { Recursion stops this deep (namespaces nest a handful of levels). }
  MaximumDepth = 24;

{ Evaluates the child Name of Node (not searching upwards). }
function EvaluateChild(Node: PAmlNode; Name: PChar; out Value: TAmlValue): Boolean;
var
  Child: PAmlNode;
begin
  FillMemory(@Value, SizeOf(Value), 0);
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
function IdText(constref Value: TAmlValue; var Text: TPlatformId): Boolean;
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
        if Length > PlatformIdLength - 1 then
          Length := PlatformIdLength - 1;
        CopyMemory(@Text[0], ValueData(Value), Length);
        Text[Length] := #0;
      end;
  else
    Result := False;
  end;
end;

procedure ReadCompatibleIds(Node: PAmlNode; var Device: TPlatformDevice);
var
  Value: TAmlValue;
  Index: LongWord;
begin
  if not EvaluateChild(Node, '_CID', Value) then
    Exit;
  if Value.Kind = AmlPackage then
  begin
    for Index := 1 to Value.Package^.Count do
      if (Device.CompatibleIdCount < MaximumCompatibleIds) and
         IdText(Value.Package^.Elements[Index - 1], Device.CompatibleIds[Device.CompatibleIdCount]) then
        Inc(Device.CompatibleIdCount);
  end
  else if IdText(Value, Device.CompatibleIds[0]) then
    Device.CompatibleIdCount := 1;
  ReleaseValue(Value);
end;

procedure ReadResources(Node: PAmlNode; Name: PChar; out List: TAcpiResourceList; out Found: Boolean);
var
  Value: TAmlValue;
begin
  FillMemory(@List, SizeOf(List), 0);
  Found := False;
  if not EvaluateChild(Node, Name, Value) then
    Exit;
  if Value.Kind = AmlBuffer then
  begin
    ParseResourceTemplate(ValueData(Value), ValueLength(Value), List);
    Found := True;
  end;
  ReleaseValue(Value);
end;

{ _CCA of the device or the nearest device above that has one. }
procedure ReadCoherency(Node: PAmlNode; var Device: TPlatformDevice);
var
  Value: TAmlValue;
begin
  while Node <> nil do
  begin
    if EvaluateChild(Node, '_CCA', Value) then
    begin
      if Value.Kind = AmlInteger then
      begin
        Device.Dma.Coherent := Value.Integer <> 0;
        Device.HasCoherencyObject := True;
      end;
      ReleaseValue(Value);
      if Device.HasCoherencyObject then
        Exit;
    end;
    Node := Node^.Parent;
  end;
end;

{ _DMA of the device or the nearest device above that has one: each of
  its memory ranges is a window, the processor's addresses in Start and
  the bus addresses in BusStart. }
procedure ReadDmaWindows(Node: PAmlNode; var Device: TPlatformDevice);
var
  List: TAcpiResourceList;
  Found: Boolean;
  Index: Integer;
begin
  while Node <> nil do
  begin
    ReadResources(Node, '_DMA', List, Found);
    if Found then
    begin
      Device.HasDmaObject := True;
      for Index := 0 to List.MemoryCount - 1 do
        if Device.Dma.WindowCount < MaximumDmaWindows then
        begin
          Device.Dma.Windows[Device.Dma.WindowCount].PhysicalStart := List.Memory[Index].Start;
          Device.Dma.Windows[Device.Dma.WindowCount].BusStart := List.Memory[Index].BusStart;
          Device.Dma.Windows[Device.Dma.WindowCount].Length := List.Memory[Index].Length;
          Inc(Device.Dma.WindowCount);
        end;
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

procedure RecordDevice(Node: PAmlNode; Status: LongWord);
var
  Device: TPlatformDevice;
  Value: TAmlValue;
  Found: Boolean;
begin
  if not EvaluateChild(Node, '_HID', Value) then
    Exit;
  FillMemory(@Device, SizeOf(Device), 0);
  Found := IdText(Value, Device.HardwareId);
  ReleaseValue(Value);
  if not Found then
    Exit;
  Device.Node := Node;
  Device.Status := Status;
  BuildPath(Node, Device.Path);
  ReadCompatibleIds(Node, Device);
  Device.UniqueId := ChildInteger(Node, '_UID', 0);
  ReadResources(Node, '_CRS', Device.Resources, Found);
  SetDefaultDmaAttributes(Device.Dma);
  ReadCoherency(Node, Device);
  ReadDmaWindows(Node, Device);
  ApplyDmaOptions(Device.Dma);
  if EvaluateChild(Node, '_DSD', Value) then
  begin
    if Value.Kind = AmlPackage then
      Device.Properties := Value
    else
      ReleaseValue(Value);
  end;
  Device.Segment := Word(ChildInteger(Node, '_SEG', 0));
  if not AddPlatformDevice(Device) then
    ReleaseValue(Device.Properties);
end;

procedure WalkScope(Scope: PAmlNode; Depth: Integer);
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
          if (Status and (DeviceStatusPresent or DeviceStatusFunctioning)) <> 0 then
          begin
            RecordDevice(Child, Status);
            WalkScope(Child, Depth + 1);
          end;
        end;
      NodeScope:
        WalkScope(Child, Depth + 1);
    end;
    Child := Child^.NextSibling;
  end;
end;

function EnumerateAcpiDevices: Integer;
begin
  if NamespaceRoot <> nil then
    WalkScope(NamespaceRoot, 0);
  Result := PlatformDeviceCount;
end;

end.

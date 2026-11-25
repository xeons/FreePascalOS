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
  Turning the devices of a thermal zone's active trip points on and off.

  An _ALx entry is a fan device (PNP0C0B) or a power resource. A power
  resource is switched with _ON and _OFF. A fan of ACPI 4.0 with fine
  control (_FSL) is set to 100 or 0 percent; an older fan is switched by
  its power resources (_PR0: all on for running; _OFF of each, and
  _PS3, for stopped; _PS0 before running). Its speed is read from _FST
  where it has one (control level in percent), else from _STA of its
  first power resource (on: 100).

  Plain Pascal over the interpreter (tools/AcpiPowerTest).
}
unit Firmware.AcpiFans;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

{ Runs (On) or stops a cooling device; False if it has no way to be
  told. }
function SetAcpiCoolingDevice(Node: PAmlNode; On: Boolean): Boolean;
{ Its speed now in percent; False if it cannot say. }
function ReadAcpiCoolingSpeed(Node: PAmlNode; out Percent: LongWord): Boolean;

implementation

uses
  Firmware.AmlValues,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceWalk;

const
  FullSpeed = 100;

function Run(Node: PAmlNode; Name: PChar; Arguments: PAmlValue; Count: Integer): Boolean;
var
  Ignored: TAmlValue;
begin
  Result := (FindChild(Node, SegmentOf(Name)) <> nil) and EvaluatePath(Node, Name, Arguments, Count, Ignored);
  if Result then
    ReleaseValue(Ignored);
end;

function ResolveNode(const Value: TAmlValue): PAmlNode;
begin
  case Value.Kind of
    AmlNodeReference:
      Result := PAmlNode(Value.Node);
    AmlNamePath:
      Result := LookupNameString(PAmlNode(Value.Node), Value.Bytes^.Data, Value.Bytes^.Length);
    AmlString:
      Result := LookupText(NamespaceRoot, PChar(Value.Bytes^.Data));
  else
    Result := nil;
  end;
end;

{ _ON or _OFF of every power resource in the device's _PR0; False if it
  has none. }
function SwitchPowerResources(Node: PAmlNode; On: Boolean): Boolean;
var
  List: TAmlValue;
  Index: LongWord;
  Resource: PAmlNode;
begin
  Result := False;
  if not EvaluateChild(Node, '_PR0', List) then
    Exit;
  Index := 0;
  while (List.Kind = AmlPackage) and (Index < List.Package^.Count) do
  begin
    Resource := ResolveNode(List.Package^.Elements[Index]);
    Inc(Index);
    if (Resource = nil) or (Resource^.Kind <> NodePowerResource) then
      Continue;
    if On then
      Result := Run(Resource, '_ON', nil, 0) or Result
    else
      Result := Run(Resource, '_OFF', nil, 0) or Result;
  end;
  ReleaseValue(List);
end;

function SetAcpiCoolingDevice(Node: PAmlNode; On: Boolean): Boolean;
var
  Level: TAmlValue;
begin
  Result := False;
  if Node = nil then
    Exit;
  if Node^.Kind = NodePowerResource then
  begin
    if On then
      Exit(Run(Node, '_ON', nil, 0));
    Exit(Run(Node, '_OFF', nil, 0));
  end;
  if FindChild(Node, SegmentOf('_FSL')) <> nil then
  begin
    if On then
      Level := MakeInteger(FullSpeed)
    else
      Level := MakeInteger(0);
    Exit(Run(Node, '_FSL', @Level, 1));
  end;
  if On then
  begin
    Result := SwitchPowerResources(Node, True);
    Result := Run(Node, '_PS0', nil, 0) or Result;
  end
  else
  begin
    Result := Run(Node, '_PS3', nil, 0);
    Result := SwitchPowerResources(Node, False) or Result;
  end;
end;

function ReadAcpiCoolingSpeed(Node: PAmlNode; out Percent: LongWord): Boolean;
var
  Status: TAmlValue;
  Control: QWord;
  Resource: PAmlNode;
  List: TAmlValue;
begin
  Percent := 0;
  Result := False;
  if Node = nil then
    Exit;
  if (Node^.Kind <> NodePowerResource) and EvaluateChild(Node, '_FST', Status) then
  begin
    if (Status.Kind = AmlPackage) and (Status.Package^.Count >= 2) and
       ValueToInteger(Status.Package^.Elements[1], True, Control) and (Control <= FullSpeed) then
    begin
      Percent := LongWord(Control);
      Result := True;
    end;
    ReleaseValue(Status);
    if Result then
      Exit;
  end;
  Resource := Node;
  if Node^.Kind <> NodePowerResource then
  begin
    Resource := nil;
    if EvaluateChild(Node, '_PR0', List) then
    begin
      if (List.Kind = AmlPackage) and (List.Package^.Count > 0) then
        Resource := ResolveNode(List.Package^.Elements[0]);
      ReleaseValue(List);
    end;
  end;
  if (Resource = nil) or (FindChild(Resource, SegmentOf('_STA')) = nil) then
    Exit;
  if ChildInteger(Resource, '_STA', 0) <> 0 then
    Percent := FullSpeed;
  Result := True;
end;

end.

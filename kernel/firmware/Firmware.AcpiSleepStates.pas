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
  What the namespace says about sleep states and general purpose events.

  Sleep states: each the system supports has a package \_Sx (x from 0,
  working, to 5, soft off) whose first two elements are the values to
  write into the SLP_TYP fields of the PM1a and PM1b control registers
  to enter it.

  General purpose events: GPE number N is handled by the method
  \_GPE._LNN (a level triggered event) or \_GPE._ENN (edge triggered),
  NN in two upper case hex digits.
}
unit Firmware.AcpiSleepStates;

{$mode objfpc}

interface

uses
  Firmware.AmlNamespace;

const
  SleepStateWorking = 0;
  SleepStateSoftOff = 5;

{ The SLP_TYP values of State; False if the system does not have it. }
function SleepTypeOf(State: Integer; out TypeA, TypeB: Byte): Boolean;
{ The method that handles GPE Number, and whether it is level
  triggered; nil if there is none. }
function GpeMethodOf(Number: LongWord; out LevelTriggered: Boolean): PAmlNode;

implementation

uses
  Firmware.AmlValues,
  Firmware.AmlInterpreter;

function SleepTypeOf(State: Integer; out TypeA, TypeB: Byte): Boolean;
var
  Path: array[0..6] of Char;
  Value: TAmlValue;
  Number: QWord;
begin
  TypeA := 0;
  TypeB := 0;
  Result := False;
  if (State < 0) or (State > 5) then
    Exit;
  Path := '\_S0_';
  Path[3] := Char(Ord('0') + State);
  if not EvaluatePath(nil, @Path[0], nil, 0, Value) then
    Exit;
  if (Value.Kind = AmlPackage) and (Value.Package^.Count >= 1) and
     ValueToInteger(Value.Package^.Elements[0], True, Number) then
  begin
    TypeA := Byte(Number and 7);
    TypeB := TypeA;
    if (Value.Package^.Count >= 2) and ValueToInteger(Value.Package^.Elements[1], True, Number) then
      TypeB := Byte(Number and 7);
    Result := True;
  end;
  ReleaseValue(Value);
end;

function GpeMethodOf(Number: LongWord; out LevelTriggered: Boolean): PAmlNode;
const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
var
  Path: array[0..10] of Char;
begin
  Path := '\_GPE._L00';
  Path[8] := HexDigits[(Number shr 4) and $F];
  Path[9] := HexDigits[Number and $F];
  LevelTriggered := True;
  Result := LookupText(NamespaceRoot, @Path[0]);
  if (Result <> nil) and (Result^.Kind = NodeMethod) then
    Exit;
  Path[7] := 'E';
  LevelTriggered := False;
  Result := LookupText(NamespaceRoot, @Path[0]);
  if (Result <> nil) and (Result^.Kind <> NodeMethod) then
    Result := nil;
end;

end.

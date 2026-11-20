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
  The mapped arguments object of a sloppy function with simple
  parameters: arguments[i] and the i-th parameter are one binding for
  each argument passed, until the index is deleted or redefined.

  Only functions that use arguments get one, and only then are their
  parameters kept in the function's environment (the compiler makes
  them captured), so the object reads and writes the environment slots
  directly (Slots: per index, -1 once unmapped). Other indices are the
  object's ordinary elements.
}
unit Js.Arguments;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions;

type
  TJsMappedArguments = class(TJsObject)
  public
    Environment: TJsEnvironment;
    Slots: array of Integer;
    procedure Trace(Tracer: TJsTracer); override;
    { The environment slot of a mapped index key (-1: not mapped). }
    function MappedSlot(Key: TJsValue): Integer; inline;
    procedure Unmap(Key: TJsValue);
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
  end;

{ Links the arguments object to the parameters' slots in Environment
  (ParameterSlots: per parameter; the first Count arguments map). }
procedure MapArguments(Arguments: TJsMappedArguments; Environment: TJsEnvironment;
  const ParameterSlots: array of Integer; Count: Integer);

implementation

procedure TJsMappedArguments.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Environment);
end;

function TJsMappedArguments.MappedSlot(Key: TJsValue): Integer;
var
  Index: LongInt;
begin
  Result := -1;
  if not JsIsInteger(Key) then
    Exit;
  Index := JsAsInteger(Key);
  if (Index >= 0) and (Index < Length(Slots)) then
    Result := Slots[Index];
end;

procedure TJsMappedArguments.Unmap(Key: TJsValue);
begin
  if MappedSlot(Key) >= 0 then
    Slots[JsAsInteger(Key)] := -1;
end;

function TJsMappedArguments.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Slot: Integer;
begin
  Result := inherited GetOwnProperty(R, Key, Desc);
  if Result <= 0 then
    Exit;
  Slot := MappedSlot(Key);
  if Slot >= 0 then
    Desc.Value := Environment.Slots^[Slot];
end;

function TJsMappedArguments.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Slot: Integer;
  Changed: TJsPropertyDescriptor;
begin
  Slot := MappedSlot(Key);
  Changed := Desc;
  if (Slot >= 0) and ((Desc.Present and (HasGetter or HasSetter)) = 0) and ((Desc.Present and HasValue) = 0) and
    ((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) = 0) then
  begin
    { Made read-only: it keeps the parameter's value. }
    Changed.Value := Environment.Slots^[Slot];
    Changed.Present := Changed.Present or HasValue;
  end;
  Result := inherited DefineOwnProperty(R, Key, Changed, ThrowOnFailure);
  if (Result <= 0) or (Slot < 0) then
    Exit;
  if (Desc.Present and (HasGetter or HasSetter)) <> 0 then
    Unmap(Key)
  else
  begin
    if (Desc.Present and HasValue) <> 0 then
      Environment.Slots^[Slot] := Desc.Value;
    if ((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) = 0) then
      Unmap(Key);
  end;
end;

function TJsMappedArguments.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Slot: Integer;
begin
  Slot := MappedSlot(Key);
  if Slot >= 0 then
    Exit(Environment.Slots^[Slot]);
  Result := inherited Get(R, Key, Receiver);
end;

function TJsMappedArguments.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Slot: Integer;
begin
  Slot := -1;
  if Receiver = JsObjectValue(Self) then
    Slot := MappedSlot(Key);
  if Slot >= 0 then
    Environment.Slots^[Slot] := Value;
  Result := SetSlow(R, Key, Value, Receiver);
end;

function TJsMappedArguments.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
begin
  Result := inherited DeleteProperty(R, Key);
  if Result > 0 then
    Unmap(Key);
end;

procedure MapArguments(Arguments: TJsMappedArguments; Environment: TJsEnvironment;
  const ParameterSlots: array of Integer; Count: Integer);
var
  Index: Integer;
begin
  Arguments.Environment := Environment;
  if Count > Length(ParameterSlots) then
    Count := Length(ParameterSlots);
  SetLength(Arguments.Slots, Count);
  for Index := 0 to Count - 1 do
    Arguments.Slots[Index] := ParameterSlots[Index];
end;

end.

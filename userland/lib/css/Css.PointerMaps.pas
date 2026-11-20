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
  A small open addressing hash map from pointers to integers (the
  matcher's sibling index caches, the style resolver's bookkeeping).
}
unit Css.PointerMaps;

{$mode objfpc}
{$H+}

interface

type
  TCssPointerMap = class
  private
    FKeys: array of Pointer;
    FValues: array of PtrInt;
    FCount: Integer;
    FMask: PtrUInt;
    procedure Grow;
    function SlotOf(Key: Pointer): PtrUInt; inline;
  public
    constructor Create;
    function TryGet(Key: Pointer; out Value: PtrInt): Boolean;
    procedure Put(Key: Pointer; Value: PtrInt);
    procedure Clear;
    property Count: Integer read FCount;
  end;

implementation

constructor TCssPointerMap.Create;
begin
  inherited Create;
  SetLength(FKeys, 64);
  SetLength(FValues, 64);
  FMask := 63;
end;

function TCssPointerMap.SlotOf(Key: Pointer): PtrUInt;
var
  Value: PtrUInt;
begin
  Value := PtrUInt(Key) shr 3;
  Value := Value xor (Value shr 17);
  Result := PtrUInt((QWord(Value and $FFFFFFFF) * 2654435761) shr 7) and FMask;
end;

procedure TCssPointerMap.Grow;
var
  OldKeys: array of Pointer;
  OldValues: array of PtrInt;
  Index: Integer;
  Slot: PtrUInt;
begin
  OldKeys := FKeys;
  OldValues := FValues;
  FKeys := nil;
  FValues := nil;
  SetLength(FKeys, Length(OldKeys) * 2);
  SetLength(FValues, Length(OldKeys) * 2);
  FMask := PtrUInt(Length(FKeys) - 1);
  for Index := 0 to High(OldKeys) do
    if OldKeys[Index] <> nil then
    begin
      Slot := SlotOf(OldKeys[Index]);
      while FKeys[Slot] <> nil do
        Slot := (Slot + 1) and FMask;
      FKeys[Slot] := OldKeys[Index];
      FValues[Slot] := OldValues[Index];
    end;
end;

function TCssPointerMap.TryGet(Key: Pointer; out Value: PtrInt): Boolean;
var
  Slot: PtrUInt;
begin
  Value := 0;
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
  begin
    if FKeys[Slot] = Key then
    begin
      Value := FValues[Slot];
      Exit(True);
    end;
    Slot := (Slot + 1) and FMask;
  end;
  Result := False;
end;

procedure TCssPointerMap.Put(Key: Pointer; Value: PtrInt);
var
  Slot: PtrUInt;
begin
  if Key = nil then
    Exit;
  if (FCount + 1) * 2 > Length(FKeys) then
    Grow;
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
  begin
    if FKeys[Slot] = Key then
    begin
      FValues[Slot] := Value;
      Exit;
    end;
    Slot := (Slot + 1) and FMask;
  end;
  FKeys[Slot] := Key;
  FValues[Slot] := Value;
  Inc(FCount);
end;

procedure TCssPointerMap.Clear;
begin
  if FCount = 0 then
    Exit;
  FillChar(FKeys[0], Length(FKeys) * SizeOf(Pointer), 0);
  FCount := 0;
end;

end.

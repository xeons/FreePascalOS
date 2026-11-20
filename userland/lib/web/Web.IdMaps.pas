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
  A map from 64 bit ids (timer handles, job and hop numbers) to objects:
  open addressing with linear probing, a power of two capacity kept at
  most half full, deleted slots marked and reused, so lookups stay
  constant time however many ids come and go. The map does not own its
  objects. (The system's runtime has fgl but not Generics.Collections.)
}
unit Web.IdMaps;

{$mode objfpc}
{$H+}

interface

type
  TIdArray = array of QWord;
  TObjectArray = array of TObject;

  TIdSlotState = (SlotEmpty, SlotUsed, SlotDeleted);

  TIdSlot = record
    Key: QWord;
    Value: TObject;
    State: TIdSlotState;
  end;

  TIdMap = class
  private
    FSlots: array of TIdSlot;
    FCount: Integer;
    FUsedOrDeleted: Integer;
    function SlotOf(Key: QWord): Integer;
    procedure Grow;
  public
    constructor Create;
    { Adds, or replaces the value of an id already there. }
    procedure Add(Key: QWord; Value: TObject);
    function TryGetValue(Key: QWord; out Value: TObject): Boolean;
    function ContainsKey(Key: QWord): Boolean;
    function Remove(Key: QWord): Boolean;
    procedure Clear;
    { Snapshots (any order). }
    function Keys: TIdArray;
    function Values: TObjectArray;
    property Count: Integer read FCount;
  end;

implementation

function HashOf(Key: QWord): QWord; inline;
begin
  { A 64 bit mix (splitmix64's finalizer). }
  Key := (Key xor (Key shr 30)) * QWord($BF58476D1CE4E5B9);
  Key := (Key xor (Key shr 27)) * QWord($94D049BB133111EB);
  Result := Key xor (Key shr 31);
end;

constructor TIdMap.Create;
begin
  inherited Create;
  SetLength(FSlots, 16);
end;

{$push}{$Q-}{$R-}
function TIdMap.SlotOf(Key: QWord): Integer;
var
  Mask: QWord;
  Position: QWord;
begin
  Mask := QWord(Length(FSlots) - 1);
  Position := HashOf(Key) and Mask;
  while FSlots[Position].State <> SlotEmpty do
  begin
    if (FSlots[Position].State = SlotUsed) and (FSlots[Position].Key = Key) then
      Exit(Integer(Position));
    Position := (Position + 1) and Mask;
  end;
  Result := -1;
end;

procedure TIdMap.Grow;
var
  Old: array of TIdSlot;
  Index: Integer;
  Capacity: Integer;
begin
  Old := FSlots;
  Capacity := Length(Old);
  if FCount * 4 >= Capacity then
    Capacity := Capacity * 2;
  FSlots := nil;
  SetLength(FSlots, Capacity);
  FCount := 0;
  FUsedOrDeleted := 0;
  for Index := 0 to High(Old) do
    if Old[Index].State = SlotUsed then
      Add(Old[Index].Key, Old[Index].Value);
end;

procedure TIdMap.Add(Key: QWord; Value: TObject);
var
  Mask, Position: QWord;
  Existing, FirstDeleted: Integer;
begin
  Existing := SlotOf(Key);
  if Existing >= 0 then
  begin
    FSlots[Existing].Value := Value;
    Exit;
  end;
  if (FUsedOrDeleted + 1) * 2 > Length(FSlots) then
    Grow;
  Mask := QWord(Length(FSlots) - 1);
  Position := HashOf(Key) and Mask;
  FirstDeleted := -1;
  while FSlots[Position].State <> SlotEmpty do
  begin
    if (FSlots[Position].State = SlotDeleted) and (FirstDeleted < 0) then
      FirstDeleted := Integer(Position);
    Position := (Position + 1) and Mask;
  end;
  if FirstDeleted >= 0 then
    Position := QWord(FirstDeleted)
  else
    Inc(FUsedOrDeleted);
  FSlots[Position].Key := Key;
  FSlots[Position].Value := Value;
  FSlots[Position].State := SlotUsed;
  Inc(FCount);
end;
{$pop}

function TIdMap.TryGetValue(Key: QWord; out Value: TObject): Boolean;
var
  Position: Integer;
begin
  Position := SlotOf(Key);
  Result := Position >= 0;
  if Result then
    Value := FSlots[Position].Value
  else
    Value := nil;
end;

function TIdMap.ContainsKey(Key: QWord): Boolean;
begin
  Result := SlotOf(Key) >= 0;
end;

function TIdMap.Remove(Key: QWord): Boolean;
var
  Position: Integer;
begin
  Position := SlotOf(Key);
  Result := Position >= 0;
  if not Result then
    Exit;
  FSlots[Position].State := SlotDeleted;
  FSlots[Position].Value := nil;
  Dec(FCount);
end;

procedure TIdMap.Clear;
begin
  FSlots := nil;
  SetLength(FSlots, 16);
  FCount := 0;
  FUsedOrDeleted := 0;
end;

function TIdMap.Keys: TIdArray;
var
  Index, Filled: Integer;
begin
  Result := nil;
  SetLength(Result, FCount);
  Filled := 0;
  for Index := 0 to High(FSlots) do
    if FSlots[Index].State = SlotUsed then
    begin
      Result[Filled] := FSlots[Index].Key;
      Inc(Filled);
    end;
end;

function TIdMap.Values: TObjectArray;
var
  Index, Filled: Integer;
begin
  Result := nil;
  SetLength(Result, FCount);
  Filled := 0;
  for Index := 0 to High(FSlots) do
    if FSlots[Index].State = SlotUsed then
    begin
      Result[Filled] := FSlots[Index].Value;
      Inc(Filled);
    end;
end;

end.

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
  A hash table from pointers to counts, with open addressing and linear
  probing: the garbage collector's set of live objects (is this pointer
  one of ours?), its pinned objects (how often pinned) and the objects
  handed to the embedder.

  Removal shifts the following entries back instead of leaving markers,
  so lookups stay short however much the table churns. The table grows
  at half full and never shrinks below its initial size.
}
unit Wasm.PointerTable;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

type
  TWasmPointerTable = class
  private
    FKeys: array of Pointer;
    FCounts: array of Integer;
    FCount: Integer;
    FMask: PtrUInt;
    function SlotOf(Key: Pointer): PtrUInt; inline;
    procedure Grow;
    procedure Insert(Key: Pointer; Count: Integer);
  public
    constructor Create;
    { Adds Delta to Key's count (Key enters with Delta if absent). }
    procedure Add(Key: Pointer; Delta: Integer = 1);
    { Takes Delta off Key's count; Key leaves at zero. }
    procedure Release(Key: Pointer; Delta: Integer = 1);
    procedure Remove(Key: Pointer);
    function Contains(Key: Pointer): Boolean;
    procedure Clear;
    { The keys, in no particular order (Capacity slots, nil when empty). }
    function KeyAt(Slot: Integer): Pointer; inline;
    function Capacity: Integer; inline;
    property Count: Integer read FCount;
  end;

implementation

const
  InitialCapacity = 64;

constructor TWasmPointerTable.Create;
begin
  inherited Create;
  Clear;
end;

procedure TWasmPointerTable.Clear;
begin
  FKeys := nil;
  FCounts := nil;
  SetLength(FKeys, InitialCapacity);
  SetLength(FCounts, InitialCapacity);
  FMask := InitialCapacity - 1;
  FCount := 0;
end;

function TWasmPointerTable.SlotOf(Key: Pointer): PtrUInt;
var
  Hash: QWord;
begin
  Hash := QWord(PtrUInt(Key)) * QWord($9E3779B97F4A7C15);
  Result := PtrUInt(Hash shr 20) and FMask;
end;

function TWasmPointerTable.KeyAt(Slot: Integer): Pointer;
begin
  Result := FKeys[Slot];
end;

function TWasmPointerTable.Capacity: Integer;
begin
  Result := Length(FKeys);
end;

procedure TWasmPointerTable.Insert(Key: Pointer; Count: Integer);
var
  Slot: PtrUInt;
begin
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
    Slot := (Slot + 1) and FMask;
  FKeys[Slot] := Key;
  FCounts[Slot] := Count;
  Inc(FCount);
end;

procedure TWasmPointerTable.Grow;
var
  OldKeys: array of Pointer;
  OldCounts: array of Integer;
  Index: Integer;
begin
  OldKeys := FKeys;
  OldCounts := FCounts;
  FKeys := nil;
  FCounts := nil;
  SetLength(FKeys, Length(OldKeys) * 2);
  SetLength(FCounts, Length(OldKeys) * 2);
  FMask := PtrUInt(Length(FKeys)) - 1;
  FCount := 0;
  for Index := 0 to High(OldKeys) do
    if OldKeys[Index] <> nil then
      Insert(OldKeys[Index], OldCounts[Index]);
end;

procedure TWasmPointerTable.Add(Key: Pointer; Delta: Integer);
var
  Slot: PtrUInt;
begin
  if Key = nil then
    Exit;
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
  begin
    if FKeys[Slot] = Key then
    begin
      Inc(FCounts[Slot], Delta);
      Exit;
    end;
    Slot := (Slot + 1) and FMask;
  end;
  if (FCount + 1) * 2 > Length(FKeys) then
  begin
    Grow;
    Insert(Key, Delta);
  end
  else
  begin
    FKeys[Slot] := Key;
    FCounts[Slot] := Delta;
    Inc(FCount);
  end;
end;

function TWasmPointerTable.Contains(Key: Pointer): Boolean;
var
  Slot: PtrUInt;
begin
  if Key = nil then
    Exit(False);
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
  begin
    if FKeys[Slot] = Key then
      Exit(True);
    Slot := (Slot + 1) and FMask;
  end;
  Result := False;
end;

procedure TWasmPointerTable.Remove(Key: Pointer);
var
  Slot, Next, Home: PtrUInt;
begin
  if Key = nil then
    Exit;
  Slot := SlotOf(Key);
  while FKeys[Slot] <> Key do
  begin
    if FKeys[Slot] = nil then
      Exit;
    Slot := (Slot + 1) and FMask;
  end;
  FKeys[Slot] := nil;
  Dec(FCount);
  { Move back the entries that probed past the freed slot. }
  Next := (Slot + 1) and FMask;
  while FKeys[Next] <> nil do
  begin
    Home := SlotOf(FKeys[Next]);
    if ((Next - Home) and FMask) >= ((Next - Slot) and FMask) then
    begin
      FKeys[Slot] := FKeys[Next];
      FCounts[Slot] := FCounts[Next];
      FKeys[Next] := nil;
      Slot := Next;
    end;
    Next := (Next + 1) and FMask;
  end;
end;

procedure TWasmPointerTable.Release(Key: Pointer; Delta: Integer);
var
  Slot: PtrUInt;
begin
  if Key = nil then
    Exit;
  Slot := SlotOf(Key);
  while FKeys[Slot] <> nil do
  begin
    if FKeys[Slot] = Key then
    begin
      Dec(FCounts[Slot], Delta);
      if FCounts[Slot] <= 0 then
        Remove(Key);
      Exit;
    end;
    Slot := (Slot + 1) and FMask;
  end;
end;

end.

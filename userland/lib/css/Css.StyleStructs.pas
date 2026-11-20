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
  Style structs: the computed values of one property group, in one
  reference counted block (a header and the group's values).

  Structs are immutable once built and shared: a child inherits an
  inherited group by taking its parent's struct, a group nothing set
  is the shared initial struct, and the struct cache interns the rest
  so that elements with equal values in a group (siblings above all)
  use one struct.
}
unit Css.StyleStructs;

{$mode objfpc}
{$H+}

interface

uses
  Css.PropertyIds, Css.ComputedValues;

type
  PCssStyleStruct = ^TCssStyleStruct;
  TCssStyleStruct = record
    References: LongInt;
    Group: TCssPropertyGroup;
    Interned: Boolean;
    Count: Word;
    Hash: LongWord;
    { Only Count values are allocated. }
    Values: array[0..255] of TCssComputedValue;
  end;

  TCssStructCache = class
  private
    FSlots: array of PCssStyleStruct;
    FCount: Integer;
    FHits: Int64;
    FMisses: Int64;
    procedure Grow;
  public
    destructor Destroy; override;
    { Replaces Struct by an equal interned struct (releasing Struct),
      or interns Struct. The cache holds a reference of its own. }
    procedure Intern(var Struct: PCssStyleStruct);
    { Drops interned structs nobody else uses. }
    procedure Purge;
    procedure Clear;
    property Count: Integer read FCount;
    property Hits: Int64 read FHits;
    property Misses: Int64 read FMisses;
  end;

var
  LiveStructCount: Integer = 0;
  LiveStructBytes: Int64 = 0;

function StructBytes(Group: TCssPropertyGroup): PtrUInt;
function NewStruct(Group: TCssPropertyGroup): PCssStyleStruct;
function CopyStruct(Source: PCssStyleStruct): PCssStyleStruct;
procedure AddRefStruct(Struct: PCssStyleStruct); inline;
procedure ReleaseStruct(var Struct: PCssStyleStruct);
function HashStruct(Struct: PCssStyleStruct): LongWord;
function SameStruct(A, B: PCssStyleStruct): Boolean;
{ The value in a slot. }
function StructValue(Struct: PCssStyleStruct; Slot: Integer): PCssComputedValue; inline;

implementation

uses
  Css.Properties;

function StructBytes(Group: TCssPropertyGroup): PtrUInt;
var
  Count: Integer;
begin
  Count := GroupSize(Group);
  if Count < 1 then
    Count := 1;
  Result := PtrUInt(@PCssStyleStruct(nil)^.Values) + PtrUInt(Count) * SizeOf(TCssComputedValue);
end;

function NewStruct(Group: TCssPropertyGroup): PCssStyleStruct;
var
  Bytes: PtrUInt;
begin
  Bytes := StructBytes(Group);
  Result := AllocMem(Bytes);
  Result^.References := 1;
  Result^.Group := Group;
  Result^.Count := GroupSize(Group);
  InterlockedIncrement(LiveStructCount);
  Inc(LiveStructBytes, Bytes);
end;

function CopyStruct(Source: PCssStyleStruct): PCssStyleStruct;
var
  Slot: Integer;
begin
  Result := NewStruct(Source^.Group);
  for Slot := 0 to Source^.Count - 1 do
  begin
    Result^.Values[Slot] := Source^.Values[Slot];
    AddRefComputed(Result^.Values[Slot]);
  end;
end;

procedure AddRefStruct(Struct: PCssStyleStruct);
begin
  if Struct <> nil then
    InterlockedIncrement(Struct^.References);
end;

procedure ReleaseStruct(var Struct: PCssStyleStruct);
var
  Slot: Integer;
begin
  if Struct = nil then
    Exit;
  if InterlockedDecrement(Struct^.References) = 0 then
  begin
    for Slot := 0 to Struct^.Count - 1 do
      ReleaseComputed(Struct^.Values[Slot]);
    InterlockedDecrement(LiveStructCount);
    Dec(LiveStructBytes, StructBytes(Struct^.Group));
    FreeMem(Struct);
  end;
  Struct := nil;
end;

function StructValue(Struct: PCssStyleStruct; Slot: Integer): PCssComputedValue;
begin
  Result := @Struct^.Values[Slot];
end;

function HashStruct(Struct: PCssStyleStruct): LongWord;
var
  Slot: Integer;
begin
  Result := 2166136261 xor LongWord(Ord(Struct^.Group));
  for Slot := 0 to Struct^.Count - 1 do
    Result := LongWord((QWord(Result xor HashComputed(Struct^.Values[Slot])) * 16777619) and $FFFFFFFF);
  if Result = 0 then
    Result := 1;
end;

function SameStruct(A, B: PCssStyleStruct): Boolean;
var
  Slot: Integer;
begin
  if A = B then
    Exit(True);
  if (A^.Group <> B^.Group) or (A^.Count <> B^.Count) then
    Exit(False);
  for Slot := 0 to A^.Count - 1 do
    if not SameComputed(A^.Values[Slot], B^.Values[Slot]) then
      Exit(False);
  Result := True;
end;

destructor TCssStructCache.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TCssStructCache.Grow;
var
  Old: array of PCssStyleStruct;
  Index: Integer;
  Slot, Mask: LongWord;
begin
  Old := FSlots;
  FSlots := nil;
  if Length(Old) = 0 then
    SetLength(FSlots, 256)
  else
    SetLength(FSlots, Length(Old) * 2);
  Mask := LongWord(Length(FSlots) - 1);
  for Index := 0 to High(Old) do
    if Old[Index] <> nil then
    begin
      Slot := Old[Index]^.Hash and Mask;
      while FSlots[Slot] <> nil do
        Slot := (Slot + 1) and Mask;
      FSlots[Slot] := Old[Index];
    end;
end;

procedure TCssStructCache.Intern(var Struct: PCssStyleStruct);
var
  Slot, Mask: LongWord;
  Existing: PCssStyleStruct;
begin
  if Struct^.Interned then
    Exit;
  if (FCount + 1) * 2 > Length(FSlots) then
    Grow;
  Struct^.Hash := HashStruct(Struct);
  Mask := LongWord(Length(FSlots) - 1);
  Slot := Struct^.Hash and Mask;
  repeat
    Existing := FSlots[Slot];
    if Existing = nil then
      Break;
    if (Existing^.Hash = Struct^.Hash) and SameStruct(Existing, Struct) then
    begin
      Inc(FHits);
      AddRefStruct(Existing);
      ReleaseStruct(Struct);
      Struct := Existing;
      Exit;
    end;
    Slot := (Slot + 1) and Mask;
  until False;
  Inc(FMisses);
  Struct^.Interned := True;
  AddRefStruct(Struct);
  FSlots[Slot] := Struct;
  Inc(FCount);
end;

procedure TCssStructCache.Purge;
var
  Index: Integer;
  Kept: array of PCssStyleStruct;
  KeptCount: Integer;
  Slot, Mask: LongWord;
begin
  Kept := nil;
  KeptCount := 0;
  for Index := 0 to High(FSlots) do
    if FSlots[Index] <> nil then
    begin
      if FSlots[Index]^.References = 1 then
      begin
        FSlots[Index]^.Interned := False;
        ReleaseStruct(FSlots[Index]);
      end
      else
      begin
        SetLength(Kept, KeptCount + 1);
        Kept[KeptCount] := FSlots[Index];
        Inc(KeptCount);
      end;
    end;
  if Length(FSlots) > 0 then
    FillChar(FSlots[0], Length(FSlots) * SizeOf(Pointer), 0);
  FCount := 0;
  Mask := LongWord(Length(FSlots) - 1);
  for Index := 0 to KeptCount - 1 do
  begin
    Slot := Kept[Index]^.Hash and Mask;
    while FSlots[Slot] <> nil do
      Slot := (Slot + 1) and Mask;
    FSlots[Slot] := Kept[Index];
    Inc(FCount);
  end;
end;

procedure TCssStructCache.Clear;
var
  Index: Integer;
begin
  for Index := 0 to High(FSlots) do
    if FSlots[Index] <> nil then
    begin
      FSlots[Index]^.Interned := False;
      ReleaseStruct(FSlots[Index]);
    end;
  FSlots := nil;
  FCount := 0;
end;

end.

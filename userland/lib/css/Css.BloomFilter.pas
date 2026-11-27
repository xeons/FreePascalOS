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
  The ancestor bloom filter: while a tree is styled top-down, the
  names (local name, id, classes; lowercased) of the elements above
  the current one are counted in a 4096 entry counting bloom filter.
  A selector whose ancestor compounds need a name the filter has never
  seen cannot match, and is dropped before any tree walking.

  Each name sets two counters (the low and high 12 bits of its 32 bit
  hash). A counter that reaches 255 stays there.
}
unit Css.BloomFilter;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.ElementAdapter;

const
  BloomFilterBits = 12;
  BloomFilterSize = 1 shl BloomFilterBits;
  BloomFilterMask = BloomFilterSize - 1;

type
  TCssAncestorFilter = class
  private
    FCounters: array[0..BloomFilterSize - 1] of Byte;
    FHashes: array of LongWord;
    FHashCount: Integer;
    { Where each pushed element's hashes start in FHashes. }
    FFrames: array of Integer;
    FElements: array of TCssElement;
    FDepth: Integer;
    procedure AddHash(Hash: LongWord);
    procedure RemoveHash(Hash: LongWord);
  public
    { Adds Element's names as an ancestor of what is styled next. }
    procedure Push(Adapter: TCssElementAdapter; Element: TCssElement);
    procedure Pop;
    procedure Clear;
    { Rebuilds the filter for the ancestors of Element. }
    procedure SetUpFor(Adapter: TCssElementAdapter; Element: TCssElement);
    function MightContain(Hash: LongWord): Boolean; inline;
    { The element pushed last (the parent of what is styled next). }
    function Top: TCssElement;
    property Depth: Integer read FDepth;
  end;

implementation

procedure TCssAncestorFilter.AddHash(Hash: LongWord);
var
  First, Second: LongWord;
begin
  if Hash = 0 then
    Hash := 1;
  First := Hash and BloomFilterMask;
  Second := (Hash shr BloomFilterBits) and BloomFilterMask;
  if FCounters[First] < 255 then
    Inc(FCounters[First]);
  if FCounters[Second] < 255 then
    Inc(FCounters[Second]);
  if FHashCount >= Length(FHashes) then
    SetLength(FHashes, FHashCount * 2 + 64);
  FHashes[FHashCount] := Hash;
  Inc(FHashCount);
end;

procedure TCssAncestorFilter.RemoveHash(Hash: LongWord);
var
  First, Second: LongWord;
begin
  First := Hash and BloomFilterMask;
  Second := (Hash shr BloomFilterBits) and BloomFilterMask;
  if (FCounters[First] > 0) and (FCounters[First] < 255) then
    Dec(FCounters[First]);
  if (FCounters[Second] > 0) and (FCounters[Second] < 255) then
    Dec(FCounters[Second]);
end;

procedure TCssAncestorFilter.Push(Adapter: TCssElementAdapter; Element: TCssElement);
var
  Index, ClassCount: Integer;
  Atom: TCssAtom;
  ClassList: PCssAtom;
begin
  if FDepth >= Length(FFrames) then
  begin
    SetLength(FFrames, FDepth * 2 + 32);
    SetLength(FElements, Length(FFrames));
  end;
  FFrames[FDepth] := FHashCount;
  FElements[FDepth] := Element;
  Inc(FDepth);
  AddHash(AtomHash(LowercaseAtom(Adapter.LocalName(Element))));
  Atom := Adapter.Id(Element);
  if Atom <> NoAtom then
    AddHash(AtomHash(LowercaseAtom(Atom)));
  ClassList := Adapter.Classes(Element, ClassCount);
  for Index := 0 to ClassCount - 1 do
    AddHash(AtomHash(LowercaseAtom(ClassList[Index])));
end;

procedure TCssAncestorFilter.Pop;
var
  Start: Integer;
begin
  if FDepth = 0 then
    Exit;
  Dec(FDepth);
  Start := FFrames[FDepth];
  while FHashCount > Start do
  begin
    Dec(FHashCount);
    RemoveHash(FHashes[FHashCount]);
  end;
end;

procedure TCssAncestorFilter.Clear;
begin
  FillChar(FCounters, SizeOf(FCounters), 0);
  FHashCount := 0;
  FDepth := 0;
end;

procedure TCssAncestorFilter.SetUpFor(Adapter: TCssElementAdapter; Element: TCssElement);
var
  Chain: array of TCssElement;
  Count: Integer;
  Ancestor: TCssElement;
begin
  Clear;
  Chain := nil;
  Count := 0;
  Ancestor := Adapter.Parent(Element);
  while Ancestor <> nil do
  begin
    if Count >= Length(Chain) then
      SetLength(Chain, Count * 2 + 16);
    Chain[Count] := Ancestor;
    Inc(Count);
    Ancestor := Adapter.Parent(Ancestor);
  end;
  while Count > 0 do
  begin
    Dec(Count);
    Push(Adapter, Chain[Count]);
  end;
end;

function TCssAncestorFilter.MightContain(Hash: LongWord): Boolean;
begin
  Result := (FCounters[Hash and BloomFilterMask] <> 0) and
    (FCounters[(Hash shr BloomFilterBits) and BloomFilterMask] <> 0);
end;

function TCssAncestorFilter.Top: TCssElement;
begin
  if FDepth = 0 then
    Result := nil
  else
    Result := FElements[FDepth - 1];
end;

end.

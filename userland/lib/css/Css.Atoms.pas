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
  Atoms: names interned once and compared as integers.

  Every name the style engine compares (element and attribute names,
  namespaces, ids, classes, keywords, custom property names, counter
  and animation names) is an atom of this one process wide table. An
  atom is never freed; atom 0 is the empty name.

  The table is seeded with the keywords of Css.Keywords in their order,
  so a keyword's atom is Ord(Keyword) and keyword tests compare
  integers. Every atom knows the atom of its ASCII lowercase form, for
  the matching that HTML makes case-insensitive.

  A document model that uses this table for its own names (libweb
  does) hands element names, ids and classes to the selector matcher
  without any mapping.
}
unit Css.Atoms;

{$mode objfpc}
{$H+}

interface

type
  TCssAtom = LongWord;
  TCssAtomArray = array of TCssAtom;

const
  NoAtom = 0;

{ The atom of Name (case-sensitive): the same Name always gives the same atom. }
function InternAtom(const Name: string): TCssAtom;
{ The atom of Name's ASCII lowercase form. }
function InternLowercaseAtom(const Name: string): TCssAtom;
{ The atom of Name if it was interned before, else NoAtom. }
function FindAtom(const Name: string): TCssAtom;
function AtomText(Atom: TCssAtom): string;
{ The atom of the ASCII lowercase form of Atom's name. }
function LowercaseAtom(Atom: TCssAtom): TCssAtom;
{ A well mixed 32 bit hash of an atom (the bloom filter's and rule buckets'). }
function AtomHash(Atom: TCssAtom): LongWord;
function AtomCount: Integer;
{ Bytes the table holds (strings, slots). }
function AtomTableBytes: PtrUInt;

function AsciiLowercase(const Text: string): string;
function AsciiSameText(const A, B: string): Boolean;

implementation

uses
  Css.Keywords;

var
  AtomNames: array of string;
  AtomLowercase: array of TCssAtom;
  AtomNameHashes: array of LongWord;
  Count: Integer = 0;
  { Open addressing; each slot holds an atom + 1, 0 is empty. }
  Slots: array of LongWord;
  SlotMask: LongWord = 0;
  TableLock: TRTLCriticalSection;
  LockReady: Boolean = False;

function AsciiLowercase(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
end;

function AsciiSameText(const A, B: string): Boolean;
var
  Index: Integer;
  CharacterA, CharacterB: Char;
begin
  Result := False;
  if Length(A) <> Length(B) then
    Exit;
  for Index := 1 to Length(A) do
  begin
    CharacterA := A[Index];
    CharacterB := B[Index];
    if CharacterA in ['A'..'Z'] then
      CharacterA := Chr(Ord(CharacterA) + 32);
    if CharacterB in ['A'..'Z'] then
      CharacterB := Chr(Ord(CharacterB) + 32);
    if CharacterA <> CharacterB then
      Exit;
  end;
  Result := True;
end;

function HashName(const Name: string): LongWord;
var
  Index: Integer;
begin
  Result := 2166136261;
  for Index := 1 to Length(Name) do
    Result := LongWord((QWord(Result xor Ord(Name[Index])) * 16777619) and $FFFFFFFF);
end;

function AtomHash(Atom: TCssAtom): LongWord;
var
  Value: LongWord;
begin
  Value := LongWord((QWord(Atom) * 2654435761) and $FFFFFFFF);
  Result := Value xor (Value shr 15);
end;

procedure Grow;
var
  NewSize, Index: Integer;
  Slot, Mask: LongWord;
begin
  NewSize := Length(Slots) * 2;
  if NewSize < 1024 then
    NewSize := 1024;
  SetLength(Slots, 0);
  SetLength(Slots, NewSize);
  SlotMask := LongWord(NewSize - 1);
  Mask := SlotMask;
  for Index := 0 to Count - 1 do
  begin
    Slot := AtomNameHashes[Index] and Mask;
    while Slots[Slot] <> 0 do
      Slot := (Slot + 1) and Mask;
    Slots[Slot] := LongWord(Index) + 1;
  end;
end;

function LookUp(const Name: string; Hash: LongWord): TCssAtom;
var
  Slot, Entry: LongWord;
begin
  Result := NoAtom;
  if Length(Slots) = 0 then
    Exit;
  Slot := Hash and SlotMask;
  repeat
    Entry := Slots[Slot];
    if Entry = 0 then
      Exit;
    if (AtomNameHashes[Entry - 1] = Hash) and (AtomNames[Entry - 1] = Name) then
      Exit(Entry - 1);
    Slot := (Slot + 1) and SlotMask;
  until False;
end;

function AddAtom(const Name: string; Hash: LongWord): TCssAtom; forward;

function InternUnlocked(const Name: string): TCssAtom;
var
  Hash: LongWord;
begin
  if Name = '' then
    Exit(NoAtom);
  Hash := HashName(Name);
  Result := LookUp(Name, Hash);
  if Result = NoAtom then
    Result := AddAtom(Name, Hash);
end;

function AddAtom(const Name: string; Hash: LongWord): TCssAtom;
var
  Slot: LongWord;
  Lower: string;
begin
  if (Count + 1) * 2 > Length(Slots) then
    Grow;
  if Count >= Length(AtomNames) then
  begin
    SetLength(AtomNames, Count * 2 + 256);
    SetLength(AtomLowercase, Length(AtomNames));
    SetLength(AtomNameHashes, Length(AtomNames));
  end;
  Result := TCssAtom(Count);
  AtomNames[Count] := Name;
  AtomNameHashes[Count] := Hash;
  AtomLowercase[Count] := Result;
  Inc(Count);
  Slot := Hash and SlotMask;
  while Slots[Slot] <> 0 do
    Slot := (Slot + 1) and SlotMask;
  Slots[Slot] := Result + 1;
  Lower := AsciiLowercase(Name);
  if Lower <> Name then
    AtomLowercase[Result] := InternUnlocked(Lower);
end;

procedure Lock; inline;
begin
  if LockReady then
    EnterCriticalSection(TableLock);
end;

procedure Unlock; inline;
begin
  if LockReady then
    LeaveCriticalSection(TableLock);
end;

function InternAtom(const Name: string): TCssAtom;
begin
  Lock;
  try
    Result := InternUnlocked(Name);
  finally
    Unlock;
  end;
end;

function InternLowercaseAtom(const Name: string): TCssAtom;
begin
  Result := InternAtom(AsciiLowercase(Name));
end;

function FindAtom(const Name: string): TCssAtom;
begin
  if Name = '' then
    Exit(NoAtom);
  Lock;
  try
    Result := LookUp(Name, HashName(Name));
  finally
    Unlock;
  end;
end;

function AtomText(Atom: TCssAtom): string;
begin
  Result := '';
  if Atom < TCssAtom(Count) then
    Result := AtomNames[Atom];
end;

function LowercaseAtom(Atom: TCssAtom): TCssAtom;
begin
  if Atom < TCssAtom(Count) then
    Result := AtomLowercase[Atom]
  else
    Result := Atom;
end;

function AtomCount: Integer;
begin
  Result := Count;
end;

function AtomTableBytes: PtrUInt;
var
  Index: Integer;
begin
  Result := PtrUInt(Length(Slots)) * SizeOf(LongWord) +
    PtrUInt(Length(AtomNames)) * (SizeOf(string) + SizeOf(TCssAtom) + SizeOf(LongWord));
  for Index := 0 to Count - 1 do
    if AtomNames[Index] <> '' then
      Inc(Result, PtrUInt(Length(AtomNames[Index])) + 1 + 2 * SizeOf(PtrInt));
end;

procedure SeedKeywords;
var
  Keyword: TCssKeyword;
  Atom: TCssAtom;
begin
  { Atom 0 is the empty name. }
  SetLength(AtomNames, 1024);
  SetLength(AtomLowercase, 1024);
  SetLength(AtomNameHashes, 1024);
  Grow;
  AtomNames[0] := '';
  AtomNameHashes[0] := HashName('');
  AtomLowercase[0] := 0;
  Count := 1;
  for Keyword := Succ(Low(TCssKeyword)) to High(TCssKeyword) do
  begin
    Atom := InternUnlocked(KeywordName(Keyword));
    if Atom <> TCssAtom(Ord(Keyword)) then
      { A keyword spelled twice in the list: the order would be lost. }
      RunError(201);
  end;
end;

initialization
  SeedKeywords;
  InitCriticalSection(TableLock);
  LockReady := True;
finalization
  LockReady := False;
  DoneCriticalSection(TableLock);
end.

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
  Atoms: names (element and attribute local names, namespaces, prefixes,
  event types, class names) interned once in a process-wide table and
  compared as integers. The table starts with the well-known HTML, SVG
  and MathML names, whose atoms are constants (AtomDiv, AtomSvgNamespace,
  ...; generated from data/well-known-names.txt). Atom 0 (AtomNone) is
  the empty name, which also stands for "no namespace".

  The table only grows; it is not locked, so atoms are made on one thread
  (the one that owns the documents).
}
unit Web.Atoms;

{$mode objfpc}
{$H+}

interface

type
  TAtom = LongWord;
  TAtomArray = array of TAtom;

const
  AtomNone = 0;

{$I Web.Atoms.WellKnown.inc}

{ The atom of a name, made if it is new. }
function Atomize(const Name: string): TAtom;
function AtomizeText(Text: PChar; Count: SizeInt): TAtom;
{ The atom of the name with A-Z made lower case. }
function AtomizeLowerCase(const Name: string): TAtom;
{ The atom of a name if it has one, otherwise AtomNone (nothing is made). }
function FindAtom(const Name: string): TAtom;
function NameOfAtom(Atom: TAtom): string; inline;
function LengthOfAtom(Atom: TAtom): SizeInt; inline;
{ How many atoms there are. }
function TotalAtomCount: LongWord;
function AsciiLowerCase(const Text: string): string;
function AsciiUpperCase(const Text: string): string;

implementation

var
  AtomNames: array of string;
  AtomHashes: array of LongWord;
  { Open addressing: each slot holds an atom, 0 when empty. }
  AtomSlots: array of LongWord;
  AtomSlotMask: LongWord;
  AtomTotal: LongWord;

function HashText(Text: PChar; Count: SizeInt): LongWord;
var
  Index: SizeInt;
  Hash: QWord;
begin
  Hash := 2166136261;
  for Index := 1 to Count do
  begin
    Hash := ((Hash xor Ord(Text[Index - 1])) * 16777619) and $FFFFFFFF;
  end;
  Result := LongWord(Hash);
end;

procedure GrowSlots;
var
  NewSize: LongWord;
  Atom, Slot: LongWord;
begin
  NewSize := Length(AtomSlots) * 2;
  if NewSize < 1024 then
    NewSize := 1024;
  AtomSlots := nil;
  SetLength(AtomSlots, NewSize);
  AtomSlotMask := NewSize - 1;
  Atom := 1;
  while Atom < AtomTotal do
  begin
    Slot := AtomHashes[Atom] and AtomSlotMask;
    while AtomSlots[Slot] <> 0 do
      Slot := (Slot + 1) and AtomSlotMask;
    AtomSlots[Slot] := Atom;
    Inc(Atom);
  end;
end;

function SameText(const Stored: string; Text: PChar; Count: SizeInt): Boolean; inline;
begin
  Result := (Length(Stored) = Count) and (CompareByte(Stored[1], Text^, Count) = 0);
end;

function LookUp(Text: PChar; Count: SizeInt; Hash: LongWord; out Slot: LongWord): TAtom;
var
  Atom: LongWord;
begin
  Slot := Hash and AtomSlotMask;
  while True do
  begin
    Atom := AtomSlots[Slot];
    if Atom = 0 then
      Exit(AtomNone);
    if (AtomHashes[Atom] = Hash) and SameText(AtomNames[Atom], Text, Count) then
      Exit(Atom);
    Slot := (Slot + 1) and AtomSlotMask;
  end;
end;

function AtomizeText(Text: PChar; Count: SizeInt): TAtom;
var
  Hash, Slot: LongWord;
  Name: string;
begin
  if Count <= 0 then
    Exit(AtomNone);
  Hash := HashText(Text, Count);
  Result := LookUp(Text, Count, Hash, Slot);
  if Result <> AtomNone then
    Exit;
  if (AtomTotal + 1) * 2 > Length(AtomSlots) then
  begin
    GrowSlots;
    LookUp(Text, Count, Hash, Slot);
  end;
  if AtomTotal >= Length(AtomNames) then
  begin
    SetLength(AtomNames, Length(AtomNames) * 2);
    SetLength(AtomHashes, Length(AtomNames));
  end;
  SetLength(Name, Count);
  Move(Text^, Name[1], Count);
  Result := AtomTotal;
  AtomNames[Result] := Name;
  AtomHashes[Result] := Hash;
  AtomSlots[Slot] := Result;
  Inc(AtomTotal);
end;

function Atomize(const Name: string): TAtom;
begin
  if Name = '' then
    Exit(AtomNone);
  Result := AtomizeText(PChar(Name), Length(Name));
end;

function AsciiLowerCase(const Text: string): string;
var
  Index: SizeInt;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
    begin
      UniqueString(Result);
      Break;
    end;
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
end;

function AsciiUpperCase(const Text: string): string;
var
  Index: SizeInt;
begin
  Result := Text;
  UniqueString(Result);
  for Index := 1 to Length(Result) do
    if Result[Index] in ['a'..'z'] then
      Result[Index] := Chr(Ord(Result[Index]) - 32);
end;

function AtomizeLowerCase(const Name: string): TAtom;
begin
  Result := Atomize(AsciiLowerCase(Name));
end;

function FindAtom(const Name: string): TAtom;
var
  Slot: LongWord;
begin
  if Name = '' then
    Exit(AtomNone);
  Result := LookUp(PChar(Name), Length(Name), HashText(PChar(Name), Length(Name)), Slot);
end;

function NameOfAtom(Atom: TAtom): string;
begin
  Result := AtomNames[Atom];
end;

function LengthOfAtom(Atom: TAtom): SizeInt;
begin
  Result := Length(AtomNames[Atom]);
end;

function TotalAtomCount: LongWord;
begin
  Result := AtomTotal;
end;

procedure InitializeAtoms;
var
  Index: Integer;
  Atom: TAtom;
begin
  SetLength(AtomNames, 2048);
  SetLength(AtomHashes, 2048);
  AtomNames[0] := '';
  AtomHashes[0] := 0;
  AtomTotal := 1;
  GrowSlots;
  for Index := 1 to WellKnownAtomCount do
  begin
    Atom := Atomize(WellKnownAtomNames[Index]);
    if Atom <> TAtom(Index) then
      RunError(204);
  end;
end;

initialization
  InitializeAtoms;
end.

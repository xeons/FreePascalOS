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
  libweb's atoms as libcss's atoms.

  libweb and libcss each keep one atom table: libweb's starts with the
  well-known HTML names as constants (AtomDiv ...), libcss's with its
  keywords in enum order, so the two cannot be one table. Instead each
  libweb atom is mapped once to the libcss atom of the same name, in an
  array indexed by the libweb atom: the element adapter then answers
  with one array read, and nothing is allocated per element.
}
unit Web.Style.Atoms;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms, Css.Atoms;

{ The libcss atom of the same name as Atom (NoAtom for AtomNone). }
function CssAtomOf(Atom: TAtom): TCssAtom;

implementation

var
  MappedAtoms: array of TCssAtom;

function MapAtom(Atom: TAtom): TCssAtom;
var
  OldLength, NewLength: SizeInt;
begin
  if Atom >= Length(MappedAtoms) then
  begin
    OldLength := Length(MappedAtoms);
    NewLength := OldLength * 2;
    if NewLength < 1024 then
      NewLength := 1024;
    while NewLength <= Atom do
      NewLength := NewLength * 2;
    SetLength(MappedAtoms, NewLength);
    FillChar(MappedAtoms[OldLength], (NewLength - OldLength) * SizeOf(TCssAtom), 0);
  end;
  Result := InternAtom(NameOfAtom(Atom));
  MappedAtoms[Atom] := Result;
end;

function CssAtomOf(Atom: TAtom): TCssAtom;
begin
  if Atom = AtomNone then
    Exit(NoAtom);
  if (Atom < Length(MappedAtoms)) and (MappedAtoms[Atom] <> NoAtom) then
    Result := MappedAtoms[Atom]
  else
    Result := MapAtom(Atom);
end;

end.

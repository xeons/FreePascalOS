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
  New names for files that would take a name already used: what
  "Rename" in a conflict, pasting into the folder a file came from, and
  "New folder" give.

  The number goes in brackets before the extension: "notes.txt" becomes
  "notes (2).txt", then "notes (3).txt"; a folder or a name without an
  extension gets it at the end ("Photos (2)", ".profile (2)"). A name
  that has such a number already counts on from it: a copy of
  "notes (2).txt" is "notes (3).txt", not "notes (2) (2).txt".

  Plain text logic; whether a name is taken is asked through a routine,
  so the host checks it (make files-test).
}
unit FileManager.ConflictNames;

{$mode objfpc}
{$H+}

interface

type
  TNameTakenFunction = function(const Name: string): Boolean of object;

{ Name with Number in brackets (Number 2 and up). }
function NumberedName(const Name: string; IsFolder: Boolean; Number: LongInt): string;
{ Name itself if it is free, else the first numbered one that is. }
function FirstFreeName(const Name: string; IsFolder: Boolean; IsTaken: TNameTakenFunction): string;

implementation

uses
  SysUtils;

const
  { Gives up after this many (and takes the next number anyway). }
  MostNumbersTried = 10000;

{ Splits Name into the part before the extension and the extension
  (with its dot); folders and names whose only dot starts them have no
  extension. }
procedure SplitExtension(const Name: string; IsFolder: Boolean; out Stem, Extension: string);
var
  Index: LongInt;
begin
  Stem := Name;
  Extension := '';
  if IsFolder then
    Exit;
  for Index := Length(Name) downto 2 do
    if Name[Index] = '.' then
    begin
      Stem := Copy(Name, 1, Index - 1);
      Extension := Copy(Name, Index, Length(Name));
      Exit;
    end;
end;

{ A stem ending in " (N)" with N a number from 2 up: the stem before it
  and N. }
function SplitNumber(const Stem: string; out Base: string; out Number: LongInt): Boolean;
var
  Open: LongInt;
  Digits: string;
  Index: LongInt;
begin
  Result := False;
  Base := Stem;
  Number := 1;
  if (Length(Stem) < 4) or (Stem[Length(Stem)] <> ')') then
    Exit;
  Open := Length(Stem) - 1;
  while (Open > 0) and (Stem[Open] in ['0'..'9']) do
    Dec(Open);
  if (Open < 2) or (Stem[Open] <> '(') or (Stem[Open - 1] <> ' ') or (Open = Length(Stem) - 1) then
    Exit;
  Digits := Copy(Stem, Open + 1, Length(Stem) - Open - 1);
  if (Length(Digits) > 6) or (Digits[1] = '0') then
    Exit;
  Number := 0;
  for Index := 1 to Length(Digits) do
    Number := Number * 10 + Ord(Digits[Index]) - Ord('0');
  if Number < 2 then
    Exit;
  Base := Copy(Stem, 1, Open - 2);
  Result := Base <> '';
  if not Result then
  begin
    Base := Stem;
    Number := 1;
  end;
end;

function NumberedName(const Name: string; IsFolder: Boolean; Number: LongInt): string;
var
  Stem: string;
  Extension: string;
  Base: string;
  Existing: LongInt;
begin
  SplitExtension(Name, IsFolder, Stem, Extension);
  SplitNumber(Stem, Base, Existing);
  Result := Base + ' (' + IntToStr(Number) + ')' + Extension;
end;

function FirstFreeName(const Name: string; IsFolder: Boolean; IsTaken: TNameTakenFunction): string;
var
  Stem: string;
  Extension: string;
  Base: string;
  Number: LongInt;
  Tries: LongInt;
begin
  if not IsTaken(Name) then
    Exit(Name);
  SplitExtension(Name, IsFolder, Stem, Extension);
  SplitNumber(Stem, Base, Number);
  Tries := 0;
  repeat
    Inc(Number);
    Inc(Tries);
    Result := Base + ' (' + IntToStr(Number) + ')' + Extension;
  until not IsTaken(Result) or (Tries >= MostNumbersTried);
end;

end.

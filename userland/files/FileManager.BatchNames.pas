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
  Renaming several items at once: F2 on a selection of many, one name
  typed, and each item gets that name with a number in brackets and its
  own extension: "Holiday" over a.jpg, b.jpg and notes.txt gives
  "Holiday (1).jpg", "Holiday (2).jpg" and "Holiday (3).txt".

  A typed name ending in an item's own extension ("Holiday.jpg") does
  not double it; folders get no extension. A number whose name is taken
  by something that is not being renamed is passed over. Plain text
  logic, checked on the host (make files-test).
}
unit FileManager.BatchNames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TBatchItem = record
    Name: string;
    IsFolder: Boolean;
  end;
  TBatchItems = array of TBatchItem;
  TNameTakenFunction = function(const Name: string): Boolean of object;

{ The new names for Items (in their order) from Typed. IsTaken (may be
  nil) says whether a name is used by an item outside the batch. }
function BatchRenameNames(const Typed: string; const Items: TBatchItems; IsTaken: TNameTakenFunction): TStringArray;

implementation

{ The extension of Name with its dot ('' for none or a folder). }
function ExtensionWithDot(const Name: string; IsFolder: Boolean): string;
var
  Dot: LongInt;
begin
  Result := '';
  if IsFolder then
    Exit;
  Dot := Length(Name);
  while (Dot > 1) and (Name[Dot] <> '.') do
    Dec(Dot);
  if Dot > 1 then
    Result := Copy(Name, Dot, Length(Name));
end;

function BatchRenameNames(const Typed: string; const Items: TBatchItems; IsTaken: TNameTakenFunction): TStringArray;
var
  Index: LongInt;
  Number: LongInt;
  Stem: string;
  Extension: string;
  Candidate: string;
  Used: TStringArray;
  function UsedInBatch(const Name: string): Boolean;
  var
    Other: LongInt;
  begin
    for Other := 0 to High(Used) do
      if SameText(Used[Other], Name) then
        Exit(True);
    Result := False;
  end;
begin
  Result := nil;
  Used := nil;
  SetLength(Result, Length(Items));
  SetLength(Used, 0);
  Number := 0;
  for Index := 0 to High(Items) do
  begin
    Extension := ExtensionWithDot(Items[Index].Name, Items[Index].IsFolder);
    Stem := Trim(Typed);
    if (Extension <> '') and (Length(Stem) > Length(Extension)) and
       SameText(Copy(Stem, Length(Stem) - Length(Extension) + 1, Length(Extension)), Extension) then
      Stem := Copy(Stem, 1, Length(Stem) - Length(Extension));
    repeat
      Inc(Number);
      Candidate := Stem + ' (' + IntToStr(Number) + ')' + Extension;
    until not UsedInBatch(Candidate) and (not Assigned(IsTaken) or not IsTaken(Candidate));
    Result[Index] := Candidate;
    SetLength(Used, Length(Used) + 1);
    Used[High(Used)] := Candidate;
  end;
end;

end.

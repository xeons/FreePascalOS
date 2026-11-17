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
  The images beside the one shown, for Next and Previous: the files of
  its folder whose names end in an extension of a format libimage reads
  (BMP, DIB, ICO, CUR, GIF, JPEG, PNG, APNG, TIFF, WebP, JPEG XL), in
  name order without regard to case, numbers compared as numbers
  ("img2" before "img10"). Going past the last comes back to the first.

  Plain logic: the host checks it (make apps-test).
}
unit ImageViewer.FolderImages;

{$mode objfpc}
{$H+}

interface

uses
  Classes;

{ Whether Name has an image file's extension. }
function HasImageExtension(const Name: string): Boolean;
{ Names (plain file names) less those that are not images, sorted. }
procedure KeepImageNames(Names: TStrings);
{ The name Step places from Current among Names (sorted image names),
  wrapping around; Current itself if it is the only one, '' if there
  are none. A Current not among them goes where it would be sorted. }
function NeighbourName(Names: TStrings; const Current: string; Step: LongInt): string;
{ The image files of Folder, sorted (the file system read here). }
procedure ListFolderImages(const Folder: string; Names: TStrings);
{ Compares names as KeepImageNames sorts them. }
function CompareImageNames(const First, Second: string): LongInt;

implementation

uses
  SysUtils;

const
  ImageExtensions: array[0..15] of string = ('bmp', 'dib', 'ico', 'cur', 'gif', 'jpg', 'jpeg', 'jpe', 'jfif', 'png',
    'apng', 'tif', 'tiff', 'webp', 'jxl', 'jng');

function HasImageExtension(const Name: string): Boolean;
var
  Extension: string;
  Index: LongInt;
begin
  Extension := LowerCase(ExtractFileExt(Name));
  if (Extension = '') or (Extension[1] <> '.') then
    Exit(False);
  Delete(Extension, 1, 1);
  for Index := Low(ImageExtensions) to High(ImageExtensions) do
    if ImageExtensions[Index] = Extension then
      Exit(True);
  Result := False;
end;

{ The run of digits at Position, as a number, and where it ends. }
function DigitRun(const Text: string; var Position: LongInt): QWord;
begin
  Result := 0;
  while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
  begin
    if Result < High(QWord) div 10 then
      Result := Result * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
end;

function CompareImageNames(const First, Second: string): LongInt;
var
  Left: string;
  Right: string;
  LeftAt: LongInt;
  RightAt: LongInt;
  LeftNumber: QWord;
  RightNumber: QWord;
begin
  Left := LowerCase(First);
  Right := LowerCase(Second);
  LeftAt := 1;
  RightAt := 1;
  while (LeftAt <= Length(Left)) and (RightAt <= Length(Right)) do
  begin
    if (Left[LeftAt] in ['0'..'9']) and (Right[RightAt] in ['0'..'9']) then
    begin
      LeftNumber := DigitRun(Left, LeftAt);
      RightNumber := DigitRun(Right, RightAt);
      if LeftNumber < RightNumber then
        Exit(-1);
      if LeftNumber > RightNumber then
        Exit(1);
      Continue;
    end;
    if Left[LeftAt] < Right[RightAt] then
      Exit(-1);
    if Left[LeftAt] > Right[RightAt] then
      Exit(1);
    Inc(LeftAt);
    Inc(RightAt);
  end;
  if LeftAt <= Length(Left) then
    Exit(1);
  if RightAt <= Length(Right) then
    Exit(-1);
  { Equal but for case: an order all the same. }
  Result := CompareStr(First, Second);
end;

function CompareListItems(List: TStringList; First, Second: LongInt): LongInt;
begin
  Result := CompareImageNames(List[First], List[Second]);
end;

procedure KeepImageNames(Names: TStrings);
var
  Index: LongInt;
  Sorted: TStringList;
begin
  Sorted := TStringList.Create;
  try
    for Index := 0 to Names.Count - 1 do
      if HasImageExtension(Names[Index]) then
        Sorted.Add(Names[Index]);
    Sorted.CustomSort(@CompareListItems);
    Names.Assign(Sorted);
  finally
    Sorted.Free;
  end;
end;

function NeighbourName(Names: TStrings; const Current: string; Step: LongInt): string;
var
  Index: LongInt;
  Count: LongInt;
begin
  Count := Names.Count;
  if Count = 0 then
    Exit('');
  { Where Current is, or the first name after it. }
  Index := 0;
  while (Index < Count) and (CompareImageNames(Names[Index], Current) < 0) do
    Inc(Index);
  if (Index < Count) and (Names[Index] = Current) then
    Index := Index + Step
  else if Step > 0 then
    Index := Index + Step - 1
  else
    Index := Index + Step;
  Index := ((Index mod Count) + Count) mod Count;
  Result := Names[Index];
end;

procedure ListFolderImages(const Folder: string; Names: TStrings);
var
  Search: TSearchRec;
begin
  Names.Clear;
  if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then
        Names.Add(Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  KeepImageNames(Names);
end;

end.

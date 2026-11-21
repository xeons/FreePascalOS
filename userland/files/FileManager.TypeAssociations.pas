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
  Which programs open a type of file: those whose program.info lists
  its extension (Extensions) or its media type (MimeTypes, "image/*"
  for a whole family), from the program folders (Configuration.
  ProgramFolders). "Open with" lists them; the default is the one the
  user chose for that extension ("Choose a default", kept as
  Files/Defaults/EXTENSION = the program's folder name), else the best
  match: a program naming the extension itself before one naming the
  media type, before one naming the family, then by name.

  Plain logic over the programs given, checked on the host (make
  files-test).
}
unit FileManager.TypeAssociations;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.ProgramInfo,
  Configuration.ProgramFolders;

{ The programs of List that open files with this extension and media
  type, best first. }
function HandlersFor(const List: TProgramList; const Extension, MimeType: string): TProgramList;
{ The index in Handlers of the default: the program in the folder named
  Chosen if it is there, else the first (-1 if there are none). }
function DefaultHandlerIndex(const Handlers: TProgramList; const Chosen: string): LongInt;
{ How well Info matches: 3 the extension, 2 the media type, 1 its
  family, 0 not at all. }
function HandlerMatch(const Info: TProgramInfo; const Extension, MimeType: string): LongInt;

implementation

uses
  SysUtils;

function HandlerMatch(const Info: TProgramInfo; const Extension, MimeType: string): LongInt;
var
  Word: string;
  Family: string;
  Slash: LongInt;
begin
  Result := 0;
  for Word in Info.Extensions do
    if (Extension <> '') and (Word = LowerCase(Extension)) then
      Exit(3);
  Slash := Pos('/', MimeType);
  Family := '';
  if Slash > 0 then
    Family := LowerCase(Copy(MimeType, 1, Slash)) + '*';
  for Word in Info.MimeTypes do
  begin
    if (MimeType <> '') and (Word = LowerCase(MimeType)) then
      Result := 2
    else if (Family <> '') and (Word = Family) and (Result < 1) then
      Result := 1;
  end;
end;

function HandlersFor(const List: TProgramList; const Extension, MimeType: string): TProgramList;
var
  Scores: array of LongInt;
  Index: LongInt;
  Other: LongInt;
  Score: LongInt;
  Swap: TProgramInfo;
  SwapScore: LongInt;
begin
  Result := nil;
  Scores := nil;
  for Index := 0 to High(List) do
  begin
    Score := HandlerMatch(List[Index], Extension, MimeType);
    if Score = 0 then
      Continue;
    SetLength(Result, Length(Result) + 1);
    SetLength(Scores, Length(Scores) + 1);
    Result[High(Result)] := List[Index];
    Scores[High(Scores)] := Score;
  end;
  { Insertion sort: best score first, then by name. }
  for Index := 1 to High(Result) do
  begin
    Other := Index;
    while (Other > 0) and ((Scores[Other] > Scores[Other - 1]) or ((Scores[Other] = Scores[Other - 1]) and
      (CompareText(Result[Other].Name, Result[Other - 1].Name) < 0))) do
    begin
      Swap := Result[Other];
      Result[Other] := Result[Other - 1];
      Result[Other - 1] := Swap;
      SwapScore := Scores[Other];
      Scores[Other] := Scores[Other - 1];
      Scores[Other - 1] := SwapScore;
      Dec(Other);
    end;
  end;
end;

function DefaultHandlerIndex(const Handlers: TProgramList; const Chosen: string): LongInt;
var
  Index: LongInt;
begin
  if Length(Handlers) = 0 then
    Exit(-1);
  if Chosen <> '' then
    for Index := 0 to High(Handlers) do
      if SameText(Handlers[Index].FolderName, Chosen) then
        Exit(Index);
  Result := 0;
end;

end.

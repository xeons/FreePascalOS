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
  Reading and writing the browser's line files (history, bookmarks,
  the session, search engines): a line a record, its fields separated
  by tabs, written whole. Plain logic (the RTL only), checked on the
  host.
}
unit Browser.TextFiles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

{ Tabs and line breaks in a field become spaces. }
function CleanField(const Text: string): string;
{ Fields joined by tabs, each cleaned. }
function JoinFields(const Fields: array of string): string;
{ The field at Index, '' past the last. }
function FieldAt(const Fields: TStringArray; Index: Integer): string;
{ The file's lines (none if it is missing or unreadable); the caller
  frees the list. }
function ReadLines(const Path: string): TStringList;
{ Writes Lines over Path (through a temporary file, so a crash never
  leaves half a file); False if it could not. }
function WriteLines(Lines: TStrings; const Path: string): Boolean;
{ Text lowered for matching (ASCII letters only: UTF-8 stays as it is). }
function FoldCase(const Text: string): string;

implementation

function CleanField(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in [#9, #10, #13] then
      Result[Index] := ' ';
end;

function JoinFields(const Fields: array of string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Fields) do
  begin
    if Index > 0 then
      Result := Result + #9;
    Result := Result + CleanField(Fields[Index]);
  end;
end;

function FieldAt(const Fields: TStringArray; Index: Integer): string;
begin
  if (Index >= 0) and (Index < Length(Fields)) then
    Result := Fields[Index]
  else
    Result := '';
end;

function ReadLines(const Path: string): TStringList;
begin
  Result := TStringList.Create;
  if (Path <> '') and FileExists(Path) then
    try
      Result.LoadFromFile(Path);
    except
      Result.Clear;
    end;
end;

function WriteLines(Lines: TStrings; const Path: string): Boolean;
var
  Temporary: string;
begin
  Result := False;
  if Path = '' then
    Exit;
  Temporary := Path + '.new';
  try
    Lines.SaveToFile(Temporary);
    if FileExists(Path) then
      DeleteFile(Path);
    Result := RenameFile(Temporary, Path);
  except
    { A file that cannot be kept is not worth stopping the browser for. }
    Result := False;
  end;
end;

function FoldCase(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
end;

end.

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
  File names as the file dialogs work with them: what a user types
  turned into a clean absolute path, the folder above one, and whether a
  name fits a filter.

  All of it is text only; nothing here looks at the file system. A
  filter is one or more patterns separated by semicolons ("*.txt;*.md"),
  where "*" stands for any run of characters and "?" for any one, and
  letters match in either case ("*.txt" finds NOTES.TXT too); an empty
  filter lets every name through.
}
unit Controls.FileNames;

{$mode objfpc}
{$H+}

interface

{ Folder and Name joined with one slash; Name alone if it is absolute.
  The result is cleaned up as CleanPath does. }
function CombinePath(const Folder, Name: string): string;
{ An absolute path without empty parts, "." and "..", and without a
  slash at the end (except "/" itself). }
function CleanPath(const Path: string): string;
{ The folder Path is in: "/etc/passwd" -> "/etc", "/etc" -> "/", and
  "/" stays "/". }
function ParentFolderOf(const Path: string): string;
{ The last part of Path: "/etc/passwd" -> "passwd" ("" for "/"). }
function LastPartOf(const Path: string): string;
{ True if Name fits one of Filter's patterns (or Filter is empty). }
function NameMatchesFilter(const Name, Filter: string): Boolean;
{ True if Text has "*" or "?" in it: typed as a file name, it is a new
  filter rather than a file. }
function HasWildcards(const Text: string): Boolean;

implementation

uses
  SysUtils,
  Classes;

{ Splits Path at its slashes, keeping the non-empty parts. }
procedure SplitPath(const Path: string; Parts: TStringList);
var
  Start: LongInt;
  Index: LongInt;
begin
  Start := 1;
  for Index := 1 to Length(Path) + 1 do
    if (Index > Length(Path)) or (Path[Index] = '/') then
    begin
      if Index > Start then
        Parts.Add(Copy(Path, Start, Index - Start));
      Start := Index + 1;
    end;
end;

function CleanPath(const Path: string): string;
var
  Parts: TStringList;
  Kept: TStringList;
  Index: LongInt;
begin
  Parts := TStringList.Create;
  Kept := TStringList.Create;
  try
    SplitPath(Path, Parts);
    for Index := 0 to Parts.Count - 1 do
    begin
      if Parts[Index] = '.' then
        Continue;
      if Parts[Index] = '..' then
      begin
        { Above the root is still the root. }
        if Kept.Count > 0 then
          Kept.Delete(Kept.Count - 1);
        Continue;
      end;
      Kept.Add(Parts[Index]);
    end;
    Result := '';
    for Index := 0 to Kept.Count - 1 do
      Result := Result + '/' + Kept[Index];
    if Result = '' then
      Result := '/';
  finally
    Kept.Free;
    Parts.Free;
  end;
end;

function CombinePath(const Folder, Name: string): string;
begin
  if (Name <> '') and (Name[1] = '/') then
    Result := CleanPath(Name)
  else
    Result := CleanPath(Folder + '/' + Name);
end;

function ParentFolderOf(const Path: string): string;
begin
  Result := CleanPath(Path + '/..');
end;

function LastPartOf(const Path: string): string;
var
  Cleaned: string;
  Index: LongInt;
begin
  Cleaned := CleanPath(Path);
  Index := Length(Cleaned);
  while (Index > 0) and (Cleaned[Index] <> '/') do
    Dec(Index);
  Result := Copy(Cleaned, Index + 1, Length(Cleaned) - Index);
end;

function HasWildcards(const Text: string): Boolean;
begin
  Result := (Pos('*', Text) > 0) or (Pos('?', Text) > 0);
end;

{ Name from NameIndex on against Pattern from PatternIndex on: "*" tries
  every length it could stand for, shortest first. }
function MatchFrom(const Name: string; NameIndex: LongInt; const Pattern: string; PatternIndex: LongInt): Boolean;
var
  Skip: LongInt;
begin
  while PatternIndex <= Length(Pattern) do
  begin
    if Pattern[PatternIndex] = '*' then
    begin
      for Skip := 0 to Length(Name) - NameIndex + 1 do
        if MatchFrom(Name, NameIndex + Skip, Pattern, PatternIndex + 1) then
          Exit(True);
      Exit(False);
    end;
    if NameIndex > Length(Name) then
      Exit(False);
    if (Pattern[PatternIndex] <> '?') and (LowerCase(Pattern[PatternIndex]) <> LowerCase(Name[NameIndex])) then
      Exit(False);
    Inc(PatternIndex);
    Inc(NameIndex);
  end;
  Result := NameIndex > Length(Name);
end;

function NameMatchesFilter(const Name, Filter: string): Boolean;
var
  Patterns: TStringList;
  Index: LongInt;
  Pattern: string;
begin
  if Trim(Filter) = '' then
    Exit(True);
  Patterns := TStringList.Create;
  try
    Patterns.Delimiter := ';';
    Patterns.StrictDelimiter := True;
    Patterns.DelimitedText := Filter;
    for Index := 0 to Patterns.Count - 1 do
    begin
      Pattern := Trim(Patterns[Index]);
      if (Pattern <> '') and MatchFrom(Name, 1, Pattern, 1) then
        Exit(True);
    end;
    Result := False;
  finally
    Patterns.Free;
  end;
end;

end.

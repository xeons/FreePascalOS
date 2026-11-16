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
  Names and paths of settings.

  A setting is named by a path of names separated by "/":

    Notepad/WordWrap            group Notepad, key WordWrap
    Display/0/Scale             group Display, section 0, key Scale
    Terminal/Colours/Text       section Colours of group Terminal

  The first name is the group: a file of its own in each scope
  (Notepad.settings), usually one per program. The last name is the key,
  and the names between are the section it is in (sections nest:
  "A/B"). A path naming a section or a whole group (for listing or
  deleting) has no key.

  A name is 1 to 64 letters, digits, "_", "-" and "."; it starts with a
  letter, a digit or "_" (so a group's file is never hidden, and "." and
  ".." are never names). Names are case-sensitive, like file names.
}
unit Configuration.Names;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  SettingsPathSeparator = '/';
  MaximumSettingsNameLength = 64;

type
  TSettingsPath = record
    Group: string;
    { '' for the group's own keys; 'A' or 'A/B' for a section. }
    Section: string;
    { '' when the path names a section or a group. }
    Key: string;
  end;

function IsSettingsName(const Name: string): Boolean;
{ A section path: names separated by "/", or '' (the group itself). }
function IsSectionPath(const Section: string): Boolean;

{ Splits the path of a key (at least a group and a key); False if it is
  not one. }
function ParseKeyPath(const Path: string; out Parsed: TSettingsPath): Boolean;
{ Splits the path of a group or a section (every name is the group or
  part of the section; Key is ''). '' names no group: every group. }
function ParseSectionPath(const Path: string; out Parsed: TSettingsPath): Boolean;
{ The path a TSettingsPath stands for. }
function SettingsPathText(const Path: TSettingsPath): string;
{ Section joined with a name below it. }
function SubsectionPath(const Section, Name: string): string;

implementation

function IsNameCharacter(Character: Char): Boolean;
begin
  Result := Character in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'];
end;

function IsSettingsName(const Name: string): Boolean;
var
  Index: Integer;
begin
  if (Length(Name) = 0) or (Length(Name) > MaximumSettingsNameLength) then
    Exit(False);
  if not (Name[1] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
    Exit(False);
  for Index := 2 to Length(Name) do
    if not IsNameCharacter(Name[Index]) then
      Exit(False);
  Result := True;
end;

{ Splits Path at every separator; False if any piece is not a name. An
  empty Path gives no names. }
function SplitNames(const Path: string; out Names: TStringArray): Boolean;
var
  Start: Integer;
  Index: Integer;
  Count: Integer;
begin
  Names := nil;
  if Path = '' then
    Exit(True);
  Count := 0;
  Start := 1;
  for Index := 1 to Length(Path) + 1 do
    if (Index > Length(Path)) or (Path[Index] = SettingsPathSeparator) then
    begin
      SetLength(Names, Count + 1);
      Names[Count] := Copy(Path, Start, Index - Start);
      if not IsSettingsName(Names[Count]) then
        Exit(False);
      Inc(Count);
      Start := Index + 1;
    end;
  Result := True;
end;

function IsSectionPath(const Section: string): Boolean;
var
  Names: TStringArray;
begin
  Result := SplitNames(Section, Names);
end;

{ The names First..Last joined with separators. }
function JoinNames(const Names: TStringArray; First, Last: Integer): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := First to Last do
  begin
    if Index > First then
      Result := Result + SettingsPathSeparator;
    Result := Result + Names[Index];
  end;
end;

function ParseKeyPath(const Path: string; out Parsed: TSettingsPath): Boolean;
var
  Names: TStringArray;
begin
  Parsed := Default(TSettingsPath);
  if not SplitNames(Path, Names) or (Length(Names) < 2) then
    Exit(False);
  Parsed.Group := Names[0];
  Parsed.Section := JoinNames(Names, 1, High(Names) - 1);
  Parsed.Key := Names[High(Names)];
  Result := True;
end;

function ParseSectionPath(const Path: string; out Parsed: TSettingsPath): Boolean;
var
  Names: TStringArray;
begin
  Parsed := Default(TSettingsPath);
  if not SplitNames(Path, Names) then
    Exit(False);
  if Length(Names) = 0 then
    Exit(True);
  Parsed.Group := Names[0];
  Parsed.Section := JoinNames(Names, 1, High(Names));
  Result := True;
end;

function SettingsPathText(const Path: TSettingsPath): string;
begin
  Result := Path.Group;
  if Path.Section <> '' then
    Result := Result + SettingsPathSeparator + Path.Section;
  if Path.Key <> '' then
    Result := Result + SettingsPathSeparator + Path.Key;
end;

function SubsectionPath(const Section, Name: string): string;
begin
  if Section = '' then
    Result := Name
  else
    Result := Section + SettingsPathSeparator + Name;
end;

end.

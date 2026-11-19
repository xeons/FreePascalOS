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
  ~/.netrc, where wget finds a user name and password for a host when
  none was given:

    machine example.com login alice password secret
    default login anonymous password me@example.com

  Words are separated by blanks or line ends; "machine NAME" starts an
  entry, "default" the one for every other host; "login", "password"
  (and "account", ignored) fill the current entry; "macdef NAME" skips
  everything up to the next empty line. The first entry for the host
  wins, the default only when none matches. Host names compare without
  regard to case.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Netrc;

{$mode objfpc}
{$H+}

interface

{ The login and password .netrc's text gives Host; False if none. }
function FindNetrcCredentials(const Text, Host: string; out User, Password: string): Boolean;

implementation

uses
  SysUtils;

type
  TNetrcEntry = record
    Machine: string;
    IsDefault: Boolean;
    User, Password: string;
  end;

{ Text without the macro definitions (each up to an empty line). }
function WithoutMacros(const Text: string): string;
var
  Lines: TStringArray;
  Index: Integer;
  InMacro: Boolean;
  Line: string;
begin
  Result := '';
  Lines := StringReplace(Text, #13, '', [rfReplaceAll]).Split([#10]);
  InMacro := False;
  for Index := 0 to High(Lines) do
  begin
    Line := Lines[Index];
    if InMacro then
    begin
      if Trim(Line) = '' then
        InMacro := False;
      Continue;
    end;
    if (Pos('macdef', Line) > 0) and (Copy(Trim(Line), 1, 6) = 'macdef') then
    begin
      InMacro := True;
      Continue;
    end;
    Result := Result + Line + #10;
  end;
end;

function SplitWords(const Text: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and (Text[Position] in [' ', #9, #10]) do
      Inc(Position);
    if Position > Length(Text) then
      Break;
    Start := Position;
    while (Position <= Length(Text)) and not (Text[Position] in [' ', #9, #10]) do
      Inc(Position);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Text, Start, Position - Start);
  end;
end;

function FindNetrcCredentials(const Text, Host: string; out User, Password: string): Boolean;
var
  Words: TStringArray;
  Entries: array of TNetrcEntry;
  Index: Integer;
  Word, Next: string;
  Entry: TNetrcEntry;
begin
  User := '';
  Password := '';
  Result := False;
  Entries := nil;
  Words := SplitWords(WithoutMacros(Text));
  Index := 0;
  while Index <= High(Words) do
  begin
    Word := Words[Index];
    Next := '';
    if Index < High(Words) then
      Next := Words[Index + 1];
    if Word = 'default' then
    begin
      SetLength(Entries, Length(Entries) + 1);
      Entries[High(Entries)] := Default(TNetrcEntry);
      Entries[High(Entries)].IsDefault := True;
      Inc(Index);
      Continue;
    end;
    if (Word = 'machine') or (Word = 'login') or (Word = 'password') or (Word = 'account') then
    begin
      if Word = 'machine' then
      begin
        SetLength(Entries, Length(Entries) + 1);
        Entries[High(Entries)] := Default(TNetrcEntry);
        Entries[High(Entries)].Machine := Next;
      end
      else if Length(Entries) > 0 then
      begin
        if Word = 'login' then
          Entries[High(Entries)].User := Next
        else if Word = 'password' then
          Entries[High(Entries)].Password := Next;
      end;
      Inc(Index, 2);
      Continue;
    end;
    Inc(Index);
  end;
  for Entry in Entries do
    if not Entry.IsDefault and SameText(Entry.Machine, Host) then
    begin
      User := Entry.User;
      Password := Entry.Password;
      Exit(True);
    end;
  for Entry in Entries do
    if Entry.IsDefault then
    begin
      User := Entry.User;
      Password := Entry.Password;
      Exit(True);
    end;
end;

end.

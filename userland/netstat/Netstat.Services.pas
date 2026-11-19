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
  The list of well known ports (/etc/ports, in the format of services(5)):

    # comment
    ssh      22/tcp
    http     80/tcp     www       # aliases follow the port

  A line is a name, "port/protocol" and any aliases; a "#" starts a
  comment anywhere. Lines that do not read as one are skipped. Names
  and protocols compare without regard to case. The first line for a
  port and protocol gives its name.

  Plain Pascal (the RTL only), checked on the host by tools/NetstatTest.
}
unit Netstat.Services;

{$mode objfpc}
{$H+}

interface

const
  PortsFilePath = '/etc/ports';

type
  TServiceEntry = record
    Name: string;
    Port: Word;
    { "tcp", "udp" (lower case). }
    Protocol: string;
    Aliases: array of string;
  end;

  TServiceTable = array of TServiceEntry;

{ The entries of the file's text, in order. }
function ParseServices(const Text: string): TServiceTable;
{ The name of Port for Protocol ("tcp", "udp"), or '' when none is listed. }
function ServiceNameOf(const Table: TServiceTable; Port: Word; const Protocol: string): string;
{ The port a name (or alias) has for Protocol; False when none. }
function ServicePortOf(const Table: TServiceTable; const Name, Protocol: string; out Port: Word): Boolean;

implementation

uses
  SysUtils;

const
  Blanks = [' ', #9, #13];

{ The line without its comment, split at blanks. }
function LineWords(const Line: string): TStringArray;
var
  Text: string;
  CommentStart: Integer;
  Position, Start: Integer;
begin
  Result := nil;
  Text := Line;
  CommentStart := Pos('#', Text);
  if CommentStart > 0 then
    SetLength(Text, CommentStart - 1);
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and (Text[Position] in Blanks) do
      Inc(Position);
    if Position > Length(Text) then
      Break;
    Start := Position;
    while (Position <= Length(Text)) and not (Text[Position] in Blanks) do
      Inc(Position);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Text, Start, Position - Start);
  end;
end;

{ "22/tcp" into its port (1 to 65535) and protocol. }
function ParsePortAndProtocol(const Text: string; out Port: Word; out Protocol: string): Boolean;
var
  Slash: Integer;
  Number: LongInt;
begin
  Port := 0;
  Protocol := '';
  Result := False;
  Slash := Pos('/', Text);
  if (Slash < 2) or (Slash = Length(Text)) then
    Exit;
  if not TryStrToInt(Copy(Text, 1, Slash - 1), Number) or (Number < 1) or (Number > 65535) then
    Exit;
  if not (Text[1] in ['0'..'9']) then
    Exit;
  Port := Number;
  Protocol := LowerCase(Copy(Text, Slash + 1, MaxInt));
  Result := True;
end;

function ParseServices(const Text: string): TServiceTable;
var
  Line: string;
  Words: TStringArray;
  Entry: TServiceEntry;
  Index: Integer;
begin
  Result := nil;
  for Line in Text.Split([#10]) do
  begin
    Words := LineWords(Line);
    if Length(Words) < 2 then
      Continue;
    Entry := Default(TServiceEntry);
    Entry.Name := Words[0];
    if not ParsePortAndProtocol(Words[1], Entry.Port, Entry.Protocol) then
      Continue;
    SetLength(Entry.Aliases, Length(Words) - 2);
    for Index := 2 to High(Words) do
      Entry.Aliases[Index - 2] := Words[Index];
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Entry;
  end;
end;

function ServiceNameOf(const Table: TServiceTable; Port: Word; const Protocol: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Table) do
    if (Table[Index].Port = Port) and SameText(Table[Index].Protocol, Protocol) then
      Exit(Table[Index].Name);
end;

function EntryHasName(constref Entry: TServiceEntry; const Name: string): Boolean;
var
  Alias: string;
begin
  if SameText(Entry.Name, Name) then
    Exit(True);
  for Alias in Entry.Aliases do
    if SameText(Alias, Name) then
      Exit(True);
  Result := False;
end;

function ServicePortOf(const Table: TServiceTable; const Name, Protocol: string; out Port: Word): Boolean;
var
  Index: Integer;
begin
  Port := 0;
  for Index := 0 to High(Table) do
    if SameText(Table[Index].Protocol, Protocol) and EntryHasName(Table[Index], Name) then
    begin
      Port := Table[Index].Port;
      Exit(True);
    end;
  Result := False;
end;

end.

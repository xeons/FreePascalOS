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
  The local terminal during an interactive session: raw mode (no echo,
  no line editing, Ctrl-C read as a byte, so every key goes to the
  remote program) for as long as the session has a remote terminal, and
  the escape character, recognized at the start of a line as OpenSSH's:

    ~.   disconnect
    ~?   list the escapes
    ~~   send one ~
}
unit SshClient.Terminal;

{$mode objfpc}{$H+}

interface

type
  TEscapeFilter = record
    Character: Integer;
    AtLineStart: Boolean;
    PendingEscape: Boolean;
    DisconnectRequested: Boolean;
  end;

procedure EnterRawMode(Handle: Int64);
procedure LeaveRawMode;
procedure StartEscapeFilter(out Filter: TEscapeFilter; Character: Integer);
{ What of Typed goes to the server; the escapes are acted on. }
function FilterTyped(var Filter: TEscapeFilter; const Typed: string): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Kernel;

var
  RawHandle: Int64 = -1;
  SavedMode: Int64 = -1;

procedure EnterRawMode(Handle: Int64);
begin
  SavedMode := GetConsoleMode(Handle);
  if SavedMode < 0 then
    Exit;
  RawHandle := Handle;
  SetConsoleMode(Handle, 0);
end;

procedure LeaveRawMode;
begin
  if (RawHandle >= 0) and (SavedMode >= 0) then
    SetConsoleMode(RawHandle, LongWord(SavedMode));
  RawHandle := -1;
end;

procedure StartEscapeFilter(out Filter: TEscapeFilter; Character: Integer);
begin
  Filter := Default(TEscapeFilter);
  Filter.Character := Character;
  Filter.AtLineStart := True;
end;

procedure SayLocally(const Text: string);
begin
  KernelWrite(StandardErrorHandle, @Text[1], Length(Text));
end;

function FilterTyped(var Filter: TEscapeFilter; const Typed: string): string;
var
  Index: Integer;
  Character: Char;
begin
  if Filter.Character < 0 then
    Exit(Typed);
  Result := '';
  for Index := 1 to Length(Typed) do
  begin
    Character := Typed[Index];
    if Filter.PendingEscape then
    begin
      Filter.PendingEscape := False;
      if Character = '.' then
      begin
        Filter.DisconnectRequested := True;
        Exit;
      end
      else if Character = '?' then
        SayLocally(#13#10'Supported escape sequences:'#13#10 +
          '  ' + Chr(Filter.Character) + '.  - terminate connection'#13#10 +
          '  ' + Chr(Filter.Character) + '?  - this message'#13#10 +
          '  ' + Chr(Filter.Character) + Chr(Filter.Character) + '  - send the escape character'#13#10)
      else if Ord(Character) = Filter.Character then
        Result := Result + Character
      else
        Result := Result + Chr(Filter.Character) + Character;
    end
    else if Filter.AtLineStart and (Ord(Character) = Filter.Character) then
      Filter.PendingEscape := True
    else
      Result := Result + Character;
    Filter.AtLineStart := Character in [#13, #10];
  end;
end;

end.

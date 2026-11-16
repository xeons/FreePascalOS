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
  stdbuf - run a command with modified buffering for its standard streams

  stdbuf [-i MODE] [-o MODE] [-e MODE] COMMAND [ARG]...

  MODE is L (line buffered), 0 (unbuffered) or a size (fully buffered).
  The setting reaches the command through the _STDBUF_O and _STDBUF_E
  variables, which libsystem's streams honor. Standard input is always
  read in blocks; -i is accepted for compatibility.
}
program stdbuf;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Environment,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Util.Commands,
  Util.Messages,
  Util.Sizes;

const
  Usage: PChar = 'Usage: stdbuf OPTION... COMMAND'#10 +
    'Run COMMAND, with modified buffering operations for its standard streams.'#10#10 +
    '  -i, --input=MODE   adjust standard input stream buffering'#10 +
    '  -o, --output=MODE  adjust standard output stream buffering'#10 +
    '  -e, --error=MODE   adjust standard error stream buffering'#10#10 +
    'If MODE is ''L'' the corresponding stream will be line buffered.'#10 +
    'If MODE is ''0'' the corresponding stream will be unbuffered.'#10 +
    'Otherwise MODE is a number which may be followed by one of the following:'#10 +
    'KB 1000, K 1024, MB 1000*1000, M 1024*1024, and so on for G, T.'#10;

procedure CheckMode(const Mode: string);
var
  Size: QWord;
begin
  if (Mode = 'L') or (Mode = '0') or ParseSize(PChar(Mode), Size) then
    Exit;
  Fail(125, 'invalid mode ''%s''', [ArgumentText(PChar(Mode))]);
end;

{ Handles "-o L", "-oL" and "--output=L" for one stream. }
function TakeMode(var Index: Integer; const Short, Long: string; out Mode: string): Boolean;
var
  Text: string;
begin
  Result := True;
  Text := Argument(Index);
  if (Text = Short) and (Index + 1 < ArgumentTotal) then
  begin
    Inc(Index);
    Mode := Argument(Index);
  end
  else if StartsStr(Short, Text) and (Length(Text) > 2) then
    Mode := Copy(Text, 3, MaxInt)
  else if StartsStr(Long, Text) then
    Mode := Copy(Text, Length(Long) + 1, MaxInt)
  else
    Result := False;
  if Result then
    CheckMode(Mode);
end;

var
  Index: Integer;
  Mode: string;
  Options: TProcessOptions;
  AnySetting: Boolean;
begin
  Index := 1;
  AnySetting := False;
  while (Index < ArgumentTotal) and (Argument(Index)[0] = '-') do
  begin
    if string(Argument(Index)) = '--help' then
    begin
      Print(Usage);
      Halt(0);
    end;
    if string(Argument(Index)) = '--' then
    begin
      Inc(Index);
      Break;
    end;
    if TakeMode(Index, '-o', '--output=', Mode) then
      SetVariable('_STDBUF_O', PChar(Mode))
    else if TakeMode(Index, '-e', '--error=', Mode) then
      SetVariable('_STDBUF_E', PChar(Mode))
    else if TakeMode(Index, '-i', '--input=', Mode) then
      SetVariable('_STDBUF_I', PChar(Mode))
    else
      FailWithUsageHint('invalid option -- ''%s''', [ArgumentText(Argument(Index))]);
    AnySetting := True;
    Inc(Index);
  end;
  if not AnySetting then
    FailWithUsageHint('you must specify a buffering mode option', []);
  if Index >= ArgumentTotal then
    FailWithUsageHint('missing operand', []);
  DefaultProcessOptions(Options);
  RunCommandAndExit(ArgumentValues + Index, Options);
end.

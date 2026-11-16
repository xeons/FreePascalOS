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
  Sys.Processes,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Output,
  Util.Sizes;

const
  Usage = 'Usage: stdbuf OPTION... COMMAND'#10 +
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
  if (Mode = 'L') or (Mode = '0') or ParseSize(Mode, Size) then
    Exit;
  Fail(125, Format('invalid mode ''%s''', [Mode]));
end;

{ Handles "-o L", "-oL" and "--output=L" for one stream. }
function TakeMode(const Arguments: TStringArray; var Index: Integer; const Short, Long: string;
  out Mode: string): Boolean;
var
  Text: string;
begin
  Result := True;
  Text := Arguments[Index];
  if (Text = Short) and (Index + 1 < Length(Arguments)) then
  begin
    Inc(Index);
    Mode := Arguments[Index];
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
  Arguments: TStringArray;
  Index: Integer;
  Mode: string;
  Options: TProcessOptions;
  AnySetting: Boolean;
begin
  Arguments := ProgramArguments;
  Index := 0;
  AnySetting := False;
  while (Index < Length(Arguments)) and StartsStr('-', Arguments[Index]) do
  begin
    if Arguments[Index] = '--help' then
    begin
      PrintString(Usage);
      Halt(0);
    end;
    if Arguments[Index] = '--' then
    begin
      Inc(Index);
      Break;
    end;
    if TakeMode(Arguments, Index, '-o', '--output=', Mode) then
      SetVariable('_STDBUF_O', Mode)
    else if TakeMode(Arguments, Index, '-e', '--error=', Mode) then
      SetVariable('_STDBUF_E', Mode)
    else if TakeMode(Arguments, Index, '-i', '--input=', Mode) then
      SetVariable('_STDBUF_I', Mode)
    else
      FailWithUsageHint(Format('invalid option -- ''%s''', [Arguments[Index]]));
    AnySetting := True;
    Inc(Index);
  end;
  if not AnySetting then
    FailWithUsageHint('you must specify a buffering mode option');
  if Index >= Length(Arguments) then
    FailWithUsageHint('missing operand');
  DefaultProcessOptions(Options);
  RunCommandAndExit(Copy(Arguments, Index, MaxInt), Options);
end.

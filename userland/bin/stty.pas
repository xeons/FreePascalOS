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
  stty - change and print terminal line settings

  stty [-a | -g]
  stty SETTING...

  Every terminal (the console, a pseudo-terminal) supports: echo /
  -echo, icanon / -icanon (line editing), isig / -isig (Ctrl-C ends the
  foreground programs), raw (all off), cooked and sane (all on), size,
  rows N and cols N (columns N), and a saved state from stty -g. Speeds
  and control characters are fixed.
}
program stty;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: stty [SETTING]...'#10 +
    '  or:  stty OPTION'#10 +
    'Print or change terminal characteristics.'#10#10 +
    '  -a, --all          print all current settings in human-readable form'#10 +
    '  -g, --save         print all current settings in a stty-readable form'#10#10 +
    'Settings: [-]echo [-]icanon [-]isig raw cooked sane size rows N cols N'#10;

  SavedPrefix = 'fpos:';

var
  ShowAll: Boolean;
  Save: Boolean;
  Settings: TStringList;
  Mode: Int64;

procedure PrintText(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

{ Settings such as "-echo" look like options, so the arguments are
  sorted by hand: -a, -g and --help are options, the rest settings. }
procedure ReadArguments;
var
  Index: Integer;
  Setting: string;
begin
  ShowAll := False;
  Save := False;
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Setting := Argument(Index);
    if (Setting = '-a') or (Setting = '--all') then
      ShowAll := True
    else if (Setting = '-g') or (Setting = '--save') then
      Save := True
    else if Setting = '--help' then
    begin
      Print(Usage);
      Halt(0);
    end
    else
      Settings.Add(Setting);
  end;
end;

function FlagText(const Name: string; Bit: LongWord): string;
begin
  if (Mode and Bit) = 0 then
    Result := '-' + Name
  else
    Result := Name;
end;

procedure ShowSettings;
var
  Rows, Columns: LongInt;
begin
  if Save then
  begin
    PrintText(SavedPrefix + LowerCase(IntToHex(QWord(Mode), 1)) + #10);
    Exit;
  end;
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  PrintText(Format('speed 115200 baud; rows %d; columns %d; line = 0;'#10, [Rows, Columns]));
  if ShowAll then
    WriteLine(StandardOutput, 'intr = ^C; eof = ^D; erase = ^?;');
  PrintText(FlagText('isig', ConsoleModeInterruptKey) + ' ' +
    FlagText('icanon', ConsoleModeLineEditing) + ' ' + FlagText('echo', ConsoleModeEcho) + #10);
end;

procedure FailInvalidArgument(const Setting: string);
begin
  Fail(1, 'invalid argument ''%s''', [ArgumentText(PChar(Setting))]);
end;

{ The mode saved by stty -g ("fpos:" and hexadecimal digits). }
function ParseSavedMode(const Setting: string): LongWord;
var
  SavedValue: Int64;
  Position: Integer;
  Digit: Char;
begin
  SavedValue := 0;
  for Position := Length(SavedPrefix) + 1 to Length(Setting) do
  begin
    Digit := LowerCase(Setting[Position]);
    if Digit in ['0'..'9'] then
      SavedValue := SavedValue * 16 + Ord(Digit) - Ord('0')
    else if Digit in ['a'..'f'] then
      SavedValue := SavedValue * 16 + Ord(Digit) - Ord('a') + 10
    else
      FailInvalidArgument(Setting);
  end;
  Result := LongWord(SavedValue);
end;

{ "rows N", "cols N" or "columns N"; Index is at the setting's name and
  is moved to its number. }
procedure ApplySize(var Index: Integer);
var
  Setting: string;
  SizeValue: Int64;
  Rows, Columns: LongInt;
begin
  Setting := Settings[Index];
  Inc(Index);
  if (Index >= Settings.Count) or not ParseInteger(PChar(Settings[Index]), SizeValue) or
     (SizeValue < 1) or (SizeValue > $FFFF) then
    Fail(1, 'invalid argument for ''%s''', [ArgumentText(PChar(Setting))]);
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  if Setting = 'rows' then
    Rows := LongInt(SizeValue)
  else
    Columns := LongInt(SizeValue);
  if SetConsoleSize(StandardInputHandle, Rows, Columns) <> 0 then
    Fail(1, 'standard input: cannot set the size', []);
end;

procedure ShowSize;
var
  Rows, Columns: LongInt;
begin
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  PrintText(Format('%d %d'#10, [Rows, Columns]));
end;

function ApplySettings: LongWord;
var
  Index: Integer;
  Setting: string;
begin
  Result := LongWord(Mode);
  Index := 0;
  while Index < Settings.Count do
  begin
    Setting := Settings[Index];
    if Setting = 'echo' then
      Result := Result or ConsoleModeEcho
    else if Setting = '-echo' then
      Result := Result and not ConsoleModeEcho
    else if Setting = 'icanon' then
      Result := Result or ConsoleModeLineEditing
    else if Setting = '-icanon' then
      Result := Result and not ConsoleModeLineEditing
    else if Setting = 'isig' then
      Result := Result or ConsoleModeInterruptKey
    else if Setting = '-isig' then
      Result := Result and not ConsoleModeInterruptKey
    else if (Setting = 'raw') or (Setting = '-cooked') then
      Result := 0
    else if (Setting = 'cooked') or (Setting = '-raw') or (Setting = 'sane') then
      Result := ConsoleModeEcho or ConsoleModeLineEditing or ConsoleModeInterruptKey
    else if (Setting = 'rows') or (Setting = 'cols') or (Setting = 'columns') then
      ApplySize(Index)
    else if Setting = 'size' then
      ShowSize
    else if StartsStr(SavedPrefix, Setting) then
      Result := ParseSavedMode(Setting)
    else
      FailInvalidArgument(Setting);
    Inc(Index);
  end;
end;

var
  NewMode: LongWord;
begin
  Settings := TStringList.Create;
  ReadArguments;

  if not IsConsole(StandardInputHandle) then
    Fail(1, 'standard input: Inappropriate ioctl for device', []);
  Mode := GetConsoleMode(StandardInputHandle);
  if Mode < 0 then
    Fail(1, 'standard input: cannot get the settings', []);

  if Settings.Count = 0 then
  begin
    ShowSettings;
    Halt(0);
  end;

  NewMode := ApplySettings;
  if NewMode <> LongWord(Mode) then
    SetConsoleMode(StandardInputHandle, NewMode);
  Settings.Free;
end.

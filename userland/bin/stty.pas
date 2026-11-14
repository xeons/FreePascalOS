{
  stty - change and print terminal line settings

  stty [-a | -g]
  stty SETTING...

  The console supports: echo / -echo, icanon / -icanon (line editing),
  raw (both off), cooked and sane (both on), size, and a saved state
  from stty -g. Speeds and control characters are fixed.
}
program stty;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
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
    'Settings: [-]echo [-]icanon raw cooked sane size'#10;

  SavedPrefix = 'fpos:';

var
  Parser: TOptionParser;
  ShowAll: Boolean;
  Save: Boolean;
  Mode: Int64;
  NewMode: LongWord;
  Index: Integer;
  Setting: PChar;
  Rows, Columns: LongInt;
  SavedValue: Int64;

procedure ShowFlag(Name: PChar; Bit: LongWord);
begin
  if (Mode and Bit) = 0 then
    WriteCharacter(StandardOutput, '-');
  WriteText(StandardOutput, Name);
end;

begin
  ShowAll := False;
  Save := False;
  { Settings such as "-echo" look like options, so the arguments are
    sorted by hand: -a, -g and --help are options, the rest settings. }
  BeginOptions(Parser, [], Usage);
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Setting := Argument(Index);
    if TextIsEqual(Setting, '-a') or TextIsEqual(Setting, '--all') then
      ShowAll := True
    else if TextIsEqual(Setting, '-g') or TextIsEqual(Setting, '--save') then
      Save := True
    else if TextIsEqual(Setting, '--help') then
    begin
      Print(Usage);
      Halt(0);
    end
    else
    begin
      Parser.Operands[Parser.OperandCount] := Setting;
      Inc(Parser.OperandCount);
    end;
  end;

  if not IsConsole(StandardInputHandle) then
    Fail(1, 'standard input: Inappropriate ioctl for device', []);
  Mode := GetConsoleMode(StandardInputHandle);
  if Mode < 0 then
    Fail(1, 'standard input: cannot get the settings', []);

  if Parser.OperandCount = 0 then
  begin
    if Save then
      WriteFormatted(StandardOutput, '%s%x'#10, [ArgumentText(SavedPrefix), ArgumentUnsigned(QWord(Mode))])
    else
    begin
      GetConsoleSize(StandardInputHandle, Rows, Columns);
      WriteFormatted(StandardOutput, 'speed 115200 baud; rows %d; columns %d; line = 0;'#10,
        [ArgumentNumber(Rows), ArgumentNumber(Columns)]);
      if ShowAll then
        WriteLine(StandardOutput, 'intr = ^C; eof = ^D; erase = ^?;');
      ShowFlag('icanon', ConsoleModeLineEditing);
      WriteCharacter(StandardOutput, ' ');
      ShowFlag('echo', ConsoleModeEcho);
      WriteCharacter(StandardOutput, #10);
    end;
    Halt(0);
  end;

  NewMode := LongWord(Mode);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Setting := Parser.Operands[Index];
    if TextIsEqual(Setting, 'echo') then
      NewMode := NewMode or ConsoleModeEcho
    else if TextIsEqual(Setting, '-echo') then
      NewMode := NewMode and not ConsoleModeEcho
    else if TextIsEqual(Setting, 'icanon') then
      NewMode := NewMode or ConsoleModeLineEditing
    else if TextIsEqual(Setting, '-icanon') then
      NewMode := NewMode and not ConsoleModeLineEditing
    else if TextIsEqual(Setting, 'raw') or TextIsEqual(Setting, '-cooked') then
      NewMode := 0
    else if TextIsEqual(Setting, 'cooked') or TextIsEqual(Setting, '-raw') or TextIsEqual(Setting, 'sane') then
      NewMode := ConsoleModeEcho or ConsoleModeLineEditing
    else if TextIsEqual(Setting, 'size') then
    begin
      GetConsoleSize(StandardInputHandle, Rows, Columns);
      WriteFormatted(StandardOutput, '%d %d'#10, [ArgumentNumber(Rows), ArgumentNumber(Columns)]);
    end
    else if TextStartsWith(Setting, SavedPrefix) then
    begin
      SavedValue := 0;
      Setting := Setting + TextLength(SavedPrefix);
      while Setting^ <> #0 do
      begin
        if IsDigit(Setting^) then
          SavedValue := SavedValue * 16 + Ord(Setting^) - Ord('0')
        else if ToLowerCase(Setting^) in ['a'..'f'] then
          SavedValue := SavedValue * 16 + Ord(ToLowerCase(Setting^)) - Ord('a') + 10
        else
          Fail(1, 'invalid argument ''%s''', [ArgumentText(Parser.Operands[Index])]);
        Inc(Setting);
      end;
      NewMode := LongWord(SavedValue);
    end
    else
      Fail(1, 'invalid argument ''%s''', [ArgumentText(Setting)]);
  end;
  if NewMode <> LongWord(Mode) then
    SetConsoleMode(StandardInputHandle, NewMode);
end.

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
  less, more - page through text on the console

  less [-FRSX] [FILE]...
  more [FILE]...

  Shows the files (or standard input) one screen at a time. Keys:
    space f PgDn      next screen          b PgUp        previous screen
    j Enter Down      next line            k Up          previous line
    d u               half a screen down / up
    g Home            first line           G End         last screen
    /PATTERN          search forward (an extended regular expression)
    n N               repeat the search forward / backward
    q Q               quit
  more quits on its own after the last screen. When standard output is
  not the console, the input is copied through unchanged.

  The screen is drawn by printing whole lines (no cursor movement), so
  it works on any console. Keys are read from standard input when that is
  the console, otherwise from standard error's console.
}
program less;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.Kernel,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage = 'Usage: less [-FRSX] [FILE]...'#10 +
    '       more [FILE]...'#10 +
    'Page through FILEs (or standard input) on the console.'#10#10 +
    '  -F, --quit-if-one-screen   quit if the text fits on one screen'#10 +
    '  -R, -S, -X                 accepted for compatibility'#10#10 +
    'Keys: space/f/PgDn next screen, b/PgUp previous screen, j/Enter/Down next line,'#10 +
    'k/Up previous line, d/u half screen, g/Home first line, G/End last screen,'#10 +
    '/PATTERN search, n/N next/previous match, q quit.'#10;

  OptionQuitIfOneScreen = 1;
  OptionIgnored = 2;

  KeyEscape = #27;
  KeyBackspace = #8;
  KeyDelete = #127;
  KeyInterrupt = #3;

  TabWidth = 8;
  HeaderLine = '::::::::::::::';

type
  TKey = (KeyNone, KeyQuit, KeyNextPage, KeyPreviousPage, KeyNextLine, KeyPreviousLine,
    KeyHalfDown, KeyHalfUp, KeyFirst, KeyLast, KeySearch, KeyNextMatch, KeyPreviousMatch, KeyRedraw);

  { The text cut into screen rows, and the screen showing part of it. }
  TPager = class
  private
    FIsMore: Boolean;
    FKeyHandle: Int64;
    FScreenColumns: LongInt;
    FPageRows: Integer;
    FRows: TStringList;
    FTop: Integer;
    FSearchReady: Boolean;
    FSearch: TExpression;
    procedure AddRows(const Line: string);
    function LastTop: Integer;
    procedure ClampTop;
    procedure ClearPrompt;
    procedure DrawPrompt;
    procedure DrawPage;
    procedure ShowMessage(const Message: string);
    function ReadKeyCharacter(out Character: Char): Boolean;
    function ReadEscapeSequence: TKey;
    function ReadKey: TKey;
    function ReadPattern(out Pattern: string): Boolean;
    function RowMatches(Index: Integer): Boolean;
    procedure FindMatch(Forward: Boolean);
    procedure StartSearch;
  public
    constructor Create(IsMore: Boolean; KeyHandle: Int64);
    destructor Destroy; override;
    { Adds a file's rows (with a header naming it when ShowHeader). }
    function LoadInput(const Path: string; ShowHeader: Boolean): Boolean;
    { True if every row fits on one screen. }
    function FitsOnScreen: Boolean;
    procedure PrintAllRows;
    procedure Page;
  end;

{ --- Copying through ------------------------------------------------- }

function CopyThrough(const Path: string): Boolean;
var
  Stream: PInputStream;
  Buffer: array[0..4095] of Byte;
  Count: QWord;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit(False);
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    WriteBytes(StandardOutput, @Buffer[0], Count);
  until Count = 0;
  CloseInput(Stream);
  Result := True;
end;

{ --- Building rows --------------------------------------------------- }

constructor TPager.Create(IsMore: Boolean; KeyHandle: Int64);
var
  ScreenRows: LongInt;
begin
  inherited Create;
  FIsMore := IsMore;
  FKeyHandle := KeyHandle;
  FRows := TStringList.Create;
  GetConsoleSize(StandardOutputHandle, ScreenRows, FScreenColumns);
  if ScreenRows < 2 then
    ScreenRows := 2;
  if FScreenColumns < 10 then
    FScreenColumns := 10;
  FPageRows := ScreenRows - 1;
end;

destructor TPager.Destroy;
begin
  if FSearchReady then
    FreeExpression(FSearch);
  FRows.Free;
  inherited Destroy;
end;

{ Expands tabs and cuts Line into rows of at most a screen width less
  one. }
procedure TPager.AddRows(const Line: string);
var
  Width: Integer;
  Row: string;
  Column: Integer;
  Index: Integer;
  Character: Char;

  procedure FinishRow;
  begin
    FRows.Add(Row);
    Row := '';
    Column := 0;
  end;

  procedure AddCharacter(Added: Char);
  begin
    Row := Row + Added;
    Inc(Column);
  end;

begin
  Width := FScreenColumns - 1;
  Row := '';
  Column := 0;
  for Index := 1 to Length(Line) do
  begin
    Character := Line[Index];
    if Character = #9 then
    begin
      repeat
        AddCharacter(' ');
      until (Column mod TabWidth = 0) or (Column >= Width);
    end
    else if Character = #13 then
      { Carriage returns would move the console cursor. }
    else if Character < ' ' then
    begin
      AddCharacter('^');
      if Column >= Width then
        FinishRow;
      AddCharacter(Char(Ord(Character) + 64));
    end
    else
      AddCharacter(Character);
    if Column >= Width then
    begin
      FinishRow;
      { The line filled its last row exactly. }
      if Index = Length(Line) then
        Exit;
    end;
  end;
  FRows.Add(Row);
end;

function TPager.LoadInput(const Path: string; ShowHeader: Boolean): Boolean;
var
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit(False);
  if ShowHeader then
  begin
    FRows.Add(HeaderLine);
    AddRows(Path);
    FRows.Add(HeaderLine);
  end;
  while ReadTextLine(Stream, Line, HadLineEnd) do
    AddRows(Line);
  CloseInput(Stream);
  Result := True;
end;

function TPager.FitsOnScreen: Boolean;
begin
  Result := FRows.Count <= FPageRows;
end;

procedure TPager.PrintAllRows;
var
  Row: string;
begin
  for Row in FRows do
    PrintStringLine(Row);
end;

{ --- Drawing --------------------------------------------------------- }

function TPager.LastTop: Integer;
begin
  Result := FRows.Count - FPageRows;
  if Result < 0 then
    Result := 0;
end;

procedure TPager.ClampTop;
begin
  if FTop > LastTop then
    FTop := LastTop;
  if FTop < 0 then
    FTop := 0;
end;

procedure TPager.ClearPrompt;
begin
  PrintString(#13 + StringOfChar(' ', FScreenColumns - 1) + #13);
end;

procedure TPager.DrawPrompt;
var
  Percent: Int64;
begin
  if FIsMore then
  begin
    if FRows.Count = 0 then
      Percent := 100
    else
      Percent := (Int64(FTop + FPageRows) * 100) div FRows.Count;
    if Percent > 100 then
      Percent := 100;
    PrintString(Format('--More--(%d%%)', [Percent]));
  end
  else if FTop >= LastTop then
    PrintString('(END)')
  else
    PrintString(':');
  FlushStream(StandardOutput);
end;

procedure TPager.DrawPage;
var
  Index: Integer;
begin
  ClearPrompt;
  for Index := FTop to FTop + FPageRows - 1 do
  begin
    if Index < FRows.Count then
      PrintStringLine(FRows[Index])
    else if not FIsMore then
      PrintStringLine('~')
    else
      PrintStringLine('');
  end;
  DrawPrompt;
end;

procedure TPager.ShowMessage(const Message: string);
begin
  ClearPrompt;
  PrintString(Message + '  (press a key)');
  FlushStream(StandardOutput);
end;

{ --- Keys ------------------------------------------------------------ }

function TPager.ReadKeyCharacter(out Character: Char): Boolean;
begin
  Result := KernelRead(FKeyHandle, @Character, 1) = 1;
end;

{ The rest of a key that sends an escape sequence. }
function TPager.ReadEscapeSequence: TKey;
var
  Character: Char;
  Parameter: Integer;
begin
  Result := KeyNone;
  if not ReadKeyCharacter(Character) then
    Exit;
  if (Character <> '[') and (Character <> 'O') then
    Exit;
  Parameter := 0;
  repeat
    if not ReadKeyCharacter(Character) then
      Exit;
    if Character in ['0'..'9'] then
      Parameter := Parameter * 10 + Ord(Character) - Ord('0');
  until (Character >= '@') and (Character <= '~');
  case Character of
    'A': Result := KeyPreviousLine;
    'B': Result := KeyNextLine;
    'H': Result := KeyFirst;
    'F': Result := KeyLast;
    '~':
      case Parameter of
        1, 7: Result := KeyFirst;
        4, 8: Result := KeyLast;
        5: Result := KeyPreviousPage;
        6: Result := KeyNextPage;
      end;
  end;
end;

function TPager.ReadKey: TKey;
var
  Character: Char;
begin
  if not ReadKeyCharacter(Character) then
    Exit(KeyQuit);
  case Character of
    'q', 'Q', KeyInterrupt: Result := KeyQuit;
    ' ', 'f', 'z', #6, #22: Result := KeyNextPage;
    'b', 'w', #2: Result := KeyPreviousPage;
    'j', 'e', #10, #13, #14, #5: Result := KeyNextLine;
    'k', 'y', 'p', #16, #25, #11: Result := KeyPreviousLine;
    'd', #4: Result := KeyHalfDown;
    'u', #21: Result := KeyHalfUp;
    'g', '<': Result := KeyFirst;
    'G', '>': Result := KeyLast;
    '/': Result := KeySearch;
    'n': Result := KeyNextMatch;
    'N': Result := KeyPreviousMatch;
    'r', 'R', #12: Result := KeyRedraw;
    KeyEscape: Result := ReadEscapeSequence;
  else
    Result := KeyNone;
  end;
end;

{ Reads the search pattern after "/", echoing it. Returns False if it
  was abandoned (Escape, or erasing past the start). }
function TPager.ReadPattern(out Pattern: string): Boolean;
var
  Character: Char;
begin
  ClearPrompt;
  PrintString('/');
  FlushStream(StandardOutput);
  Pattern := '';
  repeat
    if not ReadKeyCharacter(Character) then
      Character := KeyEscape;
    case Character of
      #10, #13: Exit(True);
      KeyEscape, KeyInterrupt: Exit(False);
      KeyBackspace, KeyDelete:
        begin
          if Pattern = '' then
            Exit(False);
          SetLength(Pattern, Length(Pattern) - 1);
          PrintString(#8' '#8);
        end;
    else
      if Character >= ' ' then
      begin
        Pattern := Pattern + Character;
        PrintString(Character);
      end;
    end;
    FlushStream(StandardOutput);
  until False;
end;

function TPager.RowMatches(Index: Integer): Boolean;
var
  Match: TMatch;
begin
  Result := SearchExpression(FSearch, FRows[Index], Match);
end;

{ Moves the top to the next (or previous) row that matches. }
procedure TPager.FindMatch(Forward: Boolean);
var
  Index: Integer;
begin
  if not FSearchReady then
  begin
    ShowMessage('No previous regular expression');
    ReadKey;
    Exit;
  end;
  if Forward then
  begin
    for Index := FTop + 1 to FRows.Count - 1 do
      if RowMatches(Index) then
      begin
        FTop := Index;
        Exit;
      end;
  end
  else
  begin
    for Index := FTop - 1 downto 0 do
      if RowMatches(Index) then
      begin
        FTop := Index;
        Exit;
      end;
  end;
  ShowMessage('Pattern not found');
  ReadKey;
end;

procedure TPager.StartSearch;
var
  Pattern: string;
  ErrorMessage: string;
begin
  if not ReadPattern(Pattern) then
    Exit;
  if Pattern <> '' then
  begin
    if FSearchReady then
      FreeExpression(FSearch);
    FSearchReady := CompileExpression(Pattern, SyntaxExtended, FSearch, ErrorMessage);
    if not FSearchReady then
    begin
      ShowMessage(ErrorMessage);
      ReadKey;
      Exit;
    end;
  end;
  { The search starts on the first row shown. }
  Dec(FTop);
  FindMatch(True);
  if (FTop < 0) or not RowMatches(FTop) then
    Inc(FTop);
end;

procedure TPager.Page;
var
  Key: TKey;
  SavedMode: Int64;
begin
  SavedMode := GetConsoleMode(FKeyHandle);
  { One key at a time, without echo; Ctrl-C still interrupts. }
  SetConsoleMode(FKeyHandle, ConsoleModeInterruptKey);
  FTop := 0;
  repeat
    ClampTop;
    DrawPage;
    if FIsMore and (FTop >= LastTop) then
      Break;
    Key := ReadKey;
    case Key of
      KeyQuit: Break;
      KeyNextPage:
        begin
          if FIsMore or (FTop < LastTop) then
            FTop := FTop + FPageRows;
        end;
      KeyPreviousPage: FTop := FTop - FPageRows;
      KeyNextLine: Inc(FTop);
      KeyPreviousLine: Dec(FTop);
      KeyHalfDown: FTop := FTop + FPageRows div 2;
      KeyHalfUp: FTop := FTop - FPageRows div 2;
      KeyFirst: FTop := 0;
      KeyLast: FTop := LastTop;
      KeySearch: StartSearch;
      KeyNextMatch: FindMatch(True);
      KeyPreviousMatch: FindMatch(False);
    end;
  until False;
  ClearPrompt;
  FlushStream(StandardOutput);
  if SavedMode >= 0 then
    SetConsoleMode(FKeyHandle, LongWord(SavedMode));
end;

{ --- The program ----------------------------------------------------- }

{ Where keys come from: the console on standard input or standard
  error, when standard output is the console too; -1 for none. }
function ChooseKeyHandle(const Paths: TStringArray): Int64;
var
  Path: string;
begin
  if IsConsole(StandardInputHandle) and IsConsole(StandardOutputHandle) then
    Result := StandardInputHandle
  else if IsConsole(StandardErrorHandle) and IsConsole(StandardOutputHandle) then
    Result := StandardErrorHandle
  else
    Result := -1;
  { Reading the text from the console that also gives the keys makes no
    sense; behave like cat then. }
  if Result = StandardInputHandle then
    for Path in Paths do
      if Path = '-' then
        Result := -1;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  QuitIfOneScreen: Boolean;
  IsMore: Boolean;
  Paths: TStringArray;
  Path: string;
  KeyHandle: Int64;
  Pager: TPager;
  Status: LongInt;
begin
  IsMore := BaseName(string(Argument(0))) = 'more';
  QuitIfOneScreen := False;
  Status := 0;
  CommandLine := TCommandLine.Create([
    CommandOption('F', 'quit-if-one-screen', False, OptionQuitIfOneScreen),
    CommandOption('R', 'RAW-CONTROL-CHARS', False, OptionIgnored),
    CommandOption('S', 'chop-long-lines', False, OptionIgnored),
    CommandOption('X', 'no-init', False, OptionIgnored)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionQuitIfOneScreen then
      QuitIfOneScreen := True;
  Paths := CommandLine.Operands;
  CommandLine.Free;
  if Length(Paths) = 0 then
    Paths := ['-'];

  KeyHandle := ChooseKeyHandle(Paths);
  if KeyHandle < 0 then
  begin
    for Path in Paths do
      if not CopyThrough(Path) then
        Status := 1;
    Halt(Status);
  end;

  Pager := TPager.Create(IsMore, KeyHandle);
  for Path in Paths do
    if not Pager.LoadInput(Path, Length(Paths) > 1) then
      Status := 1;
  FlushStandardStreams;
  if Pager.FitsOnScreen and (IsMore or QuitIfOneScreen) then
  begin
    Pager.PrintAllRows;
    Halt(Status);
  end;
  Pager.Page;
  Pager.Free;
  Halt(Status);
end.

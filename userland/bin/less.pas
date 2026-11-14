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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Console,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage: PChar = 'Usage: less [-FRSX] [FILE]...'#10 +
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

type
  TKey = (KeyNone, KeyQuit, KeyNextPage, KeyPreviousPage, KeyNextLine, KeyPreviousLine,
    KeyHalfDown, KeyHalfUp, KeyFirst, KeyLast, KeySearch, KeyNextMatch, KeyPreviousMatch, KeyRedraw);

var
  IsMore: Boolean;
  QuitIfOneScreen: Boolean;
  KeyHandle: Int64;
  ScreenRows: LongInt;
  ScreenColumns: LongInt;
  PageRows: Integer;

  { The text, cut into screen rows. }
  Rows: TLineList;
  Top: Integer;

  SearchPattern: PChar;
  SearchExpressionReady: Boolean;
  Search: TExpression;

{ --- Copying through ------------------------------------------------- }

function CopyThrough(Path: PChar): Boolean;
var
  Stream: PInputStream;
  Buffer: array[0..4095] of Char;
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

{ Expands tabs and cuts Line into rows of at most Width characters. }
procedure AddRows(Line: PChar; Width: Integer);
var
  Builder: TTextBuilder;
  Position: PChar;
  Column: Integer;
begin
  BeginText(Builder);
  Column := 0;
  Position := Line;
  while Position^ <> #0 do
  begin
    if Position^ = #9 then
    begin
      repeat
        AppendCharacter(Builder, ' ');
        Inc(Column);
      until (Column mod TabWidth = 0) or (Column >= Width);
    end
    else if Position^ = #13 then
      { Carriage returns would move the console cursor. }
    else if (Position^ < ' ') and (Position^ <> #0) then
    begin
      AppendCharacter(Builder, '^');
      Inc(Column);
      if Column >= Width then
      begin
        AddLine(Rows, FinishText(Builder));
        BeginText(Builder);
        Column := 0;
      end;
      AppendCharacter(Builder, Char(Ord(Position^) + 64));
      Inc(Column);
    end
    else
    begin
      AppendCharacter(Builder, Position^);
      Inc(Column);
    end;
    if Column >= Width then
    begin
      AddLine(Rows, FinishText(Builder));
      BeginText(Builder);
      Column := 0;
      if Position[1] = #0 then
      begin
        { The line filled its last row exactly. }
        DiscardText(Builder);
        Exit;
      end;
    end;
    Inc(Position);
  end;
  AddLine(Rows, FinishText(Builder));
end;

function LoadInput(Path: PChar; ShowHeader: Boolean; Width: Integer): Boolean;
var
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit(False);
  if ShowHeader then
  begin
    AddLine(Rows, DuplicateText('::::::::::::::'));
    AddRows(Path, Width);
    AddLine(Rows, DuplicateText('::::::::::::::'));
  end;
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    AddRows(Line, Width);
    FreeMemory(Line);
  end;
  CloseInput(Stream);
  Result := True;
end;

{ --- Drawing --------------------------------------------------------- }

function LastTop: Integer;
begin
  Result := Rows.Count - PageRows;
  if Result < 0 then
    Result := 0;
end;

procedure ClampTop;
begin
  if Top > LastTop then
    Top := LastTop;
  if Top < 0 then
    Top := 0;
end;

procedure ClearPrompt;
var
  Index: Integer;
begin
  WriteCharacter(StandardOutput, #13);
  for Index := 1 to ScreenColumns - 1 do
    WriteCharacter(StandardOutput, ' ');
  WriteCharacter(StandardOutput, #13);
end;

procedure DrawPrompt;
var
  Percent: Int64;
begin
  if IsMore then
  begin
    if Rows.Count = 0 then
      Percent := 100
    else
      Percent := (Int64(Top + PageRows) * 100) div Rows.Count;
    if Percent > 100 then
      Percent := 100;
    WriteFormatted(StandardOutput, '--More--(%d%%)', [ArgumentNumber(Percent)]);
  end
  else if Top >= LastTop then
    WriteText(StandardOutput, '(END)')
  else
    WriteCharacter(StandardOutput, ':');
  FlushStream(StandardOutput);
end;

procedure DrawPage;
var
  Index: Integer;
begin
  ClearPrompt;
  for Index := Top to Top + PageRows - 1 do
  begin
    if Index < Rows.Count then
      WriteText(StandardOutput, Rows.Items[Index])
    else if not IsMore then
      WriteCharacter(StandardOutput, '~');
    WriteCharacter(StandardOutput, #10);
  end;
  DrawPrompt;
end;

procedure ShowMessage(Message: PChar);
begin
  ClearPrompt;
  WriteText(StandardOutput, Message);
  WriteText(StandardOutput, '  (press a key)');
  FlushStream(StandardOutput);
end;

{ --- Keys ------------------------------------------------------------ }

function ReadKeyCharacter(out Character: Char): Boolean;
begin
  Result := KernelRead(KeyHandle, @Character, 1) = 1;
end;

function ReadKey: TKey;
var
  Character: Char;
  Parameter: Integer;
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
    KeyEscape:
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
          if IsDigit(Character) then
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
  else
    Result := KeyNone;
  end;
end;

{ Reads the search pattern after "/", echoing it. Returns False if it
  was abandoned (Escape, or erasing past the start). }
function ReadPattern(out Pattern: PChar): Boolean;
var
  Builder: TTextBuilder;
  Character: Char;
begin
  ClearPrompt;
  WriteCharacter(StandardOutput, '/');
  FlushStream(StandardOutput);
  BeginText(Builder);
  repeat
    if not ReadKeyCharacter(Character) then
      Character := KeyEscape;
    case Character of
      #10, #13:
        begin
          Pattern := FinishText(Builder);
          Exit(True);
        end;
      KeyEscape, KeyInterrupt:
        begin
          DiscardText(Builder);
          Exit(False);
        end;
      KeyBackspace, KeyDelete:
        begin
          if Builder.Length = 0 then
          begin
            DiscardText(Builder);
            Exit(False);
          end;
          Dec(Builder.Length);
          Builder.Text[Builder.Length] := #0;
          WriteText(StandardOutput, #8' '#8);
        end;
    else
      if Character >= ' ' then
      begin
        AppendCharacter(Builder, Character);
        WriteCharacter(StandardOutput, Character);
      end;
    end;
    FlushStream(StandardOutput);
  until False;
end;

function RowMatches(Index: Integer): Boolean;
var
  Match: TMatch;
begin
  Result := SearchExpression(Search, Rows.Items[Index], Match);
end;

{ Moves Top to the next (or previous) row that matches. }
procedure FindMatch(Forward: Boolean);
var
  Index: Integer;
begin
  if not SearchExpressionReady then
  begin
    ShowMessage('No previous regular expression');
    ReadKey;
    Exit;
  end;
  if Forward then
  begin
    Index := Top + 1;
    while Index < Rows.Count do
    begin
      if RowMatches(Index) then
      begin
        Top := Index;
        Exit;
      end;
      Inc(Index);
    end;
  end
  else
  begin
    Index := Top - 1;
    while Index >= 0 do
    begin
      if RowMatches(Index) then
      begin
        Top := Index;
        Exit;
      end;
      Dec(Index);
    end;
  end;
  ShowMessage('Pattern not found');
  ReadKey;
end;

procedure StartSearch;
var
  Pattern: PChar;
  ErrorMessage: PChar;
begin
  if not ReadPattern(Pattern) then
    Exit;
  if Pattern^ <> #0 then
  begin
    if SearchExpressionReady then
      FreeExpression(Search);
    SearchExpressionReady := CompileExpression(Pattern, SyntaxExtended, Search, ErrorMessage);
    if not SearchExpressionReady then
    begin
      ShowMessage(ErrorMessage);
      ReadKey;
      Exit;
    end;
    SearchPattern := Pattern;
  end;
  { The search starts on the first row shown. }
  Dec(Top);
  FindMatch(True);
  if (Top < 0) or not RowMatches(Top) then
    Inc(Top);
end;

procedure Page;
var
  Key: TKey;
  SavedMode: Int64;
begin
  SavedMode := GetConsoleMode(KeyHandle);
  { One key at a time, without echo; Ctrl-C still interrupts. }
  SetConsoleMode(KeyHandle, ConsoleModeInterruptKey);
  Top := 0;
  repeat
    ClampTop;
    DrawPage;
    if IsMore and (Top >= LastTop) then
      Break;
    Key := ReadKey;
    case Key of
      KeyQuit: Break;
      KeyNextPage:
        begin
          if IsMore or (Top < LastTop) then
            Top := Top + PageRows;
        end;
      KeyPreviousPage: Top := Top - PageRows;
      KeyNextLine: Inc(Top);
      KeyPreviousLine: Dec(Top);
      KeyHalfDown: Top := Top + PageRows div 2;
      KeyHalfUp: Top := Top - PageRows div 2;
      KeyFirst: Top := 0;
      KeyLast: Top := LastTop;
      KeySearch: StartSearch;
      KeyNextMatch: FindMatch(True);
      KeyPreviousMatch: FindMatch(False);
    end;
  until False;
  ClearPrompt;
  FlushStream(StandardOutput);
  if SavedMode >= 0 then
    SetConsoleMode(KeyHandle, LongWord(SavedMode));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Status: LongInt;
  Standard: PChar;
begin
  IsMore := TextIsEqual(BaseName(Argument(0)), 'more');
  Status := 0;
  BeginOptions(Parser, [
    OptionDefinition('F', 'quit-if-one-screen', False, OptionQuitIfOneScreen),
    OptionDefinition('R', 'RAW-CONTROL-CHARS', False, OptionIgnored),
    OptionDefinition('S', 'chop-long-lines', False, OptionIgnored),
    OptionDefinition('X', 'no-init', False, OptionIgnored)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionQuitIfOneScreen then
      QuitIfOneScreen := True;
  if Parser.OperandCount = 0 then
  begin
    Standard := '-';
    Parser.Operands[0] := Standard;
    Parser.OperandCount := 1;
  end;

  if IsConsole(StandardInputHandle) and IsConsole(StandardOutputHandle) then
    KeyHandle := StandardInputHandle
  else if IsConsole(StandardErrorHandle) and IsConsole(StandardOutputHandle) then
    KeyHandle := StandardErrorHandle
  else
    KeyHandle := -1;
  { Reading the text from the console that also gives the keys makes no
    sense; behave like cat then. }
  if (KeyHandle = StandardInputHandle) then
    for Index := 0 to Parser.OperandCount - 1 do
      if TextIsEqual(Parser.Operands[Index], '-') then
        KeyHandle := -1;

  if KeyHandle < 0 then
  begin
    for Index := 0 to Parser.OperandCount - 1 do
      if not CopyThrough(Parser.Operands[Index]) then
        Status := 1;
    Halt(Status);
  end;

  GetConsoleSize(StandardOutputHandle, ScreenRows, ScreenColumns);
  if ScreenRows < 2 then
    ScreenRows := 2;
  if ScreenColumns < 10 then
    ScreenColumns := 10;
  PageRows := ScreenRows - 1;
  BeginLineList(Rows);
  for Index := 0 to Parser.OperandCount - 1 do
    if not LoadInput(Parser.Operands[Index], Parser.OperandCount > 1, ScreenColumns - 1) then
      Status := 1;
  FlushStandardStreams;
  if (Rows.Count <= PageRows) and (IsMore or QuitIfOneScreen) then
  begin
    for Index := 0 to Rows.Count - 1 do
      WriteLine(StandardOutput, Rows.Items[Index]);
    Halt(Status);
  end;
  Page;
  Halt(Status);
end.

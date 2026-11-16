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
  Reading a line with editing and history, for interactive programs.

  On the console the editor switches the console to character-at-a-time
  input without echo (Ctrl-C still reaches the console's interrupt
  handling) and draws the line itself. Keys:

    Left, Right, Ctrl-B, Ctrl-F     move the cursor
    Home, End, Ctrl-A, Ctrl-E       to the start or end of the line
    Backspace, Delete               remove a character
    Ctrl-K, Ctrl-U, Ctrl-W          remove to the end, to the start, a word
    Up, Down, Ctrl-P, Ctrl-N        walk through the history
    Tab                             complete a file or command name
    Ctrl-L                          draw the line again
    Ctrl-C                          throw the line away
    Ctrl-D                          end of input on an empty line

  Redrawing only uses carriage return, backspace, spaces and the
  characters themselves, so it works on the framebuffer console and on
  serial terminals alike. A line longer than the screen is scrolled
  sideways (as ksh does): the prompt and a window of the text always fit
  on one row, so the terminal never wraps. The width is the console's,
  or $COLUMNS when set (a serial terminal can be narrower).

  When standard input is not the console, EditLine just prints the prompt
  and reads a line.

  A program can give the editor a handle to wake it while it waits for
  a key (WakeHandle: the shell's notifications): once that handle is
  ready, EditLine gives up the line and returns EditWoken.
}
unit Util.LineEditor;

{$mode objfpc}
{$pointermath on}

interface

uses
  Util.Input;

type
  TLineEditor = record
    History: TLineList;
    HistoryLimit: Integer;
    HistoryPath: PChar;
    OutputHandle: Int64;
    IsConsole: Boolean;
    { Waited for along with the keys (NoHandle: none). }
    WakeHandle: Int64;
  end;

  TEditResult = (EditLineReady, EditEndOfInput, EditWoken);

{ HistoryPath may be nil (no history file). Output (prompt and echo)
  goes to OutputHandle. }
procedure BeginLineEditor(out Editor: TLineEditor; HistoryPath: PChar; OutputHandle: Int64);
{ Reads a line (without its line end) into a new heap string. }
function EditLine(var Editor: TLineEditor; Prompt: PChar; out Line: PChar): TEditResult;
{ Adds Line to the history (empty lines and repeats are skipped). }
procedure AddHistoryLine(var Editor: TLineEditor; Line: PChar);
{ Rewrites the history file with at most HistoryLimit lines (lines are
  appended to it as they are added). }
procedure SaveHistory(var Editor: TLineEditor);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Console,
  Sys.Environment,
  Sys.Files,
  Sys.Kernel,
  Sys.Memory,
  Sys.Objects,
  Sys.Streams,
  Sys.Text,
  Util.Directories,
  Util.Paths,
  Util.Sorting;

const
  DefaultHistoryLimit = 500;
  OutputCapacity = 1024;
  { The text window is never narrower than this, even after a long
    prompt (the terminal then wraps, but editing still works). }
  MinimumWindowWidth = 8;

  KeyControlA = #1;
  KeyControlB = #2;
  KeyInterrupt = #3;
  KeyControlD = #4;
  KeyControlE = #5;
  KeyControlF = #6;
  KeyBackspace = #8;
  KeyTab = #9;
  KeyLineFeed = #10;
  KeyControlK = #11;
  KeyControlL = #12;
  KeyReturn = #13;
  KeyControlN = #14;
  KeyControlP = #16;
  KeyControlU = #21;
  KeyControlW = #23;
  KeyEscape = #27;
  KeyDelete = #127;

type
  { The line being edited and what the terminal shows of it. }
  TEditState = record
    Editor: ^TLineEditor;
    Prompt: PChar;
    Text: TTextBuilder;
    Cursor: PtrUInt;
    { Where the terminal cursor is, within the text. }
    ShownCursor: PtrUInt;
    { Where the shown part of the text ends (for clearing leftovers). }
    ShownLength: PtrUInt;
    { The first character of the text that is shown, and how many
      characters fit after the prompt. }
    WindowStart: PtrUInt;
    WindowWidth: PtrUInt;
    { The prompt's last line, redrawn after a carriage return. }
    PromptTail: PChar;
    HistoryIndex: Integer;
    { The line being typed, kept while walking through the history. }
    Scratch: PChar;
    Output: array[0..OutputCapacity - 1] of Char;
    OutputCount: Integer;
  end;

{ --- Output ---------------------------------------------------------- }

procedure FlushOutput(var State: TEditState);
begin
  if State.OutputCount > 0 then
    KernelWrite(State.Editor^.OutputHandle, @State.Output[0], QWord(State.OutputCount));
  State.OutputCount := 0;
end;

procedure Emit(var State: TEditState; Character: Char);
begin
  if State.OutputCount = OutputCapacity then
    FlushOutput(State);
  State.Output[State.OutputCount] := Character;
  Inc(State.OutputCount);
end;

procedure EmitText(var State: TEditState; Text: PChar);
begin
  while Text^ <> #0 do
  begin
    Emit(State, Text^);
    Inc(Text);
  end;
end;

{ The end of the shown part of the text. }
function WindowEnd(var State: TEditState): PtrUInt;
begin
  Result := State.WindowStart + State.WindowWidth;
  if Result > State.Text.Length then
    Result := State.Text.Length;
end;

function CursorIsInWindow(var State: TEditState; Target: PtrUInt): Boolean;
begin
  Result := (Target >= State.WindowStart) and (Target <= State.WindowStart + State.WindowWidth);
end;

{ Moves the window so that the cursor is in it, keeping some text
  visible on the side it moved towards. }
procedure PlaceWindow(var State: TEditState);
begin
  if State.Cursor < State.WindowStart then
  begin
    if State.Cursor > State.WindowWidth div 3 then
      State.WindowStart := State.Cursor - State.WindowWidth div 3
    else
      State.WindowStart := 0;
  end
  else if State.Cursor > State.WindowStart + State.WindowWidth then
    State.WindowStart := State.Cursor - (State.WindowWidth * 2) div 3;
end;

{ Writes the shown text from the terminal cursor to the window end,
  blanks what is left of a longer older line, and goes back to the
  window end. }
procedure DrawToWindowEnd(var State: TEditState);
var
  Finish: PtrUInt;
  Extra: PtrUInt;
begin
  Finish := WindowEnd(State);
  while State.ShownCursor < Finish do
  begin
    Emit(State, State.Text.Text[State.ShownCursor]);
    Inc(State.ShownCursor);
  end;
  Extra := 0;
  while State.ShownLength > Finish + Extra do
  begin
    Emit(State, ' ');
    Inc(Extra);
  end;
  while Extra > 0 do
  begin
    Emit(State, KeyBackspace);
    Dec(Extra);
  end;
  State.ShownLength := Finish;
end;

{ Moves the terminal cursor to text position Target, which must be in
  the window. }
procedure StepShownCursor(var State: TEditState; Target: PtrUInt);
begin
  while State.ShownCursor > Target do
  begin
    Emit(State, KeyBackspace);
    Dec(State.ShownCursor);
  end;
  while State.ShownCursor < Target do
  begin
    Emit(State, State.Text.Text[State.ShownCursor]);
    Inc(State.ShownCursor);
  end;
end;

{ Draws the row again from its start: prompt, then the window. }
procedure RedrawRow(var State: TEditState);
var
  OldShownEnd: PtrUInt;
  OldWidth: PtrUInt;
begin
  { What the row showed, measured from the window start, decides how
    much has to be blanked. }
  OldWidth := 0;
  if State.ShownLength > State.WindowStart then
    OldWidth := State.ShownLength - State.WindowStart;
  PlaceWindow(State);
  Emit(State, KeyReturn);
  EmitText(State, State.PromptTail);
  State.ShownCursor := State.WindowStart;
  OldShownEnd := State.WindowStart + OldWidth;
  if OldShownEnd < State.WindowStart + State.WindowWidth then
    State.ShownLength := OldShownEnd
  else
    State.ShownLength := State.WindowStart + State.WindowWidth;
  DrawToWindowEnd(State);
  StepShownCursor(State, State.Cursor);
end;

{ Moves the terminal cursor to text position Target, scrolling the
  window if needed. }
procedure MoveShownCursor(var State: TEditState; Target: PtrUInt);
var
  SavedCursor: PtrUInt;
begin
  if CursorIsInWindow(State, Target) then
    StepShownCursor(State, Target)
  else
  begin
    SavedCursor := State.Cursor;
    State.Cursor := Target;
    RedrawRow(State);
    State.Cursor := SavedCursor;
  end;
end;

{ Redraws the text from position From on, clears what is left of an
  older, longer line, and puts the terminal cursor at the cursor. }
procedure RedrawFrom(var State: TEditState; From: PtrUInt);
begin
  if not CursorIsInWindow(State, State.Cursor) or (From < State.WindowStart) then
  begin
    RedrawRow(State);
    Exit;
  end;
  if State.ShownCursor > From then
    StepShownCursor(State, From);
  if State.ShownCursor < From then
    StepShownCursor(State, From);
  DrawToWindowEnd(State);
  StepShownCursor(State, State.Cursor);
end;

procedure DrawPromptAndLine(var State: TEditState);
begin
  EmitText(State, State.Prompt);
  State.WindowStart := 0;
  State.ShownCursor := 0;
  State.ShownLength := 0;
  PlaceWindow(State);
  if State.WindowStart > 0 then
    RedrawRow(State)
  else
    RedrawFrom(State, 0);
end;

{ How wide the text window is: the screen width less the prompt's last
  line, keeping the last column free. }
procedure MeasureWindow(var State: TEditState);
var
  Rows: LongInt;
  Columns: LongInt;
  ColumnsText: PChar;
  Number: Int64;
  LastLineEnd: PtrInt;
  PromptWidth: PtrUInt;
begin
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  ColumnsText := GetVariable('COLUMNS');
  if (ColumnsText <> nil) and ParseInteger(ColumnsText, Number) and (Number >= 2 * MinimumWindowWidth) and
     (Number <= 1000) then
    Columns := LongInt(Number);
  LastLineEnd := FindLastCharacter(State.Prompt, KeyLineFeed);
  State.PromptTail := State.Prompt + LastLineEnd + 1;
  PromptWidth := TextLength(State.PromptTail);
  if PtrUInt(Columns) > PromptWidth + 1 + MinimumWindowWidth then
    State.WindowWidth := PtrUInt(Columns) - PromptWidth - 1
  else
    State.WindowWidth := MinimumWindowWidth;
end;

{ --- Editing --------------------------------------------------------- }

procedure ReplaceText(var State: TEditState; NewText: PChar);
begin
  State.Text.Length := 0;
  State.Text.Text[0] := #0;
  AppendText(State.Text, NewText);
  State.Cursor := State.Text.Length;
  RedrawFrom(State, 0);
end;

procedure InsertCharacters(var State: TEditState; Characters: PChar; Count: PtrUInt);
var
  Tail: PChar;
  From: PtrUInt;
begin
  if Count = 0 then
    Exit;
  Tail := DuplicateText(State.Text.Text + State.Cursor);
  State.Text.Length := State.Cursor;
  State.Text.Text[State.Cursor] := #0;
  AppendBytes(State.Text, Characters, Count);
  AppendText(State.Text, Tail);
  FreeMemory(Tail);
  From := State.Cursor;
  State.Cursor := State.Cursor + Count;
  RedrawFrom(State, From);
end;

{ Removes Count characters starting at First. }
procedure DeleteRange(var State: TEditState; First, Count: PtrUInt);
begin
  if (Count = 0) or (First >= State.Text.Length) then
    Exit;
  if First + Count > State.Text.Length then
    Count := State.Text.Length - First;
  MoveMemory(State.Text.Text + First, State.Text.Text + First + Count, State.Text.Length - First - Count + 1);
  State.Text.Length := State.Text.Length - Count;
  if State.Cursor > First + Count then
    State.Cursor := State.Cursor - Count
  else if State.Cursor > First then
    State.Cursor := First;
  RedrawFrom(State, First);
end;

procedure DeleteWordBeforeCursor(var State: TEditState);
var
  Start: PtrUInt;
begin
  Start := State.Cursor;
  while (Start > 0) and (State.Text.Text[Start - 1] = ' ') do
    Dec(Start);
  while (Start > 0) and (State.Text.Text[Start - 1] <> ' ') do
    Dec(Start);
  DeleteRange(State, Start, State.Cursor - Start);
end;

procedure ShowHistoryEntry(var State: TEditState; NewIndex: Integer);
var
  History: ^TLineList;
begin
  History := @State.Editor^.History;
  if (NewIndex < 0) or (NewIndex > History^.Count) or (NewIndex = State.HistoryIndex) then
    Exit;
  if State.HistoryIndex = History^.Count then
  begin
    FreeMemory(State.Scratch);
    State.Scratch := DuplicateText(State.Text.Text);
  end;
  State.HistoryIndex := NewIndex;
  if NewIndex = History^.Count then
    ReplaceText(State, State.Scratch)
  else
    ReplaceText(State, History^.Items[NewIndex]);
end;

{ --- Completion ------------------------------------------------------ }

function CompareNames(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := CompareText(PChar(First), PChar(Second));
end;

{ Adds the names in Directory starting with Prefix to Matches. }
procedure CollectMatches(Directory, Prefix: PChar; var Matches: TLineList; OnlyFiles: Boolean);
var
  Names: TLineList;
  Index: Integer;
  Path: PChar;
  Information: TFileInformation;
begin
  BeginLineList(Names);
  if ListDirectory(Directory, Names) <> ErrorNone then
  begin
    FreeLineList(Names);
    Exit;
  end;
  for Index := 0 to Names.Count - 1 do
  begin
    if not TextStartsWith(Names.Items[Index], Prefix) then
      Continue;
    { Hidden names only when asked for. }
    if (Names.Items[Index][0] = '.') and (Prefix^ <> '.') then
      Continue;
    if OnlyFiles then
    begin
      Path := JoinPath(Directory, Names.Items[Index]);
      if (GetFileInformation(Path, Information) <> ErrorNone) or (Information.Kind <> KindFile) then
      begin
        FreeMemory(Path);
        Continue;
      end;
      FreeMemory(Path);
    end;
    AddLine(Matches, DuplicateText(Names.Items[Index]));
  end;
  FreeLineList(Names);
end;

{ True if the word at Position starts a command: nothing but blanks
  before it, or a separator such as |, ;, & or (. }
function IsCommandPosition(Text: PChar; Position: PtrUInt): Boolean;
begin
  while (Position > 0) and (Text[Position - 1] = ' ') do
    Dec(Position);
  Result := (Position = 0) or (Text[Position - 1] in ['|', ';', '&', '(']);
end;

procedure CompleteWord(var State: TEditState);
var
  WordStart: PtrUInt;
  Word: PChar;
  Length: PtrUInt;
  IsCommand: Boolean;
  LastSlash: PtrInt;
  Directory: PChar;
  Prefix: PChar;
  Matches: TLineList;
  SearchPath: PChar;
  PathCopy: PChar;
  Start: PChar;
  Separator: PtrInt;
  Common: PtrUInt;
  Index: Integer;
  Candidate: PChar;
  Information: TFileInformation;
  Completed: TTextBuilder;
begin
  WordStart := State.Cursor;
  while (WordStart > 0) and (State.Text.Text[WordStart - 1] <> ' ') do
    Dec(WordStart);
  Length := State.Cursor - WordStart;
  Word := PChar(AllocateMemory(Length + 1));
  CopyMemory(Word, State.Text.Text + WordStart, Length);
  Word[Length] := #0;
  { A word in command position is a command, unless it names a path. }
  IsCommand := (FindCharacter(Word, '/') < 0) and IsCommandPosition(State.Text.Text, WordStart);

  BeginLineList(Matches);
  LastSlash := FindLastCharacter(Word, '/');
  if IsCommand then
  begin
    SearchPath := GetVariable('PATH');
    if SearchPath = nil then
      SearchPath := '/bin';
    PathCopy := DuplicateText(SearchPath);
    Start := PathCopy;
    repeat
      Separator := FindCharacter(Start, ':');
      if Separator >= 0 then
        Start[Separator] := #0;
      if Start^ <> #0 then
        CollectMatches(Start, Word, Matches, True);
      if Separator >= 0 then
        Start := Start + Separator + 1;
    until Separator < 0;
    FreeMemory(PathCopy);
    Prefix := Word;
    Directory := nil;
  end
  else
  begin
    if LastSlash >= 0 then
    begin
      Directory := PChar(AllocateMemory(LastSlash + 2));
      CopyText(Directory, Word, PtrUInt(LastSlash) + 2);
      if LastSlash = 0 then
        Directory[1] := #0
      else
        Directory[LastSlash] := #0;
      Prefix := Word + LastSlash + 1;
    end
    else
    begin
      Directory := DuplicateText('.');
      Prefix := Word;
    end;
    CollectMatches(Directory, Prefix, Matches, False);
  end;
  SortPointers(PPointer(Matches.Items), Matches.Count, @CompareNames, nil);

  if Matches.Count > 0 then
  begin
    { The longest prefix all matches share. }
    Common := TextLength(Matches.Items[0]);
    for Index := 1 to Matches.Count - 1 do
    begin
      Candidate := Matches.Items[Index];
      Length := 0;
      while (Length < Common) and (Candidate[Length] = Matches.Items[0][Length]) do
        Inc(Length);
      Common := Length;
    end;
    Length := TextLength(Prefix);
    if Common > Length then
      InsertCharacters(State, Matches.Items[0] + Length, Common - Length)
    else if Matches.Count = 1 then
    begin
      { Complete: a slash after a directory, a space after anything else. }
      BeginText(Completed);
      if Directory <> nil then
      begin
        AppendText(Completed, Directory);
        AppendCharacter(Completed, '/');
      end;
      AppendText(Completed, Matches.Items[0]);
      if not IsCommand and (GetFileInformation(Completed.Text, Information) = ErrorNone) and
         (Information.Kind = KindDirectory) then
        InsertCharacters(State, '/', 1)
      else
        InsertCharacters(State, ' ', 1);
      DiscardText(Completed);
    end
    else
    begin
      { Several matches and nothing to add: list them. }
      MoveShownCursor(State, State.Text.Length);
      Emit(State, KeyLineFeed);
      for Index := 0 to Matches.Count - 1 do
      begin
        if Index > 0 then
          EmitText(State, '  ');
        EmitText(State, Matches.Items[Index]);
      end;
      Emit(State, KeyLineFeed);
      DrawPromptAndLine(State);
    end;
    if (Matches.Count = 1) and (Common > TextLength(Prefix)) then
      CompleteWord(State);
  end;
  FreeLineList(Matches);
  FreeMemory(Directory);
  FreeMemory(Word);
end;

{ --- Reading keys ---------------------------------------------------- }

function ReadKey(out Character: Char): Boolean;
begin
  Result := KernelRead(StandardInputHandle, @Character, 1) = 1;
end;

{ Waits for a key, or for the wake handle: False if the wake handle came
  first. }
function WaitForKeyOrWake(var Editor: TLineEditor): Boolean;
begin
  if Editor.WakeHandle = NoHandle then
    Exit(True);
  Result := WaitForHandles([StandardInputHandle, Editor.WakeHandle], InfiniteWait) <> 1;
end;

{ Handles the rest of an escape sequence (after ESC). }
procedure HandleEscapeSequence(var State: TEditState);
var
  Character: Char;
  Parameter: Integer;
begin
  if not ReadKey(Character) then
    Exit;
  if (Character <> '[') and (Character <> 'O') then
    Exit;
  Parameter := 0;
  repeat
    if not ReadKey(Character) then
      Exit;
    if IsDigit(Character) then
      Parameter := Parameter * 10 + Ord(Character) - Ord('0');
  until (Character >= '@') and (Character <= '~');
  case Character of
    'A': ShowHistoryEntry(State, State.HistoryIndex - 1);
    'B': ShowHistoryEntry(State, State.HistoryIndex + 1);
    'C':
      if State.Cursor < State.Text.Length then
      begin
        Inc(State.Cursor);
        MoveShownCursor(State, State.Cursor);
      end;
    'D':
      if State.Cursor > 0 then
      begin
        Dec(State.Cursor);
        MoveShownCursor(State, State.Cursor);
      end;
    'H':
      begin
        State.Cursor := 0;
        MoveShownCursor(State, 0);
      end;
    'F':
      begin
        State.Cursor := State.Text.Length;
        MoveShownCursor(State, State.Cursor);
      end;
    '~':
      case Parameter of
        1, 7:
          begin
            State.Cursor := 0;
            MoveShownCursor(State, 0);
          end;
        4, 8:
          begin
            State.Cursor := State.Text.Length;
            MoveShownCursor(State, State.Cursor);
          end;
        3: DeleteRange(State, State.Cursor, 1);
      end;
  end;
end;

function EditOnConsole(var Editor: TLineEditor; Prompt: PChar; out Line: PChar): TEditResult;
var
  State: TEditState;
  Character: Char;
  Done: Boolean;
begin
  ZeroMemory(@State, SizeOf(State));
  State.Editor := @Editor;
  State.Prompt := Prompt;
  BeginText(State.Text);
  State.HistoryIndex := Editor.History.Count;
  State.Scratch := DuplicateText('');
  MeasureWindow(State);
  DrawPromptAndLine(State);
  FlushOutput(State);

  Result := EditLineReady;
  Done := False;
  while not Done do
  begin
    if not WaitForKeyOrWake(Editor) then
    begin
      MoveShownCursor(State, State.Text.Length);
      Emit(State, KeyLineFeed);
      Result := EditWoken;
      Break;
    end;
    if not ReadKey(Character) then
    begin
      Result := EditEndOfInput;
      Break;
    end;
    case Character of
      KeyReturn, KeyLineFeed:
        begin
          MoveShownCursor(State, State.Text.Length);
          Emit(State, KeyLineFeed);
          Done := True;
        end;
      KeyInterrupt:
        begin
          MoveShownCursor(State, State.Text.Length);
          EmitText(State, '^C'#10);
          State.Text.Length := 0;
          State.Text.Text[0] := #0;
          State.Cursor := 0;
          State.HistoryIndex := Editor.History.Count;
          DrawPromptAndLine(State);
        end;
      KeyControlD:
        if State.Text.Length = 0 then
        begin
          Emit(State, KeyLineFeed);
          Result := EditEndOfInput;
          Done := True;
        end
        else
          DeleteRange(State, State.Cursor, 1);
      KeyBackspace, KeyDelete:
        if State.Cursor > 0 then
          DeleteRange(State, State.Cursor - 1, 1);
      KeyControlA:
        begin
          State.Cursor := 0;
          MoveShownCursor(State, 0);
        end;
      KeyControlE:
        begin
          State.Cursor := State.Text.Length;
          MoveShownCursor(State, State.Cursor);
        end;
      KeyControlB:
        if State.Cursor > 0 then
        begin
          Dec(State.Cursor);
          MoveShownCursor(State, State.Cursor);
        end;
      KeyControlF:
        if State.Cursor < State.Text.Length then
        begin
          Inc(State.Cursor);
          MoveShownCursor(State, State.Cursor);
        end;
      KeyControlK: DeleteRange(State, State.Cursor, State.Text.Length - State.Cursor);
      KeyControlU: DeleteRange(State, 0, State.Cursor);
      KeyControlW: DeleteWordBeforeCursor(State);
      KeyControlP: ShowHistoryEntry(State, State.HistoryIndex - 1);
      KeyControlN: ShowHistoryEntry(State, State.HistoryIndex + 1);
      KeyControlL:
        begin
          Emit(State, KeyLineFeed);
          DrawPromptAndLine(State);
        end;
      KeyTab: CompleteWord(State);
      KeyEscape: HandleEscapeSequence(State);
    else
      if Character >= ' ' then
        InsertCharacters(State, @Character, 1);
    end;
    FlushOutput(State);
  end;
  FlushOutput(State);
  FreeMemory(State.Scratch);
  if Result <> EditLineReady then
  begin
    DiscardText(State.Text);
    Line := nil;
  end
  else
    Line := FinishText(State.Text);
end;

{ --- The public interface -------------------------------------------- }

procedure LoadHistory(var Editor: TLineEditor);
var
  Stream: PInputStream;
begin
  if (Editor.HistoryPath = nil) or not PathExists(Editor.HistoryPath) then
    Exit;
  Stream := OpenInput(Editor.HistoryPath);
  if Stream = nil then
    Exit;
  ReadAllLines(Stream, Editor.History);
  CloseInput(Stream);
end;

procedure BeginLineEditor(out Editor: TLineEditor; HistoryPath: PChar; OutputHandle: Int64);
begin
  BeginLineList(Editor.History);
  Editor.HistoryLimit := DefaultHistoryLimit;
  Editor.HistoryPath := nil;
  if HistoryPath <> nil then
    Editor.HistoryPath := DuplicateText(HistoryPath);
  Editor.OutputHandle := OutputHandle;
  Editor.IsConsole := IsConsole(StandardInputHandle);
  Editor.WakeHandle := NoHandle;
  LoadHistory(Editor);
end;

function EditLine(var Editor: TLineEditor; Prompt: PChar; out Line: PChar): TEditResult;
var
  SavedMode: Int64;
  HadLineEnd: Boolean;
begin
  if not Editor.IsConsole then
  begin
    KernelWrite(Editor.OutputHandle, Prompt, TextLength(Prompt));
    if ReadLine(StandardInput, Line, HadLineEnd) then
      Result := EditLineReady
    else
      Result := EditEndOfInput;
    Exit;
  end;
  FlushStandardStreams;
  SavedMode := GetConsoleMode(StandardInputHandle);
  { Characters one at a time, no echo; Ctrl-C keeps working. }
  SetConsoleMode(StandardInputHandle, ConsoleModeInterruptKey);
  Result := EditOnConsole(Editor, Prompt, Line);
  if SavedMode >= 0 then
    SetConsoleMode(StandardInputHandle, LongWord(SavedMode));
end;

{ Each line goes to the file at once, so it survives a crash and other
  shells started meanwhile see it. }
procedure AppendToHistoryFile(var Editor: TLineEditor; Line: PChar);
var
  Handle: Int64;
  Newline: Char;
begin
  if Editor.HistoryPath = nil then
    Exit;
  Handle := OpenFile(Editor.HistoryPath, OpenWrite or OpenCreate or OpenAppend);
  if Handle < 0 then
    Exit;
  Newline := #10;
  WriteAll(Handle, Line, TextLength(Line));
  WriteAll(Handle, @Newline, 1);
  CloseFile(Handle);
end;

procedure AddHistoryLine(var Editor: TLineEditor; Line: PChar);
var
  Index: Integer;
begin
  if (Line = nil) or (Line^ = #0) then
    Exit;
  if (Editor.History.Count > 0) and TextIsEqual(Editor.History.Items[Editor.History.Count - 1], Line) then
    Exit;
  AppendToHistoryFile(Editor, Line);
  AddLine(Editor.History, DuplicateText(Line));
  if Editor.History.Count > Editor.HistoryLimit then
  begin
    FreeMemory(Editor.History.Items[0]);
    for Index := 1 to Editor.History.Count - 1 do
      Editor.History.Items[Index - 1] := Editor.History.Items[Index];
    Dec(Editor.History.Count);
  end;
end;

procedure SaveHistory(var Editor: TLineEditor);
var
  Handle: Int64;
  Stream: POutputStream;
  Index: Integer;
  FileLines: TLineList;
  Input: PInputStream;
begin
  if Editor.HistoryPath = nil then
    Exit;
  { Other shells may have added lines; keep the newest of the file. }
  BeginLineList(FileLines);
  if PathExists(Editor.HistoryPath) then
  begin
    Input := OpenInput(Editor.HistoryPath);
    if Input <> nil then
    begin
      ReadAllLines(Input, FileLines);
      CloseInput(Input);
    end;
  end;
  if FileLines.Count <= Editor.HistoryLimit then
  begin
    FreeLineList(FileLines);
    Exit;
  end;
  FreeLineList(Editor.History);
  BeginLineList(Editor.History);
  for Index := FileLines.Count - Editor.HistoryLimit to FileLines.Count - 1 do
    AddLine(Editor.History, DuplicateText(FileLines.Items[Index]));
  FreeLineList(FileLines);
  Handle := OpenFile(Editor.HistoryPath, OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit;
  Stream := CreateOutputStream(Handle);
  for Index := 0 to Editor.History.Count - 1 do
    WriteLine(Stream, Editor.History.Items[Index]);
  DestroyOutputStream(Stream);
  CloseFile(Handle);
end;

end.

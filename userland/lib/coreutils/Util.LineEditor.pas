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

  Redrawing only uses backspace, spaces and the characters themselves,
  so it works on the framebuffer console and on serial terminals alike.

  When standard input is not the console, EditLine just prints the prompt
  and reads a line.
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
  end;

  TEditResult = (EditLineReady, EditEndOfInput);

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
  Sys.Streams,
  Sys.Text,
  Util.Directories,
  Util.Paths,
  Util.Sorting;

const
  DefaultHistoryLimit = 500;
  OutputCapacity = 1024;

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
    { How much of the text the terminal shows (for clearing leftovers). }
    ShownLength: PtrUInt;
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

{ Moves the terminal cursor to text position Target. }
procedure MoveShownCursor(var State: TEditState; Target: PtrUInt);
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

{ Redraws the text from position From on, clears what is left of an
  older, longer line, and puts the terminal cursor at the cursor. }
procedure RedrawFrom(var State: TEditState; From: PtrUInt);
var
  Index: PtrUInt;
  Extra: PtrUInt;
begin
  if From > State.ShownCursor then
    MoveShownCursor(State, From)
  else
    while State.ShownCursor > From do
    begin
      Emit(State, KeyBackspace);
      Dec(State.ShownCursor);
    end;
  Index := From;
  while Index < State.Text.Length do
  begin
    Emit(State, State.Text.Text[Index]);
    Inc(Index);
  end;
  Extra := 0;
  while State.ShownLength > State.Text.Length + Extra do
  begin
    Emit(State, ' ');
    Inc(Extra);
  end;
  while Extra > 0 do
  begin
    Emit(State, KeyBackspace);
    Dec(Extra);
  end;
  State.ShownCursor := State.Text.Length;
  State.ShownLength := State.Text.Length;
  MoveShownCursor(State, State.Cursor);
end;

procedure DrawPromptAndLine(var State: TEditState);
begin
  EmitText(State, State.Prompt);
  State.ShownCursor := 0;
  State.ShownLength := 0;
  RedrawFrom(State, 0);
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
  DrawPromptAndLine(State);
  FlushOutput(State);

  Result := EditLineReady;
  Done := False;
  while not Done do
  begin
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
  if Result = EditEndOfInput then
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

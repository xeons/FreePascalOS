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
  One line being edited on the console (Util.LineEditor has the keys and
  the rest): the text, the cursor, and what the terminal shows of them.

  Positions in the text count characters from 0: the cursor at 0 is
  before the first one. The terminal shows the prompt's last line and a
  window of the text, WindowWidth characters from WindowStart, so the
  row never wraps.
}
unit Util.LineEditing;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TLineEditSession = class
  private
    FHistory: TStrings;
    FOutputHandle: Int64;
    FPrompt: string;
    FText: string;
    FCursor: Integer;
    { Where the terminal cursor is, within the text. }
    FShownCursor: Integer;
    { Where the shown part of the text ends (for clearing leftovers). }
    FShownLength: Integer;
    { The first character of the text that is shown, and how many
      characters fit after the prompt. }
    FWindowStart: Integer;
    FWindowWidth: Integer;
    { The prompt's last line, redrawn after a carriage return. }
    FPromptTail: string;
    FHistoryIndex: Integer;
    { The line being typed, kept while walking through the history. }
    FScratch: string;
    FOutput: string;
    procedure Emit(Character: Char);
    procedure EmitText(const Text: string);
    function WindowEnd: Integer;
    function CursorIsInWindow(Target: Integer): Boolean;
    procedure PlaceWindow;
    procedure DrawToWindowEnd;
    procedure StepShownCursor(Target: Integer);
    procedure RedrawRow;
    procedure RedrawFrom(From: Integer);
    procedure MeasureWindow;
    procedure ReplaceText(const NewText: string);
    procedure ListMatches(const Matches: array of string);
  public
    constructor Create(History: TStrings; OutputHandle: Int64; const Prompt: string);
    { Writes what has been drawn so far. }
    procedure FlushOutput;
    procedure DrawPromptAndLine;
    { Moves the terminal cursor to text position Target, scrolling the
      window if needed. }
    procedure MoveShownCursor(Target: Integer);
    procedure MoveCursor(Target: Integer);
    procedure InsertText(const Characters: string);
    { Removes Count characters starting at First. }
    procedure DeleteRange(First, Count: Integer);
    procedure DeleteWordBeforeCursor;
    procedure ShowHistoryEntry(NewIndex: Integer);
    procedure CompleteWord;
    { Ctrl-C: the line is thrown away and a fresh one begins. }
    procedure ThrowLineAway;
    { Ends the row where the terminal cursor is. }
    procedure StartNewRow;
    { The cursor goes past the text and the row ends (the line is done). }
    procedure FinishRow;
    property Text: string read FText;
    property Cursor: Integer read FCursor;
    property HistoryIndex: Integer read FHistoryIndex;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.Kernel,
  Util.LineCompletion,
  Util.Numbers;

const
  { The text window is never narrower than this, even after a long
    prompt (the terminal then wraps, but editing still works). }
  MinimumWindowWidth = 8;
  OutputCapacity = 1024;
  KeyBackspace = #8;
  KeyLineFeed = #10;
  KeyReturn = #13;

constructor TLineEditSession.Create(History: TStrings; OutputHandle: Int64; const Prompt: string);
begin
  inherited Create;
  FHistory := History;
  FOutputHandle := OutputHandle;
  FPrompt := Prompt;
  FHistoryIndex := History.Count;
  MeasureWindow;
end;

{ --- Output ---------------------------------------------------------- }

procedure TLineEditSession.FlushOutput;
begin
  if FOutput <> '' then
    KernelWrite(FOutputHandle, PChar(FOutput), QWord(Length(FOutput)));
  FOutput := '';
end;

procedure TLineEditSession.Emit(Character: Char);
begin
  if Length(FOutput) = OutputCapacity then
    FlushOutput;
  FOutput := FOutput + Character;
end;

procedure TLineEditSession.EmitText(const Text: string);
var
  Character: Char;
begin
  for Character in Text do
    Emit(Character);
end;

{ The end of the shown part of the text. }
function TLineEditSession.WindowEnd: Integer;
begin
  Result := FWindowStart + FWindowWidth;
  if Result > Length(FText) then
    Result := Length(FText);
end;

function TLineEditSession.CursorIsInWindow(Target: Integer): Boolean;
begin
  Result := (Target >= FWindowStart) and (Target <= FWindowStart + FWindowWidth);
end;

{ Moves the window so that the cursor is in it, keeping some text
  visible on the side it moved towards. }
procedure TLineEditSession.PlaceWindow;
begin
  if FCursor < FWindowStart then
  begin
    if FCursor > FWindowWidth div 3 then
      FWindowStart := FCursor - FWindowWidth div 3
    else
      FWindowStart := 0;
  end
  else if FCursor > FWindowStart + FWindowWidth then
    FWindowStart := FCursor - (FWindowWidth * 2) div 3;
end;

{ Writes the shown text from the terminal cursor to the window end,
  blanks what is left of a longer older line, and goes back to the
  window end. }
procedure TLineEditSession.DrawToWindowEnd;
var
  Finish: Integer;
  Extra: Integer;
begin
  Finish := WindowEnd;
  while FShownCursor < Finish do
  begin
    Emit(FText[FShownCursor + 1]);
    Inc(FShownCursor);
  end;
  Extra := 0;
  while FShownLength > Finish + Extra do
  begin
    Emit(' ');
    Inc(Extra);
  end;
  while Extra > 0 do
  begin
    Emit(KeyBackspace);
    Dec(Extra);
  end;
  FShownLength := Finish;
end;

{ Moves the terminal cursor to text position Target, which must be in
  the window. }
procedure TLineEditSession.StepShownCursor(Target: Integer);
begin
  while FShownCursor > Target do
  begin
    Emit(KeyBackspace);
    Dec(FShownCursor);
  end;
  while FShownCursor < Target do
  begin
    Emit(FText[FShownCursor + 1]);
    Inc(FShownCursor);
  end;
end;

{ Draws the row again from its start: prompt, then the window. }
procedure TLineEditSession.RedrawRow;
var
  OldShownEnd: Integer;
  OldWidth: Integer;
begin
  { What the row showed, measured from the window start, decides how
    much has to be blanked. }
  OldWidth := 0;
  if FShownLength > FWindowStart then
    OldWidth := FShownLength - FWindowStart;
  PlaceWindow;
  Emit(KeyReturn);
  EmitText(FPromptTail);
  FShownCursor := FWindowStart;
  OldShownEnd := FWindowStart + OldWidth;
  if OldShownEnd < FWindowStart + FWindowWidth then
    FShownLength := OldShownEnd
  else
    FShownLength := FWindowStart + FWindowWidth;
  DrawToWindowEnd;
  StepShownCursor(FCursor);
end;

procedure TLineEditSession.MoveShownCursor(Target: Integer);
var
  SavedCursor: Integer;
begin
  if CursorIsInWindow(Target) then
    StepShownCursor(Target)
  else
  begin
    SavedCursor := FCursor;
    FCursor := Target;
    RedrawRow;
    FCursor := SavedCursor;
  end;
end;

{ Redraws the text from position From on, clears what is left of an
  older, longer line, and puts the terminal cursor at the cursor. }
procedure TLineEditSession.RedrawFrom(From: Integer);
begin
  if not CursorIsInWindow(FCursor) or (From < FWindowStart) then
  begin
    RedrawRow;
    Exit;
  end;
  if FShownCursor <> From then
    StepShownCursor(From);
  DrawToWindowEnd;
  StepShownCursor(FCursor);
end;

procedure TLineEditSession.DrawPromptAndLine;
begin
  EmitText(FPrompt);
  FWindowStart := 0;
  FShownCursor := 0;
  FShownLength := 0;
  PlaceWindow;
  if FWindowStart > 0 then
    RedrawRow
  else
    RedrawFrom(0);
end;

{ How wide the text window is: the screen width less the prompt's last
  line, keeping the last column free. }
procedure TLineEditSession.MeasureWindow;
var
  Rows: LongInt;
  Columns: LongInt;
  Number: Int64;
  PromptWidth: Integer;
begin
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  if (GetVariable('COLUMNS') <> nil) and ParseDecimal(GetVariable('COLUMNS'), Number) and
     (Number >= 2 * MinimumWindowWidth) and (Number <= 1000) then
    Columns := LongInt(Number);
  FPromptTail := Copy(FPrompt, LastDelimiter(KeyLineFeed, FPrompt) + 1, MaxInt);
  PromptWidth := Length(FPromptTail);
  if Columns > PromptWidth + 1 + MinimumWindowWidth then
    FWindowWidth := Columns - PromptWidth - 1
  else
    FWindowWidth := MinimumWindowWidth;
end;

{ --- Editing --------------------------------------------------------- }

procedure TLineEditSession.ReplaceText(const NewText: string);
begin
  FText := NewText;
  FCursor := Length(FText);
  RedrawFrom(0);
end;

procedure TLineEditSession.MoveCursor(Target: Integer);
begin
  FCursor := Target;
  MoveShownCursor(FCursor);
end;

procedure TLineEditSession.InsertText(const Characters: string);
var
  From: Integer;
begin
  if Characters = '' then
    Exit;
  Insert(Characters, FText, FCursor + 1);
  From := FCursor;
  FCursor := FCursor + Length(Characters);
  RedrawFrom(From);
end;

procedure TLineEditSession.DeleteRange(First, Count: Integer);
begin
  if (Count <= 0) or (First >= Length(FText)) then
    Exit;
  if First + Count > Length(FText) then
    Count := Length(FText) - First;
  Delete(FText, First + 1, Count);
  if FCursor > First + Count then
    FCursor := FCursor - Count
  else if FCursor > First then
    FCursor := First;
  RedrawFrom(First);
end;

procedure TLineEditSession.DeleteWordBeforeCursor;
var
  Start: Integer;
begin
  Start := FCursor;
  while (Start > 0) and (FText[Start] = ' ') do
    Dec(Start);
  while (Start > 0) and (FText[Start] <> ' ') do
    Dec(Start);
  DeleteRange(Start, FCursor - Start);
end;

procedure TLineEditSession.ShowHistoryEntry(NewIndex: Integer);
begin
  if (NewIndex < 0) or (NewIndex > FHistory.Count) or (NewIndex = FHistoryIndex) then
    Exit;
  if FHistoryIndex = FHistory.Count then
    FScratch := FText;
  FHistoryIndex := NewIndex;
  if NewIndex = FHistory.Count then
    ReplaceText(FScratch)
  else
    ReplaceText(FHistory[NewIndex]);
end;

procedure TLineEditSession.ThrowLineAway;
begin
  MoveShownCursor(Length(FText));
  EmitText('^C'#10);
  FText := '';
  FCursor := 0;
  FHistoryIndex := FHistory.Count;
  DrawPromptAndLine;
end;

procedure TLineEditSession.StartNewRow;
begin
  Emit(KeyLineFeed);
end;

procedure TLineEditSession.FinishRow;
begin
  MoveShownCursor(Length(FText));
  StartNewRow;
end;

{ --- Completion ------------------------------------------------------ }

{ Several matches and nothing to add: list them under the line. }
procedure TLineEditSession.ListMatches(const Matches: array of string);
var
  Index: Integer;
begin
  FinishRow;
  for Index := 0 to High(Matches) do
  begin
    if Index > 0 then
      EmitText('  ');
    EmitText(Matches[Index]);
  end;
  Emit(KeyLineFeed);
  DrawPromptAndLine;
end;

procedure TLineEditSession.CompleteWord;
var
  WordStart: Integer;
  Word: string;
  Completion: TCompletion;
  Common: string;
  Names: array of string;
  Index: Integer;
  Again: Boolean;
begin
  WordStart := FCursor;
  while (WordStart > 0) and (FText[WordStart] <> ' ') do
    Dec(WordStart);
  Word := Copy(FText, WordStart + 1, FCursor - WordStart);
  Again := False;
  { A word in command position is a command, unless it names a path. }
  Completion := TCompletion.Create(Word, (Pos('/', Word) = 0) and IsCommandPosition(FText, WordStart));
  try
    if Completion.MatchCount = 0 then
      Exit;
    Common := Completion.CommonPrefix;
    if Length(Common) > Length(Completion.Prefix) then
      InsertText(Copy(Common, Length(Completion.Prefix) + 1, MaxInt))
    else if Completion.MatchCount = 1 then
    begin
      { Complete: a slash after a directory, a space after anything else. }
      if Completion.MatchIsDirectory(0) then
        InsertText('/')
      else
        InsertText(' ');
    end
    else
    begin
      Names := nil;
      SetLength(Names, Completion.MatchCount);
      for Index := 0 to Completion.MatchCount - 1 do
        Names[Index] := Completion.Matches[Index];
      ListMatches(Names);
    end;
    Again := (Completion.MatchCount = 1) and (Length(Common) > Length(Completion.Prefix));
  finally
    Completion.Free;
  end;
  if Again then
    CompleteWord;
end;

end.

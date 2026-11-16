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

{$mode objfpc}{$H+}

interface

uses
  Classes,
  Util.LineEditing;

type
  TEditResult = (EditLineReady, EditEndOfInput, EditWoken);

  TLineEditor = class
  private
    FHistory: TStringList;
    FHistoryLimit: Integer;
    FHistoryPath: string;
    FOutputHandle: Int64;
    FIsConsole: Boolean;
    FWakeHandle: Int64;
    procedure LoadHistory;
    procedure AppendToHistoryFile(const Line: string);
    function WaitForKeyOrWake: Boolean;
    procedure HandleEscapeSequence(Session: TLineEditSession);
    function EditOnConsole(const Prompt: string; out Line: string): TEditResult;
  public
    { HistoryPath may be '' (no history file). Output (prompt and echo)
      goes to OutputHandle. }
    constructor Create(const HistoryPath: string; OutputHandle: Int64);
    destructor Destroy; override;
    { Reads a line (without its line end). }
    function EditLine(const Prompt: string; out Line: string): TEditResult;
    { Adds Line to the history (empty lines and repeats are skipped). }
    procedure AddHistoryLine(const Line: string);
    { Rewrites the history file with at most the newest HistoryLimit
      lines (lines are appended to it as they are added). }
    procedure SaveHistory;
    { Waited for along with the keys (NoHandle: none). }
    property WakeHandle: Int64 read FWakeHandle write FWakeHandle;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Files,
  Sys.Kernel,
  Sys.Objects,
  Sys.Streams,
  Util.Input,
  Util.Output;

const
  DefaultHistoryLimit = 500;

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

{ Every line of Path ('' when it cannot be read: no message). }
procedure ReadLinesOf(const Path: string; Lines: TStrings);
var
  Stream: PInputStream;
begin
  if (Path = '') or not PathExists(PChar(Path)) then
    Exit;
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit;
  ReadLinesInto(Stream, Lines);
  CloseInput(Stream);
end;

constructor TLineEditor.Create(const HistoryPath: string; OutputHandle: Int64);
begin
  inherited Create;
  FHistory := TStringList.Create;
  FHistoryLimit := DefaultHistoryLimit;
  FHistoryPath := HistoryPath;
  FOutputHandle := OutputHandle;
  FIsConsole := IsConsole(StandardInputHandle);
  FWakeHandle := NoHandle;
  LoadHistory;
end;

destructor TLineEditor.Destroy;
begin
  FHistory.Free;
  inherited Destroy;
end;

procedure TLineEditor.LoadHistory;
begin
  ReadLinesOf(FHistoryPath, FHistory);
end;

{ --- Reading keys ---------------------------------------------------- }

function ReadKey(out Character: Char): Boolean;
begin
  Result := KernelRead(StandardInputHandle, @Character, 1) = 1;
end;

{ Waits for a key, or for the wake handle: False if the wake handle came
  first. }
function TLineEditor.WaitForKeyOrWake: Boolean;
begin
  if FWakeHandle = NoHandle then
    Exit(True);
  Result := WaitForHandles([StandardInputHandle, FWakeHandle], InfiniteWait) <> 1;
end;

{ Handles the rest of an escape sequence (after ESC). }
procedure TLineEditor.HandleEscapeSequence(Session: TLineEditSession);
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
    if Character in ['0'..'9'] then
      Parameter := Parameter * 10 + Ord(Character) - Ord('0');
  until (Character >= '@') and (Character <= '~');
  case Character of
    'A': Session.ShowHistoryEntry(Session.HistoryIndex - 1);
    'B': Session.ShowHistoryEntry(Session.HistoryIndex + 1);
    'C':
      if Session.Cursor < Length(Session.Text) then
        Session.MoveCursor(Session.Cursor + 1);
    'D':
      if Session.Cursor > 0 then
        Session.MoveCursor(Session.Cursor - 1);
    'H': Session.MoveCursor(0);
    'F': Session.MoveCursor(Length(Session.Text));
    '~':
      case Parameter of
        1, 7: Session.MoveCursor(0);
        4, 8: Session.MoveCursor(Length(Session.Text));
        3: Session.DeleteRange(Session.Cursor, 1);
      end;
  end;
end;

function TLineEditor.EditOnConsole(const Prompt: string; out Line: string): TEditResult;
var
  Session: TLineEditSession;
  Character: Char;
  Done: Boolean;
begin
  Line := '';
  Session := TLineEditSession.Create(FHistory, FOutputHandle, Prompt);
  try
    Session.DrawPromptAndLine;
    Session.FlushOutput;
    Result := EditLineReady;
    Done := False;
    while not Done do
    begin
      if not WaitForKeyOrWake then
      begin
        Session.FinishRow;
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
            Session.FinishRow;
            Done := True;
          end;
        KeyInterrupt: Session.ThrowLineAway;
        KeyControlD:
          if Session.Text = '' then
          begin
            Session.FinishRow;
            Result := EditEndOfInput;
            Done := True;
          end
          else
            Session.DeleteRange(Session.Cursor, 1);
        KeyBackspace, KeyDelete:
          if Session.Cursor > 0 then
            Session.DeleteRange(Session.Cursor - 1, 1);
        KeyControlA: Session.MoveCursor(0);
        KeyControlE: Session.MoveCursor(Length(Session.Text));
        KeyControlB:
          if Session.Cursor > 0 then
            Session.MoveCursor(Session.Cursor - 1);
        KeyControlF:
          if Session.Cursor < Length(Session.Text) then
            Session.MoveCursor(Session.Cursor + 1);
        KeyControlK: Session.DeleteRange(Session.Cursor, Length(Session.Text) - Session.Cursor);
        KeyControlU: Session.DeleteRange(0, Session.Cursor);
        KeyControlW: Session.DeleteWordBeforeCursor;
        KeyControlP: Session.ShowHistoryEntry(Session.HistoryIndex - 1);
        KeyControlN: Session.ShowHistoryEntry(Session.HistoryIndex + 1);
        KeyControlL:
          begin
            Session.StartNewRow;
            Session.DrawPromptAndLine;
          end;
        KeyTab: Session.CompleteWord;
        KeyEscape: HandleEscapeSequence(Session);
      else
        if Character >= ' ' then
          Session.InsertText(Character);
      end;
      Session.FlushOutput;
    end;
    Session.FlushOutput;
    if Result = EditLineReady then
      Line := Session.Text;
  finally
    Session.Free;
  end;
end;

{ --- The public interface -------------------------------------------- }

function TLineEditor.EditLine(const Prompt: string; out Line: string): TEditResult;
var
  SavedMode: Int64;
  HadLineEnd: Boolean;
begin
  if not FIsConsole then
  begin
    if Prompt <> '' then
      KernelWrite(FOutputHandle, PChar(Prompt), Length(Prompt));
    if ReadTextLine(StandardInput, Line, HadLineEnd) then
      Result := EditLineReady
    else
      Result := EditEndOfInput;
    Exit;
  end;
  FlushStandardStreams;
  SavedMode := GetConsoleMode(StandardInputHandle);
  { Characters one at a time, no echo; Ctrl-C keeps working. }
  SetConsoleMode(StandardInputHandle, ConsoleModeInterruptKey);
  Result := EditOnConsole(Prompt, Line);
  if SavedMode >= 0 then
    SetConsoleMode(StandardInputHandle, LongWord(SavedMode));
end;

{ Each line goes to the file at once, so it survives a crash and other
  shells started meanwhile see it. }
procedure TLineEditor.AppendToHistoryFile(const Line: string);
var
  Handle: Int64;
  Text: string;
begin
  if FHistoryPath = '' then
    Exit;
  Handle := OpenFile(PChar(FHistoryPath), OpenWrite or OpenCreate or OpenAppend);
  if Handle < 0 then
    Exit;
  Text := Line + #10;
  WriteAll(Handle, PChar(Text), Length(Text));
  CloseFile(Handle);
end;

procedure TLineEditor.AddHistoryLine(const Line: string);
begin
  if Line = '' then
    Exit;
  if (FHistory.Count > 0) and (FHistory[FHistory.Count - 1] = Line) then
    Exit;
  AppendToHistoryFile(Line);
  FHistory.Add(Line);
  if FHistory.Count > FHistoryLimit then
    FHistory.Delete(0);
end;

procedure TLineEditor.SaveHistory;
var
  Handle: Int64;
  Stream: POutputStream;
  FileLines: TStringList;
  Index: Integer;
begin
  if FHistoryPath = '' then
    Exit;
  { Other shells may have added lines; keep the newest of the file. }
  FileLines := TStringList.Create;
  try
    ReadLinesOf(FHistoryPath, FileLines);
    if FileLines.Count <= FHistoryLimit then
      Exit;
    FHistory.Clear;
    for Index := FileLines.Count - FHistoryLimit to FileLines.Count - 1 do
      FHistory.Add(FileLines[Index]);
  finally
    FileLines.Free;
  end;
  Handle := OpenFile(PChar(FHistoryPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit;
  Stream := CreateOutputStream(Handle);
  for Index := 0 to FHistory.Count - 1 do
    WriteStringLine(Stream, FHistory[Index]);
  DestroyOutputStream(Stream);
  CloseFile(Handle);
end;

end.

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
  Running a sed script over input: the cycle of reading a line into the
  pattern space, running the commands on it and printing it.

  The input files are read in turn as one stream, one line ahead so that
  "$" (the last line) can be recognized. With Separate each file is its
  own stream: ProcessStream stops at the end of each file.
}
unit Sed.Editor;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Streams,
  Util.RegularExpressions,
  Sed.Script;

type
  { Output queued until the end of the cycle (a, r). }
  TQueuedOutput = record
    IsFile: Boolean;
    Text: string;
  end;

  TStreamEditor = class
  private
    FScript: TScript;
    FLastExpression: PExpression;
    FPatternSpace: string;
    FHoldSpace: string;
    FQueue: array of TQueuedOutput;
    FLineNumber: Int64;
    FSubstituted: Boolean;
    FInputFiles: array of string;
    FInputIndex: Integer;
    FCurrentInput: PInputStream;
    FLookAhead: string;
    FHaveLookAhead: Boolean;
    function OpenNextInput: Boolean;
    function ReadUntilLineEnd(out Line: string): Boolean;
    function ReadRawLine(out Line: string): Boolean;
    function NextLine(out Line: string): Boolean;
    function IsLastLine: Boolean;
    procedure WritePatternSpace(Stream: POutputStream; UpToLineEnd: Boolean);
    procedure WriteUnambiguous;
    procedure QueueOutput(const Text: string; IsFile: Boolean);
    procedure CopyFileToOutput(const Path: string);
    procedure FlushQueue;
    function RegexFor(Expression: PExpression): PExpression;
    function AddressMatches(const Address: TAddress): Boolean;
    function CommandSelects(var Command: TCommand): Boolean;
    procedure AppendReplacement(var Builder: string; const Replacement, Subject: string;
      const Match: TMatch);
    function Substitute(const Command: TCommand): Boolean;
    procedure EndCycleOutput;
    procedure RunCycle(out StartNextWithoutReading: Boolean);
  public
    Quiet: Boolean;
    Separate: Boolean;
    LineEnd: Char;
    Output: POutputStream;
    Quitting: Boolean;
    QuitCode: LongInt;
    ExitStatus: LongInt;
    constructor Create(Script: TScript);
    procedure SetInputFiles(const Paths: array of string);
    function HasInputLeft: Boolean;
    { Forgets the line numbers, the look ahead and the ranges, for a new
      stream. }
    procedure ResetStreamState;
    { Processes the input files currently set up as one stream. }
    procedure ProcessStream;
  end;

implementation

uses
  Sys.Files,
  Util.Input,
  Util.Messages;

const
  LineWrapWidth = 70;

constructor TStreamEditor.Create(Script: TScript);
begin
  inherited Create;
  FScript := Script;
  LineEnd := #10;
  Output := StandardOutput;
end;

procedure TStreamEditor.SetInputFiles(const Paths: array of string);
var
  Index: Integer;
begin
  SetLength(FInputFiles, Length(Paths));
  for Index := 0 to High(Paths) do
    FInputFiles[Index] := Paths[Index];
  FInputIndex := 0;
end;

function TStreamEditor.HasInputLeft: Boolean;
begin
  Result := FInputIndex < Length(FInputFiles);
end;

procedure TStreamEditor.ResetStreamState;
begin
  FLineNumber := 0;
  FHaveLookAhead := False;
  FCurrentInput := nil;
  FScript.ResetRanges;
end;

{ --- Input ----------------------------------------------------------- }

{ Opens the next input file; False when there are none left. }
function TStreamEditor.OpenNextInput: Boolean;
var
  Path: string;
begin
  Result := False;
  while HasInputLeft do
  begin
    Path := FInputFiles[FInputIndex];
    Inc(FInputIndex);
    if Path = '-' then
      FCurrentInput := StandardInput
    else
    begin
      if IsDirectory(PChar(Path)) then
      begin
        Report('couldn''t edit ' + Path + ': not a regular file');
        ExitStatus := 2;
        Continue;
      end;
      FCurrentInput := OpenInput(Path);
      if FCurrentInput = nil then
      begin
        ExitStatus := 2;
        Continue;
      end;
    end;
    Exit(True);
  end;
end;

{ A line ended by LineEnd when that is not a line feed (-z). }
function TStreamEditor.ReadUntilLineEnd(out Line: string): Boolean;
var
  Character: Char;
begin
  Line := '';
  Result := False;
  while ReadCharacter(FCurrentInput, Character) do
  begin
    Result := True;
    if Character = LineEnd then
      Break;
    Line := Line + Character;
  end;
end;

{ Reads the next raw line from the input files (in order). }
function TStreamEditor.ReadRawLine(out Line: string): Boolean;
var
  HadLineEnd: Boolean;
begin
  Line := '';
  repeat
    if FCurrentInput = nil then
      if not OpenNextInput then
        Exit(False);
    if LineEnd = #10 then
    begin
      if ReadTextLine(FCurrentInput, Line, HadLineEnd) then
        Exit(True);
    end
    else if ReadUntilLineEnd(Line) then
      Exit(True);
    CloseInput(FCurrentInput);
    FCurrentInput := nil;
    { With -s or -i each file is its own stream. }
    if Separate then
      Exit(False);
  until False;
end;

function TStreamEditor.NextLine(out Line: string): Boolean;
begin
  if not FHaveLookAhead then
    FHaveLookAhead := ReadRawLine(FLookAhead);
  Result := FHaveLookAhead;
  Line := FLookAhead;
  if Result then
  begin
    FHaveLookAhead := ReadRawLine(FLookAhead);
    Inc(FLineNumber);
  end;
end;

function TStreamEditor.IsLastLine: Boolean;
begin
  if not FHaveLookAhead then
    FHaveLookAhead := ReadRawLine(FLookAhead);
  Result := not FHaveLookAhead;
end;

{ --- Output ---------------------------------------------------------- }

procedure TStreamEditor.WritePatternSpace(Stream: POutputStream; UpToLineEnd: Boolean);
var
  Count: Integer;
  Newline: Integer;
begin
  Count := Length(FPatternSpace);
  if UpToLineEnd then
  begin
    Newline := Pos(#10, FPatternSpace);
    if Newline > 0 then
      Count := Newline - 1;
  end;
  WriteBytes(Stream, PChar(FPatternSpace), Count);
  WriteCharacter(Stream, LineEnd);
end;

{ How l shows one byte: C escapes, three octal digits for the other
  unprintable bytes. }
function UnambiguousText(Character: Byte): string;
const
  Escapes: array[7..13] of Char = ('a', 'b', 't', 'n', 'v', 'f', 'r');
begin
  if Character = Ord('\') then
    Result := '\\'
  else if (Character >= 7) and (Character <= 13) then
    Result := '\' + Escapes[Character]
  else if (Character < 32) or (Character >= 127) then
    Result := '\' + Char(Ord('0') + (Character shr 6)) + Char(Ord('0') + ((Character shr 3) and 7)) +
      Char(Ord('0') + (Character and 7))
  else
    Result := Char(Character);
end;

procedure TStreamEditor.WriteUnambiguous;
var
  Index: Integer;
  Column: Integer;
  Piece: string;
begin
  Column := 0;
  for Index := 1 to Length(FPatternSpace) do
  begin
    Piece := UnambiguousText(Byte(FPatternSpace[Index]));
    if Column + Length(Piece) > LineWrapWidth - 1 then
    begin
      WriteString(Output, '\'#10);
      Column := 0;
    end;
    WriteString(Output, Piece);
    Column := Column + Length(Piece);
  end;
  WriteString(Output, '$'#10);
end;

procedure TStreamEditor.QueueOutput(const Text: string; IsFile: Boolean);
var
  Queued: TQueuedOutput;
begin
  Queued.Text := Text;
  Queued.IsFile := IsFile;
  Insert(Queued, FQueue, Length(FQueue));
end;

{ A missing file is silently ignored, as in GNU sed. }
procedure TStreamEditor.CopyFileToOutput(const Path: string);
var
  Stream: PInputStream;
  Buffer: array[0..4095] of Byte;
  Count: QWord;
begin
  if not PathExists(PChar(Path)) then
    Exit;
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit;
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    WriteBytes(Output, @Buffer[0], Count);
  until Count = 0;
  CloseInput(Stream);
end;

procedure TStreamEditor.FlushQueue;
var
  Index: Integer;
begin
  for Index := 0 to High(FQueue) do
    if FQueue[Index].IsFile then
      CopyFileToOutput(FQueue[Index].Text)
    else
    begin
      WriteStringLine(Output, FQueue[Index].Text);
    end;
  FQueue := nil;
end;

{ --- Matching addresses ---------------------------------------------- }

function TStreamEditor.RegexFor(Expression: PExpression): PExpression;
begin
  if Expression = nil then
  begin
    if FLastExpression = nil then
      Fail(1, 'no previous regular expression');
    Exit(FLastExpression);
  end;
  FLastExpression := Expression;
  Result := Expression;
end;

function TStreamEditor.AddressMatches(const Address: TAddress): Boolean;
var
  Match: TMatch;
begin
  case Address.Kind of
    AddressLine: Result := FLineNumber = Address.Line;
    AddressLast: Result := IsLastLine;
    AddressStep:
      if Address.Step <= 0 then
        Result := FLineNumber = Address.Line
      else
        Result := (FLineNumber >= Address.Line) and ((FLineNumber - Address.Line) mod Address.Step = 0);
    AddressRegex: Result := SearchExpression(RegexFor(Address.Expression)^, FPatternSpace, Match);
  else
    Result := True;
  end;
end;

function TStreamEditor.CommandSelects(var Command: TCommand): Boolean;
begin
  if Command.First.Kind = AddressNone then
    Result := True
  else if Command.Second.Kind = AddressNone then
    Result := AddressMatches(Command.First)
  else if Command.InRange then
  begin
    { The range ends at the second address (inclusive). }
    Result := True;
    case Command.Second.Kind of
      AddressLine, AddressRelative:
        if FLineNumber >= Command.RangeEnd then
          Command.InRange := False;
    else
      if AddressMatches(Command.Second) then
        Command.InRange := False;
    end;
  end
  else if AddressMatches(Command.First) then
  begin
    Result := True;
    Command.InRange := True;
    case Command.Second.Kind of
      AddressLine:
        begin
          Command.RangeEnd := Command.Second.Line;
          if Command.RangeEnd <= FLineNumber then
            Command.InRange := False;
        end;
      AddressRelative:
        begin
          Command.RangeEnd := FLineNumber + Command.Second.Line;
          if Command.Second.Line = 0 then
            Command.InRange := False;
        end;
      AddressLast:
        if IsLastLine then
          Command.InRange := False;
    end;
  end
  else
    Result := False;
  if Command.Negate then
    Result := not Result;
end;

{ --- Substitution ---------------------------------------------------- }

{ The text of a match group; Match offsets count bytes from 0. }
function GroupText(const Subject: string; const Match: TMatch; Group: Integer): string;
begin
  Result := Copy(Subject, Match.Starts[Group] + 1, Match.Ends[Group] - Match.Starts[Group]);
end;

procedure TStreamEditor.AppendReplacement(var Builder: string; const Replacement, Subject: string;
  const Match: TMatch);
var
  Index: Integer;
  Group: Integer;
begin
  Index := 1;
  while Index <= Length(Replacement) do
  begin
    if Replacement[Index] = '&' then
      Builder := Builder + GroupText(Subject, Match, 0)
    else if (Replacement[Index] = '\') and (Index < Length(Replacement)) then
    begin
      Inc(Index);
      if Replacement[Index] in ['0'..'9'] then
      begin
        Group := Ord(Replacement[Index]) - Ord('0');
        if (Group < MaximumGroups) and (Match.Starts[Group] >= 0) then
          Builder := Builder + GroupText(Subject, Match, Group);
      end
      else if Replacement[Index] = 't' then
        Builder := Builder + #9
      else
        Builder := Builder + Replacement[Index];
    end
    else
      Builder := Builder + Replacement[Index];
    Inc(Index);
  end;
end;

function TStreamEditor.Substitute(const Command: TCommand): Boolean;
var
  Expression: PExpression;
  Builder: string;
  Subject: string;
  { Byte offsets from 0, as in TMatch. }
  From: PtrInt;
  Copied: PtrInt;
  Match: TMatch;
  Count: Int64;
begin
  Result := False;
  Expression := RegexFor(Command.Expression);
  Subject := FPatternSpace;
  Builder := '';
  From := 0;
  Copied := 0;
  Count := 0;
  while (From <= Length(Subject)) and SearchExpressionFrom(Expression^, Subject, From, Match) do
  begin
    Inc(Count);
    if Count >= Command.Occurrence then
    begin
      Builder := Builder + Copy(Subject, Copied + 1, Match.Starts[0] - Copied);
      AppendReplacement(Builder, Command.Replacement, Subject, Match);
      Copied := Match.Ends[0];
      Result := True;
      if not Command.Global then
        Break;
    end;
    { An empty match must still move on. }
    if Match.Ends[0] = Match.Starts[0] then
    begin
      if (Count >= Command.Occurrence) and (Match.Ends[0] < Length(Subject)) then
      begin
        Builder := Builder + Subject[Match.Ends[0] + 1];
        Copied := Match.Ends[0] + 1;
      end;
      From := Match.Ends[0] + 1;
    end
    else
      From := Match.Ends[0];
  end;
  if Result then
    FPatternSpace := Builder + Copy(Subject, Copied + 1, MaxInt);
end;

{ --- Executing ------------------------------------------------------- }

procedure TStreamEditor.EndCycleOutput;
begin
  if not Quiet then
    WritePatternSpace(Output, False);
  FlushQueue;
end;

{ Runs the script on the pattern space. StartNextWithoutReading is set
  when the next cycle starts on what D left. }
procedure TStreamEditor.RunCycle(out StartNextWithoutReading: Boolean);
var
  Counter: Integer;
  Command: PCommand;
  Line: string;
  Newline: Integer;
  Index: Integer;
begin
  StartNextWithoutReading := False;
  FSubstituted := False;
  Counter := 0;
  while Counter < Length(FScript.Commands) do
  begin
    Command := @FScript.Commands[Counter];
    Inc(Counter);
    if Command^.Name in [':', '}'] then
      Continue;
    if not CommandSelects(Command^) then
    begin
      if Command^.Name = '{' then
        Counter := Command^.JumpTarget;
      Continue;
    end;
    case Command^.Name of
      '{': ;
      '=':
        begin
          WriteDecimal(Output, FLineNumber);
          WriteCharacter(Output, #10);
        end;
      'a': QueueOutput(Command^.Text, False);
      'i': WriteStringLine(Output, Command^.Text);
      'c':
        begin
          { In a range, the text replaces the whole range. }
          if not Command^.InRange or Command^.Negate then
            WriteStringLine(Output, Command^.Text);
          FlushQueue;
          Exit;
        end;
      'd':
        begin
          FlushQueue;
          Exit;
        end;
      'D':
        begin
          Newline := Pos(#10, FPatternSpace);
          FlushQueue;
          if Newline = 0 then
            Exit;
          Delete(FPatternSpace, 1, Newline);
          StartNextWithoutReading := True;
          Exit;
        end;
      'p': WritePatternSpace(Output, False);
      'P': WritePatternSpace(Output, True);
      'l': WriteUnambiguous;
      'n':
        begin
          if Quitting or IsLastLine then
          begin
            { GNU sed prints the pattern space and stops. }
            EndCycleOutput;
            Quitting := True;
            Exit;
          end;
          EndCycleOutput;
          NextLine(Line);
          FPatternSpace := Line;
        end;
      'N':
        begin
          if IsLastLine then
          begin
            EndCycleOutput;
            Quitting := True;
            Exit;
          end;
          NextLine(Line);
          FPatternSpace := FPatternSpace + #10 + Line;
        end;
      'g': FPatternSpace := FHoldSpace;
      'G': FPatternSpace := FPatternSpace + #10 + FHoldSpace;
      'h': FHoldSpace := FPatternSpace;
      'H': FHoldSpace := FHoldSpace + #10 + FPatternSpace;
      'x':
        begin
          Line := FPatternSpace;
          FPatternSpace := FHoldSpace;
          FHoldSpace := Line;
        end;
      'z': FPatternSpace := '';
      's':
        if Substitute(Command^) then
        begin
          FSubstituted := True;
          if Command^.PrintAfter then
            WritePatternSpace(Output, False);
          if Command^.WriteFile >= 0 then
            WritePatternSpace(FScript.WriteFiles[Command^.WriteFile].Stream, False);
        end;
      'y':
        begin
          UniqueString(FPatternSpace);
          for Index := 1 to Length(FPatternSpace) do
            FPatternSpace[Index] := Command^.Translation[FPatternSpace[Index]];
        end;
      'r': QueueOutput(Command^.Text, True);
      'w': WritePatternSpace(FScript.WriteFiles[Command^.WriteFile].Stream, False);
      'b': Counter := Command^.JumpTarget;
      't':
        if FSubstituted then
        begin
          FSubstituted := False;
          Counter := Command^.JumpTarget;
        end;
      'T':
        if not FSubstituted then
          Counter := Command^.JumpTarget
        else
          FSubstituted := False;
      'q':
        begin
          EndCycleOutput;
          Quitting := True;
          QuitCode := Command^.ExitCode;
          Exit;
        end;
      'Q':
        begin
          Quitting := True;
          QuitCode := Command^.ExitCode;
          Exit;
        end;
    end;
  end;
  EndCycleOutput;
end;

procedure TStreamEditor.ProcessStream;
var
  StartWithoutReading: Boolean;
begin
  StartWithoutReading := False;
  while not Quitting do
  begin
    if not StartWithoutReading then
      if not NextLine(FPatternSpace) then
        Break;
    RunCycle(StartWithoutReading);
  end;
end;

end.

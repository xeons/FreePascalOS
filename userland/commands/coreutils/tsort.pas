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
  tsort - perform topological sort

  tsort [FILE]

  The input is pairs of words "A B", meaning A comes before B. The output
  lists every word once, in an order that respects all pairs. Loops are
  reported, and broken so the output is still complete.
}
program tsort;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages;

const
  Usage = 'Usage: tsort [OPTION] [FILE]'#10 +
    'Write totally ordered list consistent with the partial ordering in FILE.'#10;

  WhiteSpace = [' ', #9, #10, #11, #12, #13];

type
  TNode = record
    Name: string;
    { Words that must come after this one. }
    Successors: array of Integer;
    Predecessors: Integer;
    Done: Boolean;
  end;

var
  Nodes: array of TNode;

function FindOrAdd(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Nodes) do
    if Nodes[Index].Name = Name then
      Exit(Index);
  Result := Length(Nodes);
  SetLength(Nodes, Result + 1);
  Nodes[Result].Name := Name;
  Nodes[Result].Predecessors := 0;
  Nodes[Result].Done := False;
end;

procedure AddEdge(Before, After: Integer);
var
  Count: Integer;
begin
  if Before = After then
    Exit;
  Count := Length(Nodes[Before].Successors);
  SetLength(Nodes[Before].Successors, Count + 1);
  Nodes[Before].Successors[Count] := After;
  Inc(Nodes[After].Predecessors);
end;

procedure Release(Index: Integer);
var
  Successor: Integer;
begin
  PrintStringLine(Nodes[Index].Name);
  Nodes[Index].Done := True;
  for Successor in Nodes[Index].Successors do
    Dec(Nodes[Successor].Predecessors);
end;

{ Appends the words of Line (separated by white space) to Words. }
procedure SplitWords(const Line: string; Words: TStrings);
var
  Position: Integer;
  Start: Integer;
begin
  Position := 1;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and (Line[Position] in WhiteSpace) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and not (Line[Position] in WhiteSpace) do
      Inc(Position);
    Words.Add(Copy(Line, Start, Position - Start));
  end;
end;

procedure ReadWords(Stream: PInputStream; Words: TStrings);
var
  Line: string;
  HadLineEnd: Boolean;
begin
  while ReadTextLine(Stream, Line, HadLineEnd) do
    SplitWords(Line, Words);
end;

var
  CommandLine: TCommandLine;
  Stream: PInputStream;
  Words: TStringList;
  Index: Integer;
  Remaining: Integer;
  Progress: Boolean;
  SourceName: string;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  SourceName := '-';
  if CommandLine.OperandCount = 1 then
    SourceName := CommandLine.Operands[0];
  Stream := OpenInput(SourceName);
  if Stream = nil then
    Halt(1);

  Words := TStringList.Create;
  ReadWords(Stream, Words);
  CloseInput(Stream);
  if Words.Count mod 2 <> 0 then
    Fail(1, SourceName + ': input contains an odd number of tokens');

  Index := 0;
  while Index < Words.Count do
  begin
    AddEdge(FindOrAdd(Words[Index]), FindOrAdd(Words[Index + 1]));
    Index := Index + 2;
  end;
  Words.Free;

  ExitStatus := 0;
  Remaining := Length(Nodes);
  while Remaining > 0 do
  begin
    Progress := False;
    for Index := 0 to High(Nodes) do
      if not Nodes[Index].Done and (Nodes[Index].Predecessors = 0) then
      begin
        Release(Index);
        Dec(Remaining);
        Progress := True;
      end;
    if not Progress then
    begin
      { A loop: report and break it at its first remaining word. }
      ExitStatus := 1;
      for Index := 0 to High(Nodes) do
        if not Nodes[Index].Done then
        begin
          Report(SourceName + ': input contains a loop:');
          Report(Nodes[Index].Name);
          Release(Index);
          Dec(Remaining);
          Break;
        end;
    end;
  end;
  Halt(ExitStatus);
end.

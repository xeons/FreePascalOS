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
{$pointermath on}

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: tsort [OPTION] [FILE]'#10 +
    'Write totally ordered list consistent with the partial ordering in FILE.'#10;

type
  PNode = ^TNode;
  TNode = record
    Name: PChar;
    { Words that must come after this one. }
    Successors: PInteger;
    SuccessorCount: Integer;
    SuccessorCapacity: Integer;
    Predecessors: Integer;
    Done: Boolean;
  end;

var
  Nodes: PNode;
  NodeCount: Integer;
  NodeCapacity: Integer;

function FindOrAdd(Name: PChar): Integer;
var
  Index: Integer;
begin
  for Index := 0 to NodeCount - 1 do
    if TextIsEqual(Nodes[Index].Name, Name) then
      Exit(Index);
  if NodeCount = NodeCapacity then
  begin
    NodeCapacity := NodeCapacity * 2 + 16;
    Nodes := PNode(ReallocateMemory(Nodes, QWord(NodeCapacity) * SizeOf(TNode)));
  end;
  ZeroMemory(@Nodes[NodeCount], SizeOf(TNode));
  Nodes[NodeCount].Name := DuplicateText(Name);
  Result := NodeCount;
  Inc(NodeCount);
end;

procedure AddEdge(Before, After: Integer);
var
  Node: PNode;
begin
  if Before = After then
    Exit;
  Node := @Nodes[Before];
  if Node^.SuccessorCount = Node^.SuccessorCapacity then
  begin
    Node^.SuccessorCapacity := Node^.SuccessorCapacity * 2 + 4;
    Node^.Successors := PInteger(ReallocateMemory(Node^.Successors, QWord(Node^.SuccessorCapacity) * SizeOf(Integer)));
  end;
  Node^.Successors[Node^.SuccessorCount] := After;
  Inc(Node^.SuccessorCount);
  Inc(Nodes[After].Predecessors);
end;

procedure Release(Index: Integer);
var
  Successor: Integer;
begin
  PrintLine(Nodes[Index].Name);
  Nodes[Index].Done := True;
  for Successor := 0 to Nodes[Index].SuccessorCount - 1 do
    Dec(Nodes[Nodes[Index].Successors[Successor]].Predecessors);
end;

var
  Parser: TOptionParser;
  Stream: PInputStream;
  Words: TLineList;
  Line: PChar;
  HadLineEnd: Boolean;
  Position: PtrUInt;
  Start: PtrUInt;
  Index: Integer;
  Remaining: Integer;
  Progress: Boolean;
  SourceName: PChar;
  ExitStatus: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  SourceName := '-';
  if Parser.OperandCount = 1 then
    SourceName := Parser.Operands[0];
  Stream := OpenInput(SourceName);
  if Stream = nil then
    Halt(1);

  BeginLineList(Words);
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    Position := 0;
    while Line[Position] <> #0 do
    begin
      while IsSpace(Line[Position]) do
        Inc(Position);
      if Line[Position] = #0 then
        Break;
      Start := Position;
      while (Line[Position] <> #0) and not IsSpace(Line[Position]) do
        Inc(Position);
      if Line[Position] <> #0 then
      begin
        Line[Position] := #0;
        Inc(Position);
      end;
      AddLine(Words, DuplicateText(Line + Start));
    end;
    FreeMemory(Line);
  end;
  CloseInput(Stream);
  if Words.Count mod 2 <> 0 then
    Fail(1, '%s: input contains an odd number of tokens', [ArgumentText(SourceName)]);

  Index := 0;
  while Index < Words.Count do
  begin
    AddEdge(FindOrAdd(Words.Items[Index]), FindOrAdd(Words.Items[Index + 1]));
    Index := Index + 2;
  end;

  ExitStatus := 0;
  Remaining := NodeCount;
  while Remaining > 0 do
  begin
    Progress := False;
    for Index := 0 to NodeCount - 1 do
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
      for Index := 0 to NodeCount - 1 do
        if not Nodes[Index].Done then
        begin
          Report('%s: input contains a loop:', [ArgumentText(SourceName)]);
          Report('%s', [ArgumentText(Nodes[Index].Name)]);
          Release(Index);
          Dec(Remaining);
          Break;
        end;
    end;
  end;
  Halt(ExitStatus);
end.

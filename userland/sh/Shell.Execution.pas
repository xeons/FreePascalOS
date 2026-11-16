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
  Running parsed commands.

  Simple commands and pipelines are run by Shell.Pipelines (with
  Shell.Commands); this unit runs the lists and compound commands around
  them, inside the shell, and keeps the state that unwinds them: exit,
  break and continue, return, and Ctrl-C. Ctrl-C pressed while the shell
  itself is busy (a loop of builtins) is noticed between commands.
}
unit Shell.Execution;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Nodes;

type
  TLoopControl = (LoopControlNone, LoopControlBreak, LoopControlContinue);

var
  { Set by the exit builtin; unwinds all execution. }
  ExitRequested: Boolean = False;
  RequestedExitCode: LongInt = 0;
  { Set by break and continue; LoopLevels is how many loops are left. }
  LoopControl: TLoopControl = LoopControlNone;
  LoopLevels: Integer = 0;
  LoopDepth: Integer = 0;
  { Set by sh when it reads commands from the console. }
  ShellIsInteractive: Boolean = False;
  { Set when a foreground program was ended by Ctrl-C; cleared by sh
    before each command line. }
  InterruptRequested: Boolean = False;
  { Set by the return builtin; unwinds to the function call. }
  ReturnRequested: Boolean = False;
  ReturnStatus: LongInt = 0;
  FunctionDepth: Integer = 0;

{ True while break, continue, return, exit or Ctrl-C unwinds execution. }
function Unwinding: Boolean;

function ExecuteNode(Node: TShellNode): LongInt;
{ Parses and runs Text; syntax errors give status 2. }
function ExecuteText(const Text: string): LongInt;

implementation

uses
  Classes,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Streams,
  Shell.Output,
  Shell.Syntax,
  Shell.Variables,
  Shell.Expansion,
  Shell.Functions,
  Shell.Patterns,
  Shell.Redirections,
  Shell.Pipelines;

function Unwinding: Boolean;
begin
  Result := ExitRequested or InterruptRequested or ReturnRequested or (LoopControl <> LoopControlNone);
end;

{ Notices Ctrl-C pressed while the interactive shell runs builtins. }
procedure CheckPendingInterrupt;
begin
  if ShellIsInteractive and not InterruptRequested and TakePendingInterrupt(StandardInputHandle) then
  begin
    InterruptRequested := True;
    FlushStream(StandardOutput);
    WriteString(StandardError, '^C'#10);
  end;
end;

{ --- Loops ------------------------------------------------------------- }

{ True when a break or continue (or exit) ends the current loop body. }
function LeaveLoopBody: Boolean;
begin
  CheckPendingInterrupt;
  Result := Unwinding;
end;

{ After a loop body: returns True if the loop itself must stop. }
function LoopMustStop: Boolean;
begin
  if ExitRequested or InterruptRequested or ReturnRequested then
    Exit(True);
  if LoopControl = LoopControlNone then
    Exit(False);
  Dec(LoopLevels);
  if LoopLevels > 0 then
    { The break/continue is for an outer loop. }
    Exit(True);
  Result := LoopControl = LoopControlBreak;
  LoopControl := LoopControlNone;
end;

function ExecuteLoop(Node: TLoopNode): LongInt;
var
  ConditionStatus: LongInt;
begin
  Result := 0;
  Inc(LoopDepth);
  while True do
  begin
    ConditionStatus := ExecuteNode(Node.Condition);
    if LeaveLoopBody then
    begin
      if LoopMustStop then
        Break;
      Continue;
    end;
    if (ConditionStatus = 0) = Node.IsUntil then
      Break;
    Result := ExecuteNode(Node.Body);
    if LeaveLoopBody and LoopMustStop then
      Break;
  end;
  Dec(LoopDepth);
end;

function ExecuteFor(Node: TForNode): LongInt;
var
  Values: TStringList;
  Index: Integer;
begin
  Result := 0;
  Values := TStringList.Create;
  try
    if Node.HasWordList then
      ExpandWords(Node.Words, Values)
    else
      for Index := 1 to PositionalCount do
        Values.Add(PositionalParameter(Index));

    Inc(LoopDepth);
    for Index := 0 to Values.Count - 1 do
    begin
      AssignVariable(Node.VariableName, Values[Index]);
      Result := ExecuteNode(Node.Body);
      if LeaveLoopBody and LoopMustStop then
        Break;
    end;
    Dec(LoopDepth);
  finally
    Values.Free;
  end;
end;

{ --- Other compound commands ------------------------------------------- }

function CaseItemMatches(Item: TCaseItem; const Subject: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Item.Patterns) do
    if MatchPattern(ExpandToPattern(Item.Patterns[Index]), Subject) then
      Exit(True);
  Result := False;
end;

function ExecuteCase(Node: TCaseNode): LongInt;
var
  Subject: string;
  Index: Integer;
begin
  Result := 0;
  Subject := ExpandToText(Node.Subject);
  for Index := 0 to High(Node.Items) do
    if CaseItemMatches(Node.Items[Index], Subject) then
    begin
      Result := ExecuteNode(Node.Items[Index].Body);
      Break;
    end;
end;

{ ConditionUnwound: the condition started unwinding, so no branch ran. }
function ExecuteIf(Node: TIfNode; out ConditionUnwound: Boolean): LongInt;
begin
  Result := ExecuteNode(Node.Condition);
  ConditionUnwound := Unwinding;
  if ConditionUnwound then
    Exit;
  if Result = 0 then
    Result := ExecuteNode(Node.Body)
  else if Node.ElseBody <> nil then
    Result := ExecuteNode(Node.ElseBody)
  else
    Result := 0;
end;

function ExecuteAndOr(Node: TAndOrNode): LongInt;
begin
  Result := ExecuteNode(Node.Left);
  if Unwinding then
    Exit;
  if (Node.Operation = OperatorAnd) and (Result = 0) then
    Result := ExecuteNode(Node.Right)
  else if (Node.Operation = OperatorOr) and (Result <> 0) then
    Result := ExecuteNode(Node.Right);
end;

{ A compound command with redirections: the shell's own handles point
  at the files while it runs. }
function ExecuteRedirected(Node: TRedirectedNode): LongInt;
var
  Handles: TStandardHandles;
  Saved: TStandardHandles;
  Opened: TOpenedHandles;
  Index: Integer;
begin
  for Index := 0 to 2 do
    Handles[Index] := Index;
  Opened := nil;
  if not ApplyRedirections(Node.Redirections, Handles, Opened) then
  begin
    CloseOpenedHandles(Opened);
    Exit(1);
  end;
  SwitchStandardHandles(Handles, Saved);
  Result := ExecuteNode(Node.Body);
  RestoreStandardHandles(Saved);
  CloseOpenedHandles(Opened);
end;

{ A list item ending in '&' runs as a background job. }
function ExecuteInBackground(Item: TShellNode): LongInt;
begin
  if Item.Kind = NodePipeline then
    Result := ExecutePipeline(TPipelineNode(Item).Commands, False, False)
  else
    Result := ExecutePipeline([Item], False, False);
  LastStatus := 0;
end;

function ExecuteSequence(Node: TSequenceNode): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Node.Items) do
  begin
    if Node.RunInBackground[Index] then
      Result := ExecuteInBackground(Node.Items[Index])
    else
      Result := ExecuteNode(Node.Items[Index]);
    CheckPendingInterrupt;
    if Unwinding then
      Break;
  end;
end;

function ExecuteNode(Node: TShellNode): LongInt;
var
  ConditionUnwound: Boolean;
begin
  if Node = nil then
    Exit(0);
  case Node.Kind of
    NodeSimple:
      Result := ExecutePipeline([Node], False, True);
    NodePipeline:
      Result := ExecutePipeline(TPipelineNode(Node).Commands, TPipelineNode(Node).Negate, True);
    NodeAndOr:
      Result := ExecuteAndOr(TAndOrNode(Node));
    NodeSequence:
      Result := ExecuteSequence(TSequenceNode(Node));
    NodeIf:
      begin
        Result := ExecuteIf(TIfNode(Node), ConditionUnwound);
        { An unwinding condition leaves $? as the condition set it. }
        if ConditionUnwound then
          Exit;
      end;
    NodeLoop:
      Result := ExecuteLoop(TLoopNode(Node));
    NodeFor:
      Result := ExecuteFor(TForNode(Node));
    NodeCase:
      Result := ExecuteCase(TCaseNode(Node));
    NodeFunction:
      begin
        DefineFunction(TFunctionNode(Node));
        Result := 0;
      end;
    NodeRedirected:
      Result := ExecuteRedirected(TRedirectedNode(Node));
  else
    Result := 1;
  end;
  LastStatus := Result;
end;

function ExecuteText(const Text: string): LongInt;
var
  Tree: TShellNode;
  Message: string;
begin
  case ParseInput(Text, Tree, Message) of
    ParseSuccess:
      try
        Result := ExecuteNode(Tree);
      finally
        Tree.Free;
      end;
    ParseIncomplete:
      begin
        ShellError('syntax error: unexpected end of input');
        Result := 2;
      end;
  else
    begin
      ShellError(Message);
      Result := 2;
    end;
  end;
  LastStatus := Result;
end;

end.

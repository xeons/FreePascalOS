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
  Simple commands: expanding them, and running them as a program, a
  builtin or a shell function.

  External programs are started as new processes with the standard
  handles they should have (pipe ends, redirected files) and with the
  NAME=value assignments of the command in their environment. Builtins
  and functions run inside the shell, with its own standard handles
  pointed at the right place; their assignments stay in the shell.

  Functions get their own positional parameters and local variables;
  "return" unwinds to the call like "break" unwinds a loop.
}
unit Shell.Commands;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Shell.Nodes,
  Shell.Builtins,
  Shell.Redirections;

type
  { A simple command after expansion (or, with Node nil, a compound
    command that is a stage of a pipeline). }
  TPreparedCommand = class
  public
    Node: TSimpleCommandNode;
    Fields: TStringList;
    Builtin: TBuiltinRoutine;
    { The body if the command names a shell function. }
    FunctionBody: TShellNode;
    { "exec program": the shell ends with the program's status. }
    ExitAfterwards: Boolean;
    { An expansion failed; the command is not run. }
    Failed: Boolean;
    constructor Create(CommandNode: TSimpleCommandNode);
    destructor Destroy; override;
    { True unless the command is an external program. }
    function RunsInShell: Boolean;
  end;

{ Expands Node and finds what its first field names. }
function PrepareCommand(Node: TSimpleCommandNode): TPreparedCommand;
{ Starts an external program; returns its process handle, or -1 after
  reporting a problem (Status tells which). }
function StartExternal(Prepared: TPreparedCommand; const Handles: TStandardHandles; GroupId: Int64;
  out Status: LongInt): Int64;
{ Runs a builtin, a function, or a command consisting only of
  assignments and redirections, inside the shell. }
function RunInShell(Prepared: TPreparedCommand; const Handles: TStandardHandles): LongInt;

implementation

uses
  SysUtils,
  Sys.Environment,
  Sys.Errors,
  Sys.Processes,
  Sys.Streams,
  Shell.Text,
  Shell.Output,
  Shell.Host,
  Shell.Variables,
  Shell.Expansion,
  Shell.Functions,
  Shell.Execution;

const
  StatusNotFound = 127;
  StatusCannotRun = 126;

{ --- TPreparedCommand -------------------------------------------------- }

constructor TPreparedCommand.Create(CommandNode: TSimpleCommandNode);
begin
  inherited Create;
  Node := CommandNode;
  Fields := TStringList.Create;
end;

destructor TPreparedCommand.Destroy;
begin
  Fields.Free;
  inherited Destroy;
end;

function TPreparedCommand.RunsInShell: Boolean;
begin
  Result := (Fields.Count = 0) or (Builtin <> nil) or (FunctionBody <> nil) or Failed;
end;

{ --- Preparing --------------------------------------------------------- }

function PrepareCommand(Node: TSimpleCommandNode): TPreparedCommand;
var
  SkipFunctions: Boolean;
begin
  Result := TPreparedCommand.Create(Node);
  ExpansionFailed := False;
  ExpandWords(Node.Words, Result.Fields);
  Result.Failed := ExpansionFailed;
  if Result.Fields.Count = 0 then
    Exit;
  { "exec program ..." runs the program, then the shell ends. }
  if (Result.Fields[0] = 'exec') and (Result.Fields.Count > 1) then
  begin
    Result.Fields.Delete(0);
    Result.ExitAfterwards := True;
    Exit;
  end;
  { "command name ..." skips functions; "command -v" is a builtin. }
  SkipFunctions := (Result.Fields[0] = 'command') and (Result.Fields.Count > 1) and
    (CharAt(Result.Fields[1], 1) <> '-');
  if SkipFunctions then
    Result.Fields.Delete(0)
  else
    Result.FunctionBody := FindFunction(Result.Fields[0]);
  if Result.FunctionBody = nil then
    Result.Builtin := FindBuiltin(Result.Fields[0]);
end;

{ After an expansion failed: an interactive shell drops the command line,
  a script ends. }
function HandleExpansionFailure: LongInt;
begin
  if ShellIsInteractive then
    InterruptRequested := True
  else
  begin
    ExitRequested := True;
    RequestedExitCode := 1;
  end;
  Result := 1;
end;

{ --- Assignments ------------------------------------------------------- }

procedure SplitAssignment(const Assignment: string; out Name, Value: string);
var
  EqualsPosition: Integer;
begin
  EqualsPosition := Pos('=', Assignment);
  Name := Copy(Assignment, 1, EqualsPosition - 1);
  Value := ExpandToText(Copy(Assignment, EqualsPosition + 1, MaxInt));
end;

procedure PerformAssignments(Node: TSimpleCommandNode);
var
  Index: Integer;
  Name: string;
  Value: string;
begin
  for Index := 0 to High(Node.Assignments) do
  begin
    SplitAssignment(Node.Assignments[Index], Name, Value);
    AssignVariable(Name, Value);
  end;
end;

{ The environment for a program started with "NAME=value command"; nil
  when the command has no assignments. }
function BuildEnvironment(Node: TSimpleCommandNode): TStringList;
var
  Block: PPChar;
  Index: Integer;
  Existing: Integer;
  Name: string;
  Value: string;
begin
  if Length(Node.Assignments) = 0 then
    Exit(nil);
  Result := TStringList.Create;
  Block := EnvironmentBlock;
  for Index := 0 to EnvironmentCount - 1 do
    Result.Add(string(Block[Index]));

  for Index := 0 to High(Node.Assignments) do
  begin
    SplitAssignment(Node.Assignments[Index], Name, Value);
    { Replace an existing entry of the same name. }
    Existing := 0;
    while (Existing < Result.Count) and (Copy(Result[Existing], 1, Length(Name) + 1) <> Name + '=') do
      Inc(Existing);
    if Existing < Result.Count then
      Result[Existing] := Name + '=' + Value
    else
      Result.Add(Name + '=' + Value);
  end;
end;

{ --- Running ----------------------------------------------------------- }

function StartExternal(Prepared: TPreparedCommand; const Handles: TStandardHandles; GroupId: Int64;
  out Status: LongInt): Int64;
var
  Name: string;
  ProgramPath: string;
  Effective: TStandardHandles;
  Opened: TOpenedHandles;
  Options: TProcessOptions;
  Environment: TStringList;
  EnvironmentVector: TTextVector;
  ArgumentVector: TTextVector;
begin
  Status := 0;
  Name := Prepared.Fields[0];
  if not LocateProgram(Name, ProgramPath) then
  begin
    ShellError(Name + ': command not found');
    Status := StatusNotFound;
    Exit(-1);
  end;

  Effective := Handles;
  Opened := nil;
  if not ApplyRedirections(Prepared.Node.Redirections, Effective, Opened) then
  begin
    CloseOpenedHandles(Opened);
    Status := 1;
    Exit(-1);
  end;

  Environment := BuildEnvironment(Prepared.Node);
  try
    DefaultProcessOptions(Options);
    Options.GroupId := GroupId;
    if Environment <> nil then
    begin
      EnvironmentVector := MakeTextVector(Environment);
      Options.Environment := @EnvironmentVector[0];
    end;
    Options.InputHandle := Effective[0];
    Options.OutputHandle := Effective[1];
    Options.ErrorHandle := Effective[2];
    ArgumentVector := MakeTextVector(Prepared.Fields);
    FlushStandardStreams;
    Result := StartProgram(PChar(ProgramPath), @ArgumentVector[0], Options);
  finally
    Environment.Free;
  end;
  CloseOpenedHandles(Opened);

  if Result < 0 then
  begin
    ShellError(Name + ': ' + ErrorMessage(ErrorCodeOf(Result)));
    Status := StatusCannotRun;
    Result := -1;
  end;
end;

{ Runs a shell function with Fields as its arguments. }
function CallFunction(Body: TShellNode; Fields: TStrings): LongInt;
var
  SavedPositionals: TStringArray;
  SavedLoopDepth: Integer;
begin
  SavedPositionals := SavePositionalParameters;
  SetPositionalParameters(StringsFrom(Fields, 1));
  BeginLocalScope;
  Inc(FunctionDepth);
  { break and continue do not reach loops outside the function. }
  SavedLoopDepth := LoopDepth;
  LoopDepth := 0;
  Result := ExecuteNode(Body);
  if ReturnRequested then
  begin
    Result := ReturnStatus;
    ReturnRequested := False;
  end;
  LoopControl := LoopControlNone;
  LoopDepth := SavedLoopDepth;
  Dec(FunctionDepth);
  EndLocalScope;
  RestorePositionalParameters(SavedPositionals);
end;

{ "exec" with only redirections makes them permanent. }
procedure MakeHandlesPermanent(const Handles: TStandardHandles);
var
  Index: Integer;
begin
  FlushStandardStreams;
  for Index := 0 to 2 do
    if Handles[Index] <> Index then
      DuplicateHandle(Handles[Index], Index);
end;

function RunInShell(Prepared: TPreparedCommand; const Handles: TStandardHandles): LongInt;
var
  Effective: TStandardHandles;
  Saved: TStandardHandles;
  Opened: TOpenedHandles;
begin
  if Prepared.Failed then
    Exit(HandleExpansionFailure);
  Effective := Handles;
  Opened := nil;
  if not ApplyRedirections(Prepared.Node.Redirections, Effective, Opened) then
  begin
    CloseOpenedHandles(Opened);
    Exit(1);
  end;
  if Prepared.Fields.Count = 0 then
  begin
    PerformAssignments(Prepared.Node);
    CloseOpenedHandles(Opened);
    { The status of the last command substitution, if any. }
    Exit(LastStatus);
  end;

  if Prepared.Fields[0] = 'exec' then
  begin
    MakeHandlesPermanent(Effective);
    CloseOpenedHandles(Opened);
    Exit(0);
  end;

  PerformAssignments(Prepared.Node);
  SwitchStandardHandles(Effective, Saved);
  if Prepared.FunctionBody <> nil then
    Result := CallFunction(Prepared.FunctionBody, Prepared.Fields)
  else
    Result := Prepared.Builtin(Prepared.Fields);
  RestoreStandardHandles(Saved);
  CloseOpenedHandles(Opened);
end;

end.

{
  Running parsed commands.

  External programs are started as new processes with the standard
  handles they should have (pipe ends, redirected files). Builtins and
  compound commands run inside the shell itself; for them the shell
  temporarily points its own standard handles at the right place.

  A pipeline is started in two passes so that no stage waits for one
  that has not started yet: first every external program, then the
  stages that run inside the shell, from left to right. Then the shell
  waits for the external programs. The status of a pipeline is the
  status of its last stage.

  An interactive shell runs every pipeline in a process group of its own;
  a foreground pipeline's group becomes the console's foreground group
  while the shell waits, so Ctrl-C ends exactly that pipeline. When a
  foreground program ends by Ctrl-C (status 130), the rest of the command
  line is abandoned. Ctrl-C pressed while the shell itself is busy (a loop
  of builtins) is noticed between commands.

  Functions run inside the shell with their own positional parameters and
  local variables; "return" unwinds to the call like "break" unwinds a
  loop. Here-documents reach the command through a pipe, or through a
  temporary file when they are larger than a pipe holds.
}
unit Shell.Execution;

{$mode objfpc}
{$pointermath on}

interface

uses
  Shell.Syntax;

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

function ExecuteNode(Node: PNode): LongInt;
{ Parses and runs Text; syntax errors give status 2. }
function ExecuteText(Text: PChar): LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Console,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Shell.Lexer,
  Shell.Variables,
  Shell.Expansion,
  Shell.Functions,
  Shell.Patterns,
  Shell.Builtins;

const
  ProgramPathCapacity = 1024;
  StatusNotFound = 127;
  StatusCannotRun = 126;
  StatusInterrupted = 130;
  { A here-document up to this size goes through a pipe (which holds
    4 KiB), a larger one through a temporary file. }
  HereDocumentPipeLimit = 4000;
  MaximumTemporaryFiles = 16;

type
  TStandardHandles = array[0..2] of Int64;

  { Files opened for the redirections of one command. }
  TOpenedHandles = record
    Handles: array[0..15] of Int64;
    Count: Integer;
  end;

  { A simple command after expansion. }
  TPreparedCommand = record
    Node: PNode;
    Fields: TFieldList;
    Builtin: TBuiltinRoutine;
    { The body if the command names a shell function. }
    FunctionBody: PNode;
    { "exec program": the shell ends with the program's status. }
    ExitAfterwards: Boolean;
    { An expansion failed; the command is not run. }
    Failed: Boolean;
  end;
  PPreparedCommand = ^TPreparedCommand;

var
  { Here-documents written to files, removed when the pipeline ends. }
  TemporaryFiles: array[0..MaximumTemporaryFiles - 1] of PChar;
  TemporaryFileCount: Integer = 0;
  TemporaryFileNumber: Integer = 0;

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
    WriteText(StandardError, '^C'#10);
  end;
end;

procedure RemoveTemporaryFiles;
var
  Index: Integer;
begin
  for Index := 0 to TemporaryFileCount - 1 do
  begin
    RemovePath(TemporaryFiles[Index]);
    FreeMemory(TemporaryFiles[Index]);
  end;
  TemporaryFileCount := 0;
end;

procedure ShellError(Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, 'sh: ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteCharacter(StandardError, #10);
end;

{ --- Standard handle switching --------------------------------------- }

{ Points the shell's handles 0-2 at Handles, remembering the old ones. }
procedure SwitchStandardHandles(const Handles: TStandardHandles; out Saved: TStandardHandles);
var
  Index: Integer;
begin
  FlushStandardStreams;
  for Index := 0 to 2 do
  begin
    Saved[Index] := NoHandle;
    if Handles[Index] <> Index then
    begin
      Saved[Index] := DuplicateHandle(Index, NoHandle);
      DuplicateHandle(Handles[Index], Index);
    end;
  end;
end;

procedure RestoreStandardHandles(const Saved: TStandardHandles);
var
  Index: Integer;
begin
  FlushStandardStreams;
  for Index := 0 to 2 do
  begin
    if Saved[Index] >= 0 then
    begin
      DuplicateHandle(Saved[Index], Index);
      CloseFile(Saved[Index]);
    end;
  end;
end;

{ --- Redirections ---------------------------------------------------- }

{ A handle from which the command reads the here-document's text. }
function OpenHereDocument(Redirection: PRedirection): Int64;
var
  Body: PChar;
  Length: PtrUInt;
  ReadHandle: Int64;
  WriteHandle: Int64;
  Directory: PChar;
  Builder: TTextBuilder;
  Path: PChar;
begin
  Result := -1;
  if Redirection^.HereBody = nil then
    Body := DuplicateText('')
  else if Redirection^.HereIsQuoted then
    Body := DuplicateText(Redirection^.HereBody)
  else
    Body := ExpandHereDocument(Redirection^.HereBody);
  Length := TextLength(Body);

  if Length <= HereDocumentPipeLimit then
  begin
    if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    begin
      ShellError('cannot create a pipe for a here-document', []);
      FreeMemory(Body);
      Exit;
    end;
    WriteAll(WriteHandle, Body, Length);
    CloseFile(WriteHandle);
    FreeMemory(Body);
    Exit(ReadHandle);
  end;

  Directory := LookupVariable('TMPDIR');
  if (Directory = nil) or (Directory^ = #0) then
    Directory := '/tmp';
  Inc(TemporaryFileNumber);
  BeginText(Builder);
  AppendText(Builder, Directory);
  AppendText(Builder, '/sh-here-');
  AppendDecimal(Builder, CurrentProcessId);
  AppendCharacter(Builder, '-');
  AppendDecimal(Builder, TemporaryFileNumber);
  Path := FinishText(Builder);
  WriteHandle := OpenFile(Path, OpenWrite or OpenCreate or OpenTruncate);
  if WriteHandle < 0 then
  begin
    ShellError('cannot create a file for a here-document: %s', [ArgumentText(ErrorMessage(ErrorCodeOf(WriteHandle)))]);
    FreeMemory(Path);
    FreeMemory(Body);
    Exit;
  end;
  WriteAll(WriteHandle, Body, Length);
  CloseFile(WriteHandle);
  FreeMemory(Body);
  Result := OpenFile(Path, OpenRead);
  if TemporaryFileCount < MaximumTemporaryFiles then
  begin
    TemporaryFiles[TemporaryFileCount] := Path;
    Inc(TemporaryFileCount);
  end
  else
    FreeMemory(Path);
end;

{ Applies the redirections of Node on top of Handles. Files opened here
  are added to Opened so they can be closed later. Returns False (after
  reporting) when a file cannot be opened. }
function ApplyRedirections(Node: PNode; var Handles: TStandardHandles; var Opened: TOpenedHandles): Boolean;
var
  Index: Integer;
  Redirection: PRedirection;
  Target: PChar;
  Flags: LongWord;
  Handle: Int64;
  SourceNumber: Int64;
begin
  Result := True;
  for Index := 0 to Node^.RedirectionCount - 1 do
  begin
    Redirection := @Node^.Redirections[Index];
    if (Redirection^.Handle < 0) or (Redirection^.Handle > 2) then
    begin
      ShellError('only handles 0, 1 and 2 can be redirected', []);
      Exit(False);
    end;
    if Redirection^.Kind = RedirectHereDocument then
    begin
      Handle := OpenHereDocument(Redirection);
      if Handle < 0 then
        Exit(False);
      Handles[Redirection^.Handle] := Handle;
      if Opened.Count < Length(Opened.Handles) then
      begin
        Opened.Handles[Opened.Count] := Handle;
        Inc(Opened.Count);
      end;
      Continue;
    end;
    Target := ExpandToText(Redirection^.Target);

    if Redirection^.Kind = RedirectDuplicate then
    begin
      if ParseInteger(Target, SourceNumber) and (SourceNumber >= 0) and (SourceNumber <= 2) then
        Handles[Redirection^.Handle] := Handles[SourceNumber]
      else
      begin
        ShellError('%s: bad redirection', [ArgumentText(Target)]);
        FreeMemory(Target);
        Exit(False);
      end;
      FreeMemory(Target);
      Continue;
    end;

    case Redirection^.Kind of
      RedirectInput: Flags := OpenRead;
      RedirectOutput: Flags := OpenWrite or OpenCreate or OpenTruncate;
    else
      Flags := OpenWrite or OpenCreate or OpenAppend;
    end;
    Handle := OpenFile(Target, Flags);
    if Handle < 0 then
    begin
      ShellError('%s: %s', [ArgumentText(Target), ArgumentText(ErrorMessage(ErrorCodeOf(Handle)))]);
      FreeMemory(Target);
      Exit(False);
    end;
    FreeMemory(Target);
    Handles[Redirection^.Handle] := Handle;
    if Opened.Count < Length(Opened.Handles) then
    begin
      Opened.Handles[Opened.Count] := Handle;
      Inc(Opened.Count);
    end;
  end;
end;

procedure CloseOpenedHandles(var Opened: TOpenedHandles);
var
  Index: Integer;
begin
  for Index := 0 to Opened.Count - 1 do
    CloseFile(Opened.Handles[Index]);
  Opened.Count := 0;
end;

{ --- Simple commands ------------------------------------------------- }

{ Drops the first field (for "exec program" and "command program"). }
procedure DropFirstField(var Fields: TFieldList);
var
  Index: Integer;
begin
  FreeMemory(Fields.Items[0]);
  for Index := 1 to Fields.Count do
    Fields.Items[Index - 1] := Fields.Items[Index];
  Dec(Fields.Count);
end;

procedure PrepareCommand(Node: PNode; out Prepared: TPreparedCommand);
var
  SkipFunctions: Boolean;
begin
  Prepared.Node := Node;
  Prepared.FunctionBody := nil;
  Prepared.ExitAfterwards := False;
  BeginFieldList(Prepared.Fields);
  ExpansionFailed := False;
  ExpandWords(Node^.Words, Node^.WordCount, Prepared.Fields);
  Prepared.Failed := ExpansionFailed;
  Prepared.Builtin := nil;
  if Prepared.Fields.Count = 0 then
    Exit;
  SkipFunctions := False;
  { "exec program ..." runs the program, then the shell ends. }
  if TextIsEqual(Prepared.Fields.Items[0], 'exec') and (Prepared.Fields.Count > 1) then
  begin
    DropFirstField(Prepared.Fields);
    Prepared.ExitAfterwards := True;
    Exit;
  end;
  { "command name ..." skips functions; "command -v" is a builtin. }
  if TextIsEqual(Prepared.Fields.Items[0], 'command') and (Prepared.Fields.Count > 1) and
     (Prepared.Fields.Items[1][0] <> '-') then
  begin
    DropFirstField(Prepared.Fields);
    SkipFunctions := True;
  end;
  if not SkipFunctions then
    Prepared.FunctionBody := FindFunction(Prepared.Fields.Items[0]);
  if Prepared.FunctionBody = nil then
    Prepared.Builtin := FindBuiltin(Prepared.Fields.Items[0]);
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

{ Runs a shell function with Fields as its arguments. }
function CallFunction(Body: PNode; const Fields: TFieldList): LongInt;
var
  SavedPositionals: TSavedPositionals;
  SavedLoopDepth: Integer;
begin
  SavePositionalParameters(SavedPositionals);
  SetPositionalParameters(Fields.Items + 1, Fields.Count - 1);
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

{ The environment for a program started with "NAME=value command". }
function BuildEnvironment(Node: PNode): PPChar;
var
  Block: PPChar;
  Count: Integer;
  Index: Integer;
  Value: PChar;
  Builder: TTextBuilder;
  EqualsPosition: PtrInt;
  Name: array[0..255] of Char;
  Existing: Integer;
begin
  if Node^.AssignmentCount = 0 then
    Exit(nil);
  Block := EnvironmentBlock;
  Count := EnvironmentCount;
  Result := PPChar(AllocateZeroedMemory(QWord(Count + Node^.AssignmentCount + 1) * SizeOf(PChar)));
  for Index := 0 to Count - 1 do
    Result[Index] := DuplicateText(Block[Index]);

  for Index := 0 to Node^.AssignmentCount - 1 do
  begin
    EqualsPosition := FindCharacter(Node^.Assignments[Index], '=');
    CopyText(@Name[0], Node^.Assignments[Index], PtrUInt(EqualsPosition) + 1);
    Value := ExpandToText(Node^.Assignments[Index] + EqualsPosition + 1);
    BeginText(Builder);
    AppendText(Builder, @Name[0]);
    AppendCharacter(Builder, '=');
    AppendText(Builder, Value);
    FreeMemory(Value);

    { Replace an existing entry of the same name. }
    Existing := 0;
    while (Existing < Count) and not (TextStartsWith(Result[Existing], @Name[0]) and
      (Result[Existing][EqualsPosition] = '=')) do
      Inc(Existing);
    if Existing < Count then
      FreeMemory(Result[Existing])
    else
      Inc(Count);
    Result[Existing] := FinishText(Builder);
  end;
end;

procedure FreeEnvironment(Environment: PPChar);
var
  Index: Integer;
begin
  if Environment = nil then
    Exit;
  Index := 0;
  while Environment[Index] <> nil do
  begin
    FreeMemory(Environment[Index]);
    Inc(Index);
  end;
  FreeMemory(Environment);
end;

{ Starts an external program; returns its process handle, or -1 after
  reporting a problem (Status tells which). }
function StartExternal(var Prepared: TPreparedCommand; const Handles: TStandardHandles;
  GroupId: Int64; out Status: LongInt): Int64;
var
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
  Effective: TStandardHandles;
  Opened: TOpenedHandles;
  Options: TProcessOptions;
  Environment: PPChar;
  Name: PChar;
begin
  Result := -1;
  Status := 0;
  Name := Prepared.Fields.Items[0];
  if not FindProgram(Name, @ProgramPath[0], ProgramPathCapacity) then
  begin
    ShellError('%s: command not found', [ArgumentText(Name)]);
    Status := StatusNotFound;
    Exit;
  end;

  Effective := Handles;
  Opened.Count := 0;
  if not ApplyRedirections(Prepared.Node, Effective, Opened) then
  begin
    CloseOpenedHandles(Opened);
    Status := 1;
    Exit;
  end;

  Environment := BuildEnvironment(Prepared.Node);
  DefaultProcessOptions(Options);
  Options.GroupId := GroupId;
  Options.Environment := Environment;
  Options.InputHandle := Effective[0];
  Options.OutputHandle := Effective[1];
  Options.ErrorHandle := Effective[2];
  FlushStandardStreams;
  Result := StartProgram(@ProgramPath[0], Prepared.Fields.Items, Options);
  FreeEnvironment(Environment);
  CloseOpenedHandles(Opened);

  if Result < 0 then
  begin
    ShellError('%s: %s', [ArgumentText(Name), ArgumentText(ErrorMessage(ErrorCodeOf(Result)))]);
    Status := StatusCannotRun;
    Result := -1;
  end;
end;

procedure PerformAssignments(Node: PNode);
var
  Index: Integer;
  EqualsPosition: PtrInt;
  Name: array[0..255] of Char;
  Value: PChar;
begin
  for Index := 0 to Node^.AssignmentCount - 1 do
  begin
    EqualsPosition := FindCharacter(Node^.Assignments[Index], '=');
    CopyText(@Name[0], Node^.Assignments[Index], PtrUInt(EqualsPosition) + 1);
    Value := ExpandToText(Node^.Assignments[Index] + EqualsPosition + 1);
    AssignVariable(@Name[0], Value);
    FreeMemory(Value);
  end;
end;

{ Runs a builtin, or a command consisting only of assignments and
  redirections, inside the shell. }
function RunInShell(var Prepared: TPreparedCommand; const Handles: TStandardHandles): LongInt;
var
  Effective: TStandardHandles;
  Saved: TStandardHandles;
  Opened: TOpenedHandles;
  Index: Integer;
begin
  if Prepared.Failed then
    Exit(HandleExpansionFailure);
  Effective := Handles;
  Opened.Count := 0;
  if not ApplyRedirections(Prepared.Node, Effective, Opened) then
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

  { "exec" with only redirections makes them permanent. }
  if TextIsEqual(Prepared.Fields.Items[0], 'exec') then
  begin
    FlushStandardStreams;
    for Index := 0 to 2 do
      if Effective[Index] <> Index then
        DuplicateHandle(Effective[Index], Index);
    CloseOpenedHandles(Opened);
    Exit(0);
  end;

  PerformAssignments(Prepared.Node);
  SwitchStandardHandles(Effective, Saved);
  if Prepared.FunctionBody <> nil then
    Result := CallFunction(Prepared.FunctionBody, Prepared.Fields)
  else
    Result := Prepared.Builtin(Prepared.Fields.Items, Prepared.Fields.Count);
  RestoreStandardHandles(Saved);
  CloseOpenedHandles(Opened);
end;

function RunsInShell(const Prepared: TPreparedCommand): Boolean;
begin
  Result := (Prepared.Fields.Count = 0) or (Prepared.Builtin <> nil) or (Prepared.FunctionBody <> nil) or
    Prepared.Failed;
end;

{ --- Pipelines ------------------------------------------------------- }

function ExecutePipeline(Children: PPNode; Count: Integer; Negate: Boolean; Wait: Boolean): LongInt;
var
  Prepared: PPreparedCommand;
  Processes: PInt64;
  Statuses: PLongInt;
  Inputs: PInt64;
  Outputs: PInt64;
  Index: Integer;
  ReadHandle: Int64;
  WriteHandle: Int64;
  Handles: TStandardHandles;
  Saved: TStandardHandles;
  IsInShell: PBoolean;
  PipelineGroup: Int64;
  OwnsConsole: Boolean;
begin
  Prepared := PPreparedCommand(AllocateZeroedMemory(QWord(Count) * SizeOf(TPreparedCommand)));
  Processes := PInt64(AllocateZeroedMemory(QWord(Count) * SizeOf(Int64)));
  Statuses := PLongInt(AllocateZeroedMemory(QWord(Count) * SizeOf(LongInt)));
  Inputs := PInt64(AllocateZeroedMemory(QWord(Count) * SizeOf(Int64)));
  Outputs := PInt64(AllocateZeroedMemory(QWord(Count) * SizeOf(Int64)));
  IsInShell := PBoolean(AllocateZeroedMemory(QWord(Count) * SizeOf(Boolean)));

  { Connect the stages. }
  Inputs[0] := StandardInputHandle;
  Outputs[Count - 1] := StandardOutputHandle;
  for Index := 0 to Count - 2 do
  begin
    if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    begin
      ShellError('cannot create a pipe', []);
      ReadHandle := StandardInputHandle;
      WriteHandle := StandardOutputHandle;
    end;
    Outputs[Index] := WriteHandle;
    Inputs[Index + 1] := ReadHandle;
  end;

  { Expand every simple command; anything else runs in the shell. }
  for Index := 0 to Count - 1 do
  begin
    Processes[Index] := -1;
    if Children[Index]^.Kind = NodeSimple then
    begin
      PrepareCommand(Children[Index], Prepared[Index]);
      IsInShell[Index] := RunsInShell(Prepared[Index]);
    end
    else
    begin
      BeginFieldList(Prepared[Index].Fields);
      IsInShell[Index] := True;
    end;
  end;

  { Pass 1: external programs. In an interactive shell they form a new
    process group, led by the first. }
  PipelineGroup := GroupInherit;
  if ShellIsInteractive then
    PipelineGroup := GroupNew;
  for Index := 0 to Count - 1 do
  begin
    if IsInShell[Index] then
      Continue;
    Handles[0] := Inputs[Index];
    Handles[1] := Outputs[Index];
    Handles[2] := StandardErrorHandle;
    Processes[Index] := StartExternal(Prepared[Index], Handles, PipelineGroup, Statuses[Index]);
    if (PipelineGroup = GroupNew) and (Processes[Index] >= 0) then
      PipelineGroup := ProcessIdOf(Processes[Index]);
  end;
  { Ctrl-C now belongs to the pipeline. }
  OwnsConsole := Wait and ShellIsInteractive and (PipelineGroup > 0) and IsConsole(StandardInputHandle);
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, PipelineGroup);
  { The shell keeps only the pipe ends that in-shell stages still need,
    so readers see the end of their input when the writers finish. }
  for Index := 0 to Count - 1 do
  begin
    if IsInShell[Index] then
      Continue;
    if Inputs[Index] <> StandardInputHandle then
      CloseFile(Inputs[Index]);
    if Outputs[Index] <> StandardOutputHandle then
      CloseFile(Outputs[Index]);
  end;

  { Pass 2: stages inside the shell, left to right. }
  for Index := 0 to Count - 1 do
  begin
    if not IsInShell[Index] then
      Continue;
    Handles[0] := Inputs[Index];
    Handles[1] := Outputs[Index];
    Handles[2] := StandardErrorHandle;
    if Children[Index]^.Kind = NodeSimple then
      Statuses[Index] := RunInShell(Prepared[Index], Handles)
    else
    begin
      SwitchStandardHandles(Handles, Saved);
      Statuses[Index] := ExecuteNode(Children[Index]);
      RestoreStandardHandles(Saved);
    end;
    if Inputs[Index] <> StandardInputHandle then
      CloseFile(Inputs[Index]);
    if Outputs[Index] <> StandardOutputHandle then
      CloseFile(Outputs[Index]);
  end;

  for Index := 0 to Count - 1 do
  begin
    if Processes[Index] < 0 then
      Continue;
    if Wait then
    begin
      Statuses[Index] := WaitForProgram(Processes[Index]);
      if ShellIsInteractive and (Statuses[Index] = StatusInterrupted) then
        InterruptRequested := True;
      if Prepared[Index].ExitAfterwards then
      begin
        ExitRequested := True;
        RequestedExitCode := Statuses[Index];
      end;
    end
    else
      { A background program keeps running on its own. }
      CloseFile(Processes[Index]);
  end;
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, CurrentProcessGroup);

  Result := Statuses[Count - 1];
  if Negate then
    Result := Ord(Result = 0);

  for Index := 0 to Count - 1 do
    FreeFieldList(Prepared[Index].Fields);
  if Wait then
    RemoveTemporaryFiles;
  FreeMemory(Prepared);
  FreeMemory(Processes);
  FreeMemory(Statuses);
  FreeMemory(Inputs);
  FreeMemory(Outputs);
  FreeMemory(IsInShell);
end;

{ --- Compound commands ----------------------------------------------- }

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

function ExecuteLoop(Node: PNode): LongInt;
var
  ConditionStatus: LongInt;
begin
  Result := 0;
  Inc(LoopDepth);
  while True do
  begin
    ConditionStatus := ExecuteNode(Node^.Condition);
    if LeaveLoopBody then
    begin
      if LoopMustStop then
        Break;
      Continue;
    end;
    if (ConditionStatus = 0) = Node^.IsUntil then
      Break;
    Result := ExecuteNode(Node^.Body);
    if LeaveLoopBody and LoopMustStop then
      Break;
  end;
  Dec(LoopDepth);
end;

function ExecuteFor(Node: PNode): LongInt;
var
  Values: TFieldList;
  Index: Integer;
begin
  Result := 0;
  BeginFieldList(Values);
  if Node^.Words = nil then
  begin
    for Index := 1 to PositionalCount do
      AddField(Values, PositionalParameter(Index));
  end
  else
    ExpandWords(Node^.Words, Node^.WordCount, Values);

  Inc(LoopDepth);
  for Index := 0 to Values.Count - 1 do
  begin
    AssignVariable(Node^.VariableName, Values.Items[Index]);
    Result := ExecuteNode(Node^.Body);
    if LeaveLoopBody and LoopMustStop then
      Break;
  end;
  Dec(LoopDepth);
  FreeFieldList(Values);
end;

function ExecuteCase(Node: PNode): LongInt;
var
  Subject: PChar;
  ItemIndex: Integer;
  PatternIndex: Integer;
  Item: PNode;
  Pattern: PChar;
  Matched: Boolean;
begin
  Result := 0;
  Subject := ExpandToText(Node^.Words[0]);
  for ItemIndex := 0 to Node^.ChildCount - 1 do
  begin
    Item := Node^.Children[ItemIndex];
    Matched := False;
    for PatternIndex := 0 to Item^.WordCount - 1 do
    begin
      Pattern := ExpandToPattern(Item^.Words[PatternIndex]);
      Matched := MatchPattern(Pattern, Subject);
      FreeMemory(Pattern);
      if Matched then
        Break;
    end;
    if Matched then
    begin
      Result := ExecuteNode(Item^.Body);
      Break;
    end;
  end;
  FreeMemory(Subject);
end;

{ A compound command with redirections: the shell's own handles point
  at the files while it runs. }
function ExecuteRedirected(Node: PNode): LongInt;
var
  Handles: TStandardHandles;
  Saved: TStandardHandles;
  Opened: TOpenedHandles;
  Index: Integer;
begin
  for Index := 0 to 2 do
    Handles[Index] := Index;
  Opened.Count := 0;
  if not ApplyRedirections(Node, Handles, Opened) then
  begin
    CloseOpenedHandles(Opened);
    Exit(1);
  end;
  SwitchStandardHandles(Handles, Saved);
  Result := ExecuteNode(Node^.Body);
  RestoreStandardHandles(Saved);
  CloseOpenedHandles(Opened);
end;

function ExecuteSequence(Node: PNode): LongInt;
var
  Index: Integer;
  Child: PNode;
begin
  Result := 0;
  for Index := 0 to Node^.ChildCount - 1 do
  begin
    Child := Node^.Children[Index];
    if Node^.RunInBackground[Index] then
    begin
      if Child^.Kind = NodePipeline then
        Result := ExecutePipeline(Child^.Children, Child^.ChildCount, False, False)
      else
        Result := ExecutePipeline(@Node^.Children[Index], 1, False, False);
      LastStatus := 0;
    end
    else
      Result := ExecuteNode(Child);
    CheckPendingInterrupt;
    if Unwinding then
      Break;
  end;
end;

function ExecuteNode(Node: PNode): LongInt;
begin
  if Node = nil then
    Exit(0);
  case Node^.Kind of
    NodeSimple:
      Result := ExecutePipeline(@Node, 1, False, True);
    NodePipeline:
      Result := ExecutePipeline(Node^.Children, Node^.ChildCount, Node^.Negate, True);
    NodeAndOr:
      begin
        Result := ExecuteNode(Node^.Left);
        if not Unwinding then
        begin
          if (Node^.AndOrOperator = OperatorAnd) and (Result = 0) then
            Result := ExecuteNode(Node^.Right)
          else if (Node^.AndOrOperator = OperatorOr) and (Result <> 0) then
            Result := ExecuteNode(Node^.Right);
        end;
      end;
    NodeSequence:
      Result := ExecuteSequence(Node);
    NodeIf:
      begin
        Result := ExecuteNode(Node^.Condition);
        if Unwinding then
          Exit;
        if Result = 0 then
          Result := ExecuteNode(Node^.Body)
        else if Node^.ElseBody <> nil then
          Result := ExecuteNode(Node^.ElseBody)
        else
          Result := 0;
      end;
    NodeLoop:
      Result := ExecuteLoop(Node);
    NodeFor:
      Result := ExecuteFor(Node);
    NodeCase:
      Result := ExecuteCase(Node);
    NodeFunction:
      begin
        DefineFunction(Node);
        Result := 0;
      end;
    NodeRedirected:
      Result := ExecuteRedirected(Node);
  else
    Result := 1;
  end;
  LastStatus := Result;
end;

function ExecuteText(Text: PChar): LongInt;
var
  Tree: PNode;
  Message: PChar;
begin
  case ParseInput(Text, Tree, Message) of
    ParseSuccess:
      begin
        Result := ExecuteNode(Tree);
        FreeNode(Tree);
      end;
    ParseIncomplete:
      begin
        ShellError('syntax error: unexpected end of input', []);
        Result := 2;
      end;
  else
    begin
      ShellError('%s', [ArgumentText(Message)]);
      Result := 2;
    end;
  end;
  LastStatus := Result;
end;

end.

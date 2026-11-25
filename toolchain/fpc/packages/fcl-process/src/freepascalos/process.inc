{
    FreePascalOS
    Copyright (C) 2026 Brandon Scott

    The FreePascalOS part of TProcess (fcl-process): programs are
    started by the kernel (Sys.Processes.StartProgram) with the standard
    handles they are given - the pipes of poUsePipes, /dev/null for
    poNoConsole - and a process handle the parent waits on. Part of the
    FreePascalOS patches to Free Pascal.

    See the file COPYING.FPC, included in the Free Pascal distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 **********************************************************************}

uses
  Abi.SystemCalls, Sys.Processes;

type
  TPCharArray = array of PChar;

Resourcestring
  SNoCommandLine        = 'Cannot execute empty command-line';
  SErrNoSuchProgram     = 'Executable not found: "%s"';
  SErrCannotExecute     = 'Failed to execute %s : %d';
  SErrCannotCreatePipes = 'Failed to create pipes';

procedure TProcess.CloseProcessHandles;
begin
  if FProcessHandle <> 0 then
    begin
    FileClose(FProcessHandle);
    FProcessHandle := 0;
    end;
end;

{ True (with FExitCode) once the program has ended; the handle stays
  open, so it can be asked again. }
Function TProcess.PeekExitStatus : Boolean;
var
  Code: LongInt;
begin
  Result := WaitForProgramWithTimeout(FProcessHandle, 0, Code) = ErrorNone;
  if Result then
    FExitCode := Cardinal(Code)
  else
    FExitCode := Cardinal(-1);
end;

{ The program and its arguments, as the other platforms take them:
  Executable and Parameters, or else the (deprecated) CommandLine or
  ApplicationName split into words. }
procedure MakeArguments(P : TProcess; Words : TStrings);
begin
  If (P.ApplicationName='') and (P.CommandLine='') and (P.Executable='') then
    Raise EProcess.Create(SNoCommandline);
  if (P.ApplicationName='') and (P.CommandLine='') then
    begin
    Words.Assign(P.Parameters);
    Words.Insert(0,P.Executable);
    end
  else if P.CommandLine='' then
    CommandToList(P.ApplicationName,Words)
  else
    CommandToList(P.CommandLine,Words);
end;

{ A nil terminated list of PChars into Strings, which must outlive it. }
function MakePCharList(Strings : TStrings) : TPCharArray;
var
  Index : Integer;
begin
  Result := nil;
  SetLength(Result, Strings.Count + 1);
  for Index := 0 to Strings.Count - 1 do
    Result[Index] := PChar(Strings[Index]);
  Result[Strings.Count] := nil;
end;

{ A program named without a folder is looked for in PATH (and the
  program folders), as the shell does. }
function ResolveProgramPath(const Name : String) : String;
begin
  Result := '';
  if Pos('/', Name) > 0 then
    begin
    if FileExists(Name) then
      Result := Name;
    end
  else if not FindProgramPath(Name, Result) then
    Result := '';
  if Result = '' then
    raise EProcess.CreateFmt(SErrNoSuchProgram, [Name]);
end;

Procedure TProcess.Execute;
var
  Words : TStringList;
  Arguments, EnvironmentList : TPCharArray;
  StartOptions : Sys.Processes.TProcessOptions;
  ProgramPath : String;
  InputRead, InputWrite, OutputRead, OutputWrite, ErrorRead, ErrorWrite : Int64;
  NullHandle : THandle;
  StartedHandle : Int64;
  UsePipes, PassInput, ErrorToOutput : Boolean;
begin
  UsePipes := poUsePipes in Options;
  PassInput := poPassInput in Options;
  ErrorToOutput := poStderrToOutPut in Options;
  InputRead := -1;
  InputWrite := -1;
  OutputRead := -1;
  OutputWrite := -1;
  ErrorRead := -1;
  ErrorWrite := -1;
  NullHandle := THandle(UnusedHandle);
  Words := TStringList.Create;
  try
    MakeArguments(Self, Words);
    ProgramPath := ResolveProgramPath(Words[0]);
    Arguments := MakePCharList(Words);

    DefaultProcessOptions(StartOptions);
    EnvironmentList := nil;
    if FEnvironment.Count > 0 then
      begin
      EnvironmentList := MakePCharList(FEnvironment);
      StartOptions.Environment := @EnvironmentList[0];
      end;
    if FCurrentDirectory <> '' then
      StartOptions.WorkingDirectory := PChar(FCurrentDirectory);

    if UsePipes then
      begin
      if (not PassInput and (CreatePipe(InputRead, InputWrite) <> ErrorNone)) or
         (CreatePipe(OutputRead, OutputWrite) <> ErrorNone) or
         (not ErrorToOutput and (CreatePipe(ErrorRead, ErrorWrite) <> ErrorNone)) then
        raise EProcess.Create(SErrCannotCreatePipes);
      if not PassInput then
        StartOptions.InputHandle := InputRead;
      StartOptions.OutputHandle := OutputWrite;
      if ErrorToOutput then
        StartOptions.ErrorHandle := OutputWrite
      else
        StartOptions.ErrorHandle := ErrorWrite;
      end
    else if poNoConsole in Options then
      begin
      NullHandle := FileOpen('/dev/null', fmOpenReadWrite or fmShareDenyNone);
      if NullHandle <> THandle(UnusedHandle) then
        begin
        StartOptions.InputHandle := NullHandle;
        StartOptions.OutputHandle := NullHandle;
        StartOptions.ErrorHandle := NullHandle;
        end;
      end;

    StartedHandle := StartProgram(PChar(ProgramPath), @Arguments[0], StartOptions);
    if StartedHandle < 0 then
      raise EProcess.CreateFmt(SErrCannotExecute, [ProgramPath, -StartedHandle]);
    FProcessHandle := THandle(StartedHandle);
    FThreadHandle := FProcessHandle;
    FProcessID := Integer(ProcessIdOf(StartedHandle));
    if poRunSuspended in Options then
      StopPrograms(FProcessID);
  finally
    { the program has its own copies of the ends it was given }
    if NullHandle <> THandle(UnusedHandle) then
      FileClose(NullHandle);
    if InputRead >= 0 then
      FileClose(InputRead);
    if OutputWrite >= 0 then
      FileClose(OutputWrite);
    if ErrorWrite >= 0 then
      FileClose(ErrorWrite);
    Words.Free;
  end;
  if UsePipes then
    CreateStreams(InputWrite, OutputRead, ErrorRead);
  FRunning := True;
  if not (csDesigning in ComponentState) and // This would hang the IDE !
     (poWaitOnExit in FProcessOptions) and
     not (poRunSuspended in FProcessOptions) then
    WaitOnExit;
end;

Function TProcess.WaitOnExit : Boolean;
var
  Code: LongInt;
begin
  if FRunning then
    begin
    if WaitForProgramWithTimeout(FProcessHandle, QWord(InfiniteWait), Code) = ErrorNone then
      FExitCode := Cardinal(Code)
    else
      FExitCode := Cardinal(-1);
    end;
  Result := LongInt(FExitCode) >= 0;
  FRunning := False;
end;

Function TProcess.WaitOnExit(Timeout : DWord) : Boolean;
var
  Code: LongInt;
begin
  Result := WaitForProgramWithTimeout(FProcessHandle, Timeout, Code) = ErrorNone;
  if Result then
    begin
    FExitCode := Cardinal(Code);
    FRunning := False;
    end
  else
    FExitCode := Cardinal(-1);
end;

Function TProcess.Suspend : Longint;
begin
  If StopPrograms(FProcessID) <> ErrorNone then
    Result:=-1
  else
    Result:=1;
end;

Function TProcess.Resume : LongInt;
begin
  If ContinuePrograms(FProcessID) <> ErrorNone then
    Result:=-1
  else
    Result:=0;
end;

Function TProcess.Terminate(AExitCode : Integer) : Boolean;
begin
  Result := TerminateProgram(FProcessID, AExitCode) = ErrorNone;
  { the request does not end the program at once: wait for it }
  if Result then
    WaitOnExit;
end;

Procedure TProcess.SetShowWindow (Value : TShowWindowOptions);
begin
  FShowWindow:=Value;
end;

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
  Starting and waiting for other programs.

  A program is started with an argument list, an environment, an
  optional working directory and the three standard handles it should
  receive. Bare program names (without a '/') are looked up in the
  directories listed in the PATH variable.
}
unit Sys.Processes;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

type
  TProcessOptions = record
    Environment: PPChar;       { nil = this program's environment }
    WorkingDirectory: PChar;   { nil = this program's directory }
    InputHandle: Int64;
    OutputHandle: Int64;
    ErrorHandle: Int64;
    { GroupInherit, GroupNew or the id of a group to join. }
    GroupId: Int64;
    { nil: this program's user. Otherwise the user to start it as (root
      only; see TAbiProcessIdentity). }
    Identity: PAbiProcessIdentity;
    { The program leads a session of its own (ProcessNewSession), which
      EndSession ends as a whole. }
    NewSession: Boolean;
  end;

{ Options with the standard handles and environment of this program. }
procedure DefaultProcessOptions(out Options: TProcessOptions);

{ Finds Name in PATH (or takes it as a path if it contains '/'); False
  (and Path empty) if it is not there. }
function FindProgramPath(const Name: string; out Path: string): Boolean;

{ Starts a program; returns a process handle or a negative error. }
function StartProgram(Path: PChar; Arguments: PPChar; const Options: TProcessOptions): Int64;
{ Waits for a started program and returns its exit code (or a negative
  error). The handle is closed. }
function WaitForProgram(ProcessHandle: Int64): LongInt;
{ Waits at most Milliseconds. Returns 0 with ExitCode set when the
  program ended, else ErrorTimedOut (or another error). The handle stays
  open. }
function WaitForProgramWithTimeout(ProcessHandle: Int64; Milliseconds: QWord;
  out ExitCode: LongInt): LongInt;
{ Job control. Waits at most Milliseconds (or InfiniteWait) for the
  program to end or stop. Returns ErrorNone with Stopped set, or with
  ExitCode set when it ended; else ErrorTimedOut or another error. A stop
  is reported once. The handle stays open. }
function WaitForProgramChange(ProcessHandle: Int64; Milliseconds: Int64;
  out Stopped: Boolean; out ExitCode: LongInt): LongInt;
{ Stop or continue a program (Target > 0), a process group (-group) or
  this program's own group (0). Return 0 or an error code. }
function StopPrograms(Target: Int64): LongInt;
function ContinuePrograms(Target: Int64): LongInt;

{ The process id of a started program. }
function ProcessIdOf(ProcessHandle: Int64): Int64;
{ Asks a running program to end with ExitCode (by convention 128 plus a
  signal number). Returns 0 or an error code. }
function TerminateProgram(ProcessId: QWord; ExitCode: LongInt): LongInt;
{ Makes Path this program's "/" (and current directory). }
function ChangeRootDirectory(Path: PChar): LongInt;
{ Starts a program and waits for it. }
function RunProgram(Path: PChar; Arguments: PPChar): LongInt;

function CurrentProcessId: Int64;
{ The process group, which Ctrl-C on the console ends as a whole. }
function CurrentProcessGroup: Int64;
{ With True, Ctrl-C on the console no longer ends this program. }
procedure IgnoreInterrupts(Ignore: Boolean);
procedure SleepMilliseconds(Milliseconds: QWord);
procedure ExitProgram(Code: LongInt);

function CreatePipe(out ReadHandle, WriteHandle: Int64): LongInt;
function DuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;

{ Ends every process of session SessionId (the id of the process that
  leads it) but this one, at once, with ExitCode; returns how many, or
  minus an error. (Sys.Notifications.AskSessionToEnd asks them first.) }
function EndSession(SessionId: QWord; ExitCode: LongInt): Int64;
{ The session process ProcessId belongs to; False if there is no such
  process. }
function SessionOfProcess(ProcessId: QWord; out SessionId: QWord): Boolean;
{ True while a process of session SessionId runs (other than this one). }
function SessionHasProcesses(SessionId: QWord): Boolean;
{ How many processes of session SessionId run (other than this one). }
function CountSessionProcesses(SessionId: QWord): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors,
  Sys.Files,
  Sys.Environment,
  Sys.Text;

procedure DefaultProcessOptions(out Options: TProcessOptions);
begin
  Options.Environment := nil;
  Options.WorkingDirectory := nil;
  Options.InputHandle := StandardInputHandle;
  Options.OutputHandle := StandardOutputHandle;
  Options.ErrorHandle := StandardErrorHandle;
  Options.GroupId := GroupInherit;
  Options.Identity := nil;
  Options.NewSession := False;
end;

function IsProgramFile(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetFileInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = KindFile);
end;

function FindProgramPath(const Name: string; out Path: string): Boolean;
var
  SearchPath: string;
  Directory: string;
  Start: Integer;
  Finish: Integer;
  Information: TFileInformation;
begin
  Path := '';
  if Name = '' then
    Exit(False);
  if Pos('/', Name) > 0 then
  begin
    Result := GetFileInformation(PChar(Name), Information) = ErrorNone;
    if Result then
      Path := Name;
    Exit;
  end;

  if GetVariable('PATH') <> nil then
    SearchPath := GetVariable('PATH')
  else
    SearchPath := '/bin';

  Start := 1;
  while Start <= Length(SearchPath) + 1 do
  begin
    Finish := Start;
    while (Finish <= Length(SearchPath)) and (SearchPath[Finish] <> ':') do
      Inc(Finish);
    Directory := Copy(SearchPath, Start, Finish - Start);
    if (Directory <> '') and IsProgramFile(Directory + '/' + Name) then
    begin
      Path := Directory + '/' + Name;
      Exit(True);
    end;
    Start := Finish + 1;
  end;
  Result := False;
end;

function StartProgram(Path: PChar; Arguments: PPChar; const Options: TProcessOptions): Int64;
var
  Creation: TAbiProcessCreation;
begin
  Creation.Path := Path;
  Creation.Arguments := Arguments;
  if Options.Environment <> nil then
    Creation.Environment := Options.Environment
  else
    Creation.Environment := EnvironmentBlock;
  Creation.WorkingDirectory := Options.WorkingDirectory;
  Creation.InputHandle := Options.InputHandle;
  Creation.OutputHandle := Options.OutputHandle;
  Creation.ErrorHandle := Options.ErrorHandle;
  Creation.GroupId := Options.GroupId;
  Creation.Identity := Options.Identity;
  if Options.NewSession then
    Creation.Flags := ProcessNewSession
  else
    Creation.Flags := 0;
  Result := KernelCreateProcess(Creation);
end;

function WaitForProgram(ProcessHandle: Int64): LongInt;
var
  WaitResult: Int64;
begin
  WaitResult := KernelWaitForProcess(ProcessHandle, InfiniteWait);
  KernelClose(ProcessHandle);
  Result := LongInt(WaitResult);
end;

function RunProgram(Path: PChar; Arguments: PPChar): LongInt;
var
  Options: TProcessOptions;
  Handle: Int64;
begin
  DefaultProcessOptions(Options);
  Handle := StartProgram(Path, Arguments, Options);
  if Handle < 0 then
    Exit(LongInt(Handle));
  Result := WaitForProgram(Handle);
end;

function WaitForProgramWithTimeout(ProcessHandle: Int64; Milliseconds: QWord;
  out ExitCode: LongInt): LongInt;
var
  WaitResult: Int64;
begin
  ExitCode := 0;
  WaitResult := KernelWaitForProcess(ProcessHandle, Int64(Milliseconds));
  if WaitResult < 0 then
    Exit(ErrorCodeOf(WaitResult));
  ExitCode := LongInt(WaitResult);
  Result := ErrorNone;
end;

function WaitForProgramChange(ProcessHandle: Int64; Milliseconds: Int64;
  out Stopped: Boolean; out ExitCode: LongInt): LongInt;
var
  WaitResult: Int64;
begin
  Stopped := False;
  ExitCode := 0;
  WaitResult := KernelWaitForProcessChange(ProcessHandle, Milliseconds);
  if WaitResult < 0 then
    Exit(ErrorCodeOf(WaitResult));
  if WaitResult = WaitStatusStopped then
    Stopped := True
  else
    ExitCode := LongInt(WaitResult);
  Result := ErrorNone;
end;

function StopPrograms(Target: Int64): LongInt;
var
  CallResult: Int64;
begin
  CallResult := KernelStopProcesses(Target);
  if CallResult < 0 then
    Exit(ErrorCodeOf(CallResult));
  Result := ErrorNone;
end;

function ContinuePrograms(Target: Int64): LongInt;
var
  CallResult: Int64;
begin
  CallResult := KernelContinueProcesses(Target);
  if CallResult < 0 then
    Exit(ErrorCodeOf(CallResult));
  Result := ErrorNone;
end;

function ProcessIdOf(ProcessHandle: Int64): Int64;
begin
  Result := KernelGetProcessId(ProcessHandle);
end;

function TerminateProgram(ProcessId: QWord; ExitCode: LongInt): LongInt;
begin
  Result := ErrorCodeOf(KernelTerminateProcess(ProcessId, ExitCode));
end;

function ChangeRootDirectory(Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelSetRootDirectory(Path));
end;

function CurrentProcessId: Int64;
begin
  Result := KernelGetProcessId(NoHandle);
end;

function CurrentProcessGroup: Int64;
begin
  Result := KernelGetProcessGroup;
end;

procedure IgnoreInterrupts(Ignore: Boolean);
begin
  KernelSetInterruptIgnored(Ignore);
end;

procedure SleepMilliseconds(Milliseconds: QWord);
begin
  KernelSleep(Milliseconds);
end;

procedure ExitProgram(Code: LongInt);
begin
  Halt(Code);
end;

function CreatePipe(out ReadHandle, WriteHandle: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelCreatePipe(ReadHandle, WriteHandle));
end;

function DuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;
begin
  Result := KernelDuplicateHandle(Handle, NewHandle);
end;

function EndSession(SessionId: QWord; ExitCode: LongInt): Int64;
begin
  Result := KernelTerminateSession(SessionId, ExitCode);
end;

function SessionOfProcess(ProcessId: QWord; out SessionId: QWord): Boolean;
var
  Information: TAbiProcessInformation;
  Index: QWord;
begin
  SessionId := 0;
  Index := 0;
  while KernelListProcesses(Index, Information) >= 0 do
  begin
    if Information.ProcessId = ProcessId then
    begin
      SessionId := Information.SessionId;
      Exit(True);
    end;
    Inc(Index);
  end;
  Result := False;
end;

function SessionHasProcesses(SessionId: QWord): Boolean;
begin
  Result := CountSessionProcesses(SessionId) > 0;
end;

function CountSessionProcesses(SessionId: QWord): LongInt;
var
  Information: TAbiProcessInformation;
  Index: QWord;
  Own: QWord;
begin
  Result := 0;
  Own := QWord(CurrentProcessId);
  Index := 0;
  while KernelListProcesses(Index, Information) >= 0 do
  begin
    if (Information.SessionId = SessionId) and (Information.ProcessId <> Own) and
       (Information.State <> ProcessStateExiting) then
      Inc(Result);
    Inc(Index);
  end;
end;

end.

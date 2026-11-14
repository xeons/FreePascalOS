{
  Starting and waiting for other programs.

  A program is started with an argument list, an environment, an
  optional working directory and the three standard handles it should
  receive. Bare program names (without a '/') are looked up in the
  directories listed in the PATH variable.
}
unit Sys.Processes;

{$mode objfpc}
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
  end;

{ Options with the standard handles and environment of this program. }
procedure DefaultProcessOptions(out Options: TProcessOptions);

{ Finds Name in PATH (or takes it as a path if it contains '/'). The
  result is written to FullPath. }
function FindProgram(Name: PChar; FullPath: PChar; Capacity: PtrUInt): Boolean;

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
procedure SleepMilliseconds(Milliseconds: QWord);
procedure ExitProgram(Code: LongInt);

function CreatePipe(out ReadHandle, WriteHandle: Int64): LongInt;
function DuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;

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
end;

function FindProgram(Name: PChar; FullPath: PChar; Capacity: PtrUInt): Boolean;
var
  SearchPath: PChar;
  Start: PtrUInt;
  Finish: PtrUInt;
  Length: PtrUInt;
  Information: TFileInformation;
begin
  Result := False;
  if (Name = nil) or (Name^ = #0) then
    Exit;
  if FindCharacter(Name, '/') >= 0 then
  begin
    CopyText(FullPath, Name, Capacity);
    Exit(GetFileInformation(FullPath, Information) = ErrorNone);
  end;

  SearchPath := GetVariable('PATH');
  if SearchPath = nil then
    SearchPath := '/bin';

  Start := 0;
  repeat
    Finish := Start;
    while (SearchPath[Finish] <> ':') and (SearchPath[Finish] <> #0) do
      Inc(Finish);
    Length := Finish - Start;
    if (Length > 0) and (Length + TextLength(Name) + 2 < Capacity) then
    begin
      CopyMemory(FullPath, SearchPath + Start, Length);
      FullPath[Length] := '/';
      CopyText(FullPath + Length + 1, Name, Capacity - Length - 1);
      if (GetFileInformation(FullPath, Information) = ErrorNone) and (Information.Kind = KindFile) then
        Exit(True);
    end;
    Start := Finish + 1;
  until SearchPath[Finish] = #0;
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

end.

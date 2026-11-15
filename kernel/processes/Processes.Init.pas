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
  Starting the first user program.

  After startup the kernel runs one program in user mode: the one named
  by the kernel option "init=" (a path in the system volume), or /bin/sh
  when no option is given. It gets the console as its standard input,
  output and error, a small default environment, and "/" as its current
  directory. The kernel waits for it to finish.
}
unit Processes.Init;

{$mode objfpc}

interface

const
  InitialProgramNotStarted = -1;

{ Runs the initial program and returns its exit code, or
  InitialProgramNotStarted. }
function RunInitialProgram: LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Options,
  Kernel.Scheduler,
  Objects.Manager,
  Io.Console,
  Io.LineDiscipline,
  Io.Manager,
  Io.DeviceFiles,
  FileSystem.Types,
  FileSystem.Files,
  Processes.Process,
  Processes.Handles,
  Processes.Paths,
  Processes.UserProcess,
  Processes.Security,
  Debug.Output;

const
  DefaultInitialProgram = '/bin/sh';
  ProgramPathCapacity = 256;

  DefaultEnvironment: array[0..3] of PChar = (
    'PATH=/bin',
    'HOME=/',
    'TERM=console',
    'SHELL=/bin/sh');

{ "/bin/coretest" -> "coretest" }
function ProgramFileName(Path: PChar): PChar;
var
  Index: PtrUInt;
begin
  Result := Path;
  Index := 0;
  while Path[Index] <> #0 do
  begin
    if Path[Index] = '/' then
      Result := @Path[Index + 1];
    Inc(Index);
  end;
end;

procedure Report(Message: PChar; Detail: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('init');
  DebugWrite(Message);
  DebugWriteLine(Detail);
  DebugEndMessage;
end;

function RunInitialProgram: LongInt;
var
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  Arguments: array[0..0] of PChar;
  Startup: TProcessStartup;
  Information: TNodeInformation;
  Process: PProcess;
  Error: LongInt;
  StandardIndex: Integer;
  Console: PDeviceObject;
  ConsoleFile: PDeviceFile;
begin
  Result := InitialProgramNotStarted;
  if not SelectSystemVolume then
  begin
    Report('No system volume (labelled ', SystemVolumeLabel + ' or named by root=); user mode not started');
    Exit;
  end;
  Report('System volume: /', SystemVolumeName);

  if not GetKernelOptionValue('init', @ProgramPath[0], ProgramPathCapacity) then
    CopyText(@ProgramPath[0], DefaultInitialProgram, ProgramPathCapacity);

  SystemVolumePath(@ProgramPath[0], @KernelPath[0], ProcessPathCapacity);
  if GetPathInformation(@KernelPath[0], Information) <> StatusSuccess then
  begin
    Report('Initial program not found: ', @ProgramPath[0]);
    Exit;
  end;

  Arguments[0] := @ProgramPath[0];
  FillMemory(@Startup, SizeOf(Startup), 0);
  { The first program runs as root; from here on files are checked. }
  GetRootCredentials(Startup.Credentials);
  InitializeProcessSecurity;
  Startup.KernelPath := @KernelPath[0];
  Startup.Name := ProgramFileName(@ProgramPath[0]);
  Startup.Arguments := @Arguments[0];
  Startup.ArgumentCount := 1;
  Startup.Environment := @DefaultEnvironment[0];
  Startup.EnvironmentCount := Length(DefaultEnvironment);
  Startup.WorkingDirectory := '/';
  Console := FindDevice('console');
  if (Console = nil) or (OpenDevice(Console, OpenRead or OpenWrite, ConsoleFile) <> ErrorNone) then
  begin
    Report('Cannot open the console for ', @ProgramPath[0]);
    Exit;
  end;
  for StandardIndex := 0 to 2 do
  begin
    Startup.StandardKinds[StandardIndex] := HandleKindDevice;
    Startup.StandardObjects[StandardIndex] := ConsoleFile;
  end;
  { Every program runs on the console unless started on another
    terminal. }
  Startup.ControllingTerminal := Console;

  Report('Starting ', @ProgramPath[0]);
  Error := CreateUserProcess(Startup, Process);
  { The process's handles hold their own references. }
  DereferenceObject(ConsoleFile);
  { The first program owns the console: Ctrl-C ends its group. }
  if Error = ErrorNone then
    SetTerminalForegroundGroup(ConsoleTerminal^, Process^.GroupId);
  if Error <> ErrorNone then
  begin
    DebugBeginMessage;
    DebugWriteTag('init');
    DebugWrite('Could not start the initial program, error ');
    DebugWriteDecimal(QWord(Error));
    DebugWriteLine('');
    DebugEndMessage;
    Exit;
  end;

  WaitForProcessExit(Process, InfiniteTimeout, Result);
  DereferenceObject(Process);

  DebugBeginMessage;
  DebugWriteTag('init');
  DebugWrite(@ProgramPath[0]);
  DebugWrite(' exited with code ');
  DebugWriteSignedDecimal(Result);
  DebugWriteLine('');
  DebugEndMessage;
end;

end.

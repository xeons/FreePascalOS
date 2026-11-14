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
  Objects.Manager,
  Io.Console,
  FileSystem.Types,
  FileSystem.Files,
  Processes.Process,
  Processes.Handles,
  Processes.Paths,
  Processes.UserProcess,
  Debug.Output;

const
  DefaultInitialProgram = '/bin/sh';
  ProgramPathCapacity = 256;

  DefaultEnvironment: array[0..3] of PChar = (
    'PATH=/bin',
    'HOME=/',
    'TERM=console',
    'SHELL=/bin/sh');

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
  Startup.KernelPath := @KernelPath[0];
  Startup.Name := @ProgramPath[0];
  Startup.Arguments := @Arguments[0];
  Startup.ArgumentCount := 1;
  Startup.Environment := @DefaultEnvironment[0];
  Startup.EnvironmentCount := Length(DefaultEnvironment);
  Startup.WorkingDirectory := '/';
  for StandardIndex := 0 to 2 do
  begin
    Startup.StandardKinds[StandardIndex] := HandleKindConsole;
    Startup.StandardObjects[StandardIndex] := ConsoleObject;
  end;

  Report('Starting ', @ProgramPath[0]);
  Error := CreateUserProcess(Startup, Process);
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

  Result := WaitForProcessExit(Process);
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

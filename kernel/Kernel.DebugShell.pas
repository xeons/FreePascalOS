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
  The kernel debug shell: a few commands to look around the system from
  inside the kernel, before (or without) any user program.

  With the kernel option "kshell" it runs on the console once the system
  is up, before the first program starts; "exit" goes on with the boot.
  It reads lines through the console like a program would (with line
  editing) and writes through the kernel debug output, so it works on the
  serial port and the screen alike.

    help              the commands
    echo TEXT         prints TEXT
    ls [PATH]         lists a directory (the volumes for /)
    cat PATH          prints a file
    volumes           the mounted volumes
    disks             the block devices
    ps                the user processes
    trace [THREAD]    kernel stack traces: of the thread with that id, or
                      of every thread
    threads           the user processes with their threads (id, state, priority, name)
    modules ID        a process's program and libraries: load bias, span, name
    mem               physical memory, kernel heap and objects
    cache             the block cache and the disks' statistics
    uptime            time since boot
    watchdog          the hardware watchdog: which, armed, timeout, pets
    suspend           suspends to RAM (ACPI S3) until woken
    poweroff          shuts down and powers off (ACPI S5)
    reboot            shuts down and resets the machine
    exit              leaves the shell
}
unit Kernel.DebugShell;

{$mode objfpc}
{$pointermath on}

interface

{ Runs the shell on the console until "exit". }
procedure RunDebugShell;

{ Carries out one command line (for the network debug shell,
  Kernel.NetworkShell); False for "exit", "poweroff" and "reboot". }
function RunDebugShellCommand(Line: PChar): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Memory.PhysicalPages,
  Objects.Manager,
  Kernel.Clock,
  Io.Console,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.Types,
  FileSystem.Volumes,
  FileSystem.Files,
  Processes.Process,
  Processes.Thread,
  Processes.ImageLoader,
  Kernel.Threads,
  Kernel.Mutex,
  Processes.Shutdown,
  Processes.Suspend,
  Drivers.DiskStatistics,
  Drivers.NetworkCards,
  Io.InterruptRouting,
  Io.PlatformDevices,
  Drivers.RaspberryPiBoard,
  Io.Watchdog,
  Processes.ThreadTraces,
  Debug.Output;

const
  LineCapacity = 256;
  Prompt = 'kshell> ';

{ --- Helpers ------------------------------------------------------------------ }

procedure WriteLine(Text: PChar);
begin
  DebugWriteLine(Text);
end;

procedure ReportStatus(What: PChar; Status: TFileSystemStatus);
begin
  DebugBeginMessage;
  DebugWrite(What);
  DebugWrite(': ');
  DebugWriteLine(FileSystemStatusText(Status));
  DebugEndMessage;
end;

{ Splits Line at its first space: Command returns the word, the result
  the rest (leading spaces skipped). }
function SplitCommand(Line: PChar; Command: PChar; Capacity: Integer): PChar;
var
  Length: Integer;
begin
  while Line^ = ' ' do
    Inc(Line);
  Length := 0;
  while (Line^ <> #0) and (Line^ <> ' ') do
  begin
    if Length < Capacity - 1 then
    begin
      Command[Length] := Line^;
      Inc(Length);
    end;
    Inc(Line);
  end;
  Command[Length] := #0;
  while Line^ = ' ' do
    Inc(Line);
  Result := Line;
end;

{ --- Commands ------------------------------------------------------------------ }

procedure ShowHelp;
begin
  WriteLine('Commands: help, echo TEXT, ls [PATH], cat PATH, volumes, disks, ps, threads, modules ID,');
  WriteLine('trace [THREAD], mem, cache, netcards, interrupts, devices, board, uptime, watchdog, suspend,');
  WriteLine('poweroff, reboot, exit');
end;

procedure ListDirectory(Path: PChar);
var
  OpenedFile: POpenFile;
  Entry: TDirectoryEntry;
  Status: TFileSystemStatus;
begin
  if Path^ = #0 then
    Path := '/';
  Status := OpenPath(Path, OpenedFile);
  if Status <> StatusSuccess then
  begin
    ReportStatus(Path, Status);
    Exit;
  end;
  repeat
    Status := ReadDirectoryEntry(OpenedFile, Entry);
    if Status <> StatusSuccess then
      Break;
    DebugBeginMessage;
    DebugWrite(@Entry.Name[0]);
    if Entry.Kind = NodeKindDirectory then
      DebugWrite('/');
    DebugWriteLine('');
    DebugEndMessage;
  until False;
  if Status <> StatusEndOfDirectory then
    ReportStatus(Path, Status);
  CloseFile(OpenedFile);
end;

procedure ShowFile(Path: PChar);
var
  OpenedFile: POpenFile;
  Buffer: array[0..511] of Char;
  BytesRead: QWord;
  Status: TFileSystemStatus;
  Index: QWord;
  EndedWithNewLine: Boolean;
begin
  Status := OpenPath(Path, OpenedFile);
  if Status <> StatusSuccess then
  begin
    ReportStatus(Path, Status);
    Exit;
  end;
  EndedWithNewLine := True;
  repeat
    Status := ReadFromFile(OpenedFile, @Buffer[0], SizeOf(Buffer), BytesRead);
    if (Status <> StatusSuccess) or (BytesRead = 0) then
      Break;
    DebugBeginMessage;
    for Index := 0 to BytesRead - 1 do
      DebugWriteCharacter(Buffer[Index]);
    DebugEndMessage;
    EndedWithNewLine := Buffer[BytesRead - 1] = #10;
  until False;
  if not EndedWithNewLine then
    WriteLine('');
  if Status <> StatusSuccess then
    ReportStatus(Path, Status);
  CloseFile(OpenedFile);
end;

procedure ShowVolumes;
var
  Index: Integer;
  Volume: PVolume;
begin
  for Index := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(Index);
    if Volume = nil then
      Break;
    DebugBeginMessage;
    DebugWrite(@Volume^.Name[0]);
    DebugWrite('  ');
    DebugWrite(@Volume^.TypeName[0]);
    DebugWrite('  "');
    DebugWrite(@Volume^.VolumeLabel[0]);
    DebugWrite('"  ');
    DebugWriteSize(Volume^.TotalBytes);
    if Volume^.IsReadOnly then
      DebugWriteLine('  read-only')
    else
      DebugWriteLine('  read-write');
    DebugEndMessage;
  end;
end;

procedure ShowDisks;
var
  Index: Integer;
begin
  for Index := 0 to BlockDeviceCount - 1 do
    WriteBlockDeviceDescription(BlockDeviceAt(Index));
end;

procedure DescribeProcess(Process: PProcess; Context: Pointer);
begin
  if not Process^.IsUserProcess then
    Exit;
  DebugBeginMessage;
  DebugWriteDecimal(Process^.ProcessId);
  DebugWrite('  ');
  DebugWrite(@Process^.Name[0]);
  DebugWrite('  ');
  DebugWriteDecimal(Process^.ThreadCount);
  DebugWriteLine(' threads');
  DebugEndMessage;
end;

procedure ShowProcesses;
begin
  WriteLine('ID  NAME  THREADS');
  LockProcessRegistry;
  VisitRunningProcessesLocked(@DescribeProcess, nil);
  UnlockProcessRegistry;
end;

procedure DescribeProcessThread(Thread: PThread; Context: Pointer);
begin
  DebugBeginMessage;
  DebugWrite('    ');
  DebugWriteDecimal(Thread^.ControlBlock.ThreadId);
  DebugWrite('  ');
  DebugWrite(ThreadStateName(Thread^.ControlBlock.State));
  DebugWrite('  ');
  DebugWriteDecimal(Thread^.ControlBlock.Priority);
  DebugWrite('  ');
  DebugWriteLine(@Thread^.ControlBlock.Name[0]);
  DebugEndMessage;
end;

procedure DescribeProcessWithThreads(Process: PProcess; Context: Pointer);
begin
  DescribeProcess(Process, Context);
  if Process^.IsUserProcess then
    VisitProcessThreads(Process, @DescribeProcessThread, nil);
end;

{ Every user process with its threads: id, state, priority and name. }
procedure ShowThreads;
begin
  WriteLine('ID  NAME  THREADS');
  WriteLine('    THREAD  STATE  PRIORITY  NAME');
  LockProcessRegistry;
  VisitRunningProcessesLocked(@DescribeProcessWithThreads, nil);
  UnlockProcessRegistry;
end;

{ The decimal number at the start of Text (0 if there is none). }
function ParseProcessId(Text: PChar): QWord;
begin
  Result := 0;
  while (Text <> nil) and (Text^ >= '0') and (Text^ <= '9') do
  begin
    Result := Result * 10 + QWord(Ord(Text^) - Ord('0'));
    Inc(Text);
  end;
end;

{ The modules of a process: name, load bias (what a symbolizer
  subtracts from an address) and the span of its segments. }
procedure ShowModules(Arguments: PChar);
var
  Process: PProcess;
  List: PModuleList;
  Index: Integer;
  Module: PLoadedModule;
begin
  WriteLine('BASE              START-END                        NAME');
  LockProcessRegistry;
  Process := FindRunningProcessLocked(ParseProcessId(Arguments));
  if (Process = nil) or not Process^.IsUserProcess then
  begin
    UnlockProcessRegistry;
    WriteLine('modules: no such user process');
    Exit;
  end;
  { Kept by a reference, not the registry lock, while its lock is held. }
  ReferenceObject(Process);
  UnlockProcessRegistry;
  AcquireMutex(Process^.Lock);
  List := PModuleList(Process^.Modules);
  if List <> nil then
    for Index := 0 to List^.Count - 1 do
    begin
      Module := List^.Modules[Index];
      DebugBeginMessage;
      DebugWriteHex(Module^.Base, 16);
      DebugWrite('  ');
      DebugWriteHex(Module^.ImageStart, 12);
      DebugWrite('-');
      DebugWriteHex(Module^.ImageEnd, 12);
      DebugWrite('        ');
      DebugWriteLine(@Module^.Name[0]);
      DebugEndMessage;
    end;
  ReleaseMutex(Process^.Lock);
  DereferenceObject(Process);
end;

procedure ShowUptime;
var
  Milliseconds: QWord;
begin
  Milliseconds := UptimeMilliseconds;
  DebugBeginMessage;
  DebugWrite('up ');
  DebugWriteDecimal(Milliseconds div 1000);
  DebugWrite('.');
  DebugWriteDecimal((Milliseconds div 100) mod 10);
  DebugWriteLine(' s');
  DebugEndMessage;
end;

procedure ShowWatchdog;
begin
  DebugBeginMessage;
  DebugWrite('watchdog: ');
  DebugWrite(WatchdogName);
  if WatchdogIsArmed then
  begin
    DebugWrite(', armed for ');
    DebugWriteDecimal(WatchdogTimeoutSeconds);
    DebugWrite(' s, petted ');
    DebugWriteDecimal(WatchdogPetCount);
    DebugWrite(' times');
  end
  else if WatchdogIsPresent then
    DebugWrite(', not armed');
  DebugWriteLine('');
  DebugEndMessage;
end;

{ "trace" writes every thread's trace, "trace ID" one thread's. }
procedure ShowThreadTraces(Arguments: PChar);
var
  ThreadId: QWord;
  Index: Integer;
begin
  if Arguments^ = #0 then
  begin
    WriteThreadTraces(AllThreads);
    Exit;
  end;
  ThreadId := 0;
  Index := 0;
  while Arguments[Index] in ['0'..'9'] do
  begin
    ThreadId := ThreadId * 10 + QWord(Ord(Arguments[Index]) - Ord('0'));
    Inc(Index);
  end;
  if (Index = 0) or not (Arguments[Index] in [#0, ' ']) then
    WriteLine('trace: give a thread id (a number), or nothing for every thread')
  else if not WriteThreadTraces(ThreadId) then
    WriteLine('trace: there is no thread with that id');
end;

{ Carries out one line; returns False for "exit". }
function RunCommand(Line: PChar): Boolean;
var
  Command: array[0..31] of Char;
  Arguments: PChar;
begin
  Result := True;
  Arguments := SplitCommand(Line, @Command[0], SizeOf(Command));
  if Command[0] = #0 then
    Exit;
  if TextIsEqual(@Command[0], 'help') then
    ShowHelp
  else if TextIsEqual(@Command[0], 'echo') then
    WriteLine(Arguments)
  else if TextIsEqual(@Command[0], 'ls') then
    ListDirectory(Arguments)
  else if TextIsEqual(@Command[0], 'cat') then
    ShowFile(Arguments)
  else if TextIsEqual(@Command[0], 'volumes') then
    ShowVolumes
  else if TextIsEqual(@Command[0], 'disks') then
    ShowDisks
  else if TextIsEqual(@Command[0], 'ps') then
    ShowProcesses
  else if TextIsEqual(@Command[0], 'trace') then
    ShowThreadTraces(Arguments)
  else if TextIsEqual(@Command[0], 'threads') then
    ShowThreads
  else if TextIsEqual(@Command[0], 'modules') then
    ShowModules(Arguments)
  else if TextIsEqual(@Command[0], 'mem') then
  begin
    WritePhysicalMemorySummary;
    WriteKernelHeapSummary;
    WriteObjectManagerSummary;
  end
  else if TextIsEqual(@Command[0], 'cache') then
  begin
    WriteBlockCacheSummary;
    WriteDiskStatistics;
  end
  else if TextIsEqual(@Command[0], 'netcards') then
    WriteNetworkCardSummary
  else if TextIsEqual(@Command[0], 'interrupts') then
    WriteSharedLineSummary
  else if TextIsEqual(@Command[0], 'devices') then
    WritePlatformDeviceSummary
  else if TextIsEqual(@Command[0], 'board') then
    WriteBoardInformation
  else if TextIsEqual(@Command[0], 'uptime') then
    ShowUptime
  else if TextIsEqual(@Command[0], 'watchdog') then
    ShowWatchdog
  else if TextIsEqual(@Command[0], 'suspend') then
  begin
    if SuspendToRam <> 0 then
      WriteLine('suspend: the machine could not be suspended');
  end
  else if TextIsEqual(@Command[0], 'poweroff') then
  begin
    RequestShutdown(PowerActionOff);
    Result := False;
  end
  else if TextIsEqual(@Command[0], 'reboot') then
  begin
    RequestShutdown(PowerActionReboot);
    Result := False;
  end
  else if TextIsEqual(@Command[0], 'exit') then
    Result := False
  else
  begin
    DebugBeginMessage;
    DebugWrite(@Command[0]);
    DebugWriteLine(': unknown command (try help)');
    DebugEndMessage;
  end;
end;

{ Reads a line from the console (without its newline); False at the end
  of input. }
function ReadCommandLine(Line: PChar; Capacity: Integer): Boolean;
var
  Length: Integer;
  Character: Char;
begin
  Length := 0;
  repeat
    if ReadFromConsole(@Character, 1) <> 1 then
      Exit(Length > 0);
    if Character = #10 then
      Break;
    if (Length < Capacity - 1) and (Character <> #13) then
    begin
      Line[Length] := Character;
      Inc(Length);
    end;
  until False;
  Line[Length] := #0;
  Result := True;
end;

function RunDebugShellCommand(Line: PChar): Boolean;
begin
  Result := RunCommand(Line);
end;

procedure RunDebugShell;
var
  Line: array[0..LineCapacity - 1] of Char;
begin
  WriteLine('Kernel debug shell; "help" lists the commands, "exit" goes on.');
  repeat
    DebugWrite(Prompt);
    if not ReadCommandLine(@Line[0], LineCapacity) then
      Break;
  until not RunCommand(@Line[0]);
end;

end.

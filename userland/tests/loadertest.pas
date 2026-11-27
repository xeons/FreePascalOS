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
  loadertest: the program loader and process creation against crafted
  and racing input.

    loadertest              the crafted ELF files of /usr/lib/loadertest
                            (scripts/make-crafted-elves.py): each bad
                            program must fail to start and each bad
                            library to load, cleanly, without reaching
                            kernel memory or a page others share (a
                            mapped set-user-ID file is compared before
                            and after); the two good ones must work
    loadertest --unprivileged   what a user (not root) must not do: start
                            a set-user-ID program through a symbolic link
                            swapped by another thread while it starts
                            and get another program run as root; raise
                            a limit it lowered
    loadertest --report-euid    exits 66 when it runs as root, else 7

  Root mode also checks processes and objects: a forked child's thread
  block names the child's thread and its stack overflow is still caught;
  a thread whose handle cannot be stored never runs; a thread handle
  cannot be sent through a channel; sections count against the commit
  limit; a private mapping keeps what the file held when it was mapped
  while another thread rewrites the file.

  Prints "loadertest: all N checks passed" last when nothing failed.
}
program loadertest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Processes,
  Sys.Threads,
  Sys.Libraries;

const
  CraftedFolder = '/usr/lib/loadertest/';
  SetUserIdProgram = '/usr/lib/loadertest/suid-true';
  SelfProgram = '/bin/loadertest';
  WatchedFile = '/bin/su';
  RaceLink = '/tmp/loadertest-link';
  RaceLinkSpare = '/tmp/loadertest-link-new';
  RaceRounds = 300;
  RootExitCode = 66;
  UserExitCode = 7;
  GoodProgramExitCode = 42;
  { Shared with scripts/make-crafted-elves.py. }
  GapLibraryBase = QWord($00005A5A00000000);
  PageBytes = 4096;
  { The POSIX mmap flags and protection (Processes.MemoryMapping). }
  MapShared = $01;
  MapPrivate = $02;
  MapFixedNoReplace = $100000;
  ProtectRead = $1;
  { waitpid. }
  ForkedChildPassed = 0;
  SectionPages = 256;
  SnapshotRounds = 200;
  SnapshotFile = '/tmp/loadertest-snapshot';

var
  Checks: Integer = 0;
  Failures: Integer = 0;
  RaceRunning: Boolean = False;
  StrayThreadRan: Boolean = False;
  WriterRunning: Boolean = False;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('loadertest: pass: ', Name)
  else
  begin
    WriteLn('loadertest: FAIL: ', Name);
    Inc(Failures);
  end;
end;

{ Runs Path with one argument; its exit code or a negative error. }
function RunWithArgument(const Path, Argument: string): LongInt;
var
  Arguments: array[0..2] of PChar;
begin
  Arguments[0] := PChar(Path);
  if Argument <> '' then
    Arguments[1] := PChar(Argument)
  else
    Arguments[1] := nil;
  Arguments[2] := nil;
  Result := RunProgram(PChar(Path), @Arguments[0]);
end;

{ --- The crafted files ---------------------------------------------------- }

procedure CheckProgramRefused(const Name: string);
var
  Outcome: LongInt;
begin
  Outcome := RunWithArgument(CraftedFolder + Name, '');
  Check(Name + ' does not start (' + IntToStr(Outcome) + ')', Outcome < 0);
end;

procedure CheckLibraryRefused(const Name: string);
var
  Handle: Int64;
begin
  Handle := LoadLibrary(PChar(CraftedFolder + Name));
  Check(Name + ' does not load (' + IntToStr(Handle) + ')', Handle < 0);
end;

{ The bytes of the first page of Path, as read() gives them. }
function FirstPageOf(const Path: string): RawByteString;
var
  Handle: Int64;
  Count: Int64;
begin
  Result := '';
  SetLength(Result, PageBytes);
  FillChar(Result[1], PageBytes, 0);
  Handle := KernelOpen(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit('');
  Count := KernelRead(Handle, @Result[1], PageBytes);
  KernelClose(Handle);
  if Count < 0 then
    Exit('');
end;

{ Maps the first page of Path at Address (MapShared or MapPrivate,
  read-only); True on success. }
function MapFirstPage(const Path: string; Address: QWord; Sharing: QWord): Boolean;
var
  Handle: Int64;
  Mapped: Int64;
begin
  Handle := KernelOpen(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  Mapped := SystemCall(CallMapMemory, Address, PageBytes, ProtectRead, Sharing or MapFixedNoReplace,
    QWord(Handle), 0);
  KernelClose(Handle);
  Result := Mapped = Int64(Address);
end;

function MappedPage(Address: QWord): RawByteString;
begin
  Result := '';
  SetLength(Result, PageBytes);
  Move(Pointer(Address)^, Result[1], PageBytes);
end;

{ A library whose relocation aims at a gap of its own image, where this
  program mapped a set-user-ID file: the loader must not write there,
  shared or private, and the file stays as it was. }
procedure CheckGapRelocation(Sharing: QWord; const What: string);
var
  Before: RawByteString;
  Target: QWord;
begin
  Target := GapLibraryBase + PageBytes;
  Before := FirstPageOf(WatchedFile);
  if not MapFirstPage(WatchedFile, Target, Sharing) then
  begin
    Check(What + ': ' + WatchedFile + ' mapped in the library''s gap', False);
    Exit;
  end;
  CheckLibraryRefused('reloc-gap-library.so');
  Check(What + ': the mapped page is unchanged', MappedPage(Target) = Before);
  SystemCall(CallUnmapMemory, Target, PageBytes, 0, 0, 0, 0);
  Check(What + ': ' + WatchedFile + ' is unchanged', (Before <> '') and (FirstPageOf(WatchedFile) = Before));
end;

{ A relocated self pointer is its own address. }
function SelfPointerHolds(LibraryHandle: Int64; const Symbol: string): Boolean;
var
  Value: PQWord;
begin
  Value := PQWord(FindSymbol(LibraryHandle, PChar(Symbol)));
  Result := (Value <> nil) and (Value^ = QWord(Value));
end;

{ --text-relocation-child: loads the library with a relocation into a
  built read-only page, and checks its own copy before and after the
  parent loads it too. }
function RunTextRelocationChild: LongInt;
var
  Handle: Int64;
begin
  Handle := LoadLibrary(PChar(CraftedFolder + 'text-relocation-library.so'));
  if (Handle < 0) or not SelfPointerHolds(Handle, 'loadertest_text_value') then
    Exit(1);
  SleepMilliseconds(600);
  if not SelfPointerHolds(Handle, 'loadertest_text_value') then
    Exit(2);
  Result := 0;
end;

procedure CheckTextRelocation;
var
  Options: TProcessOptions;
  Arguments: array[0..2] of PChar;
  Child: Int64;
  Handle: Int64;
begin
  DefaultProcessOptions(Options);
  Arguments[0] := SelfProgram;
  Arguments[1] := '--text-relocation-child';
  Arguments[2] := nil;
  Child := StartProgram(SelfProgram, @Arguments[0], Options);
  Check('the text relocation child starts', Child >= 0);
  if Child < 0 then
    Exit;
  SleepMilliseconds(200);
  Handle := LoadLibrary(PChar(CraftedFolder + 'text-relocation-library.so'));
  Check('a relocation into a shared read-only page loads', Handle >= 0);
  Check('this process''s copy of the page holds its own value', (Handle >= 0) and
    SelfPointerHolds(Handle, 'loadertest_text_value'));
  Check('the other process''s copy holds its own value', WaitForProgram(Child) = 0);
end;

procedure TestCraftedFiles;
var
  Handle: Int64;
begin
  CheckProgramRefused('segment-kernel-program');
  CheckProgramRefused('segment-wrap-program');
  CheckProgramRefused('reloc-kernel-program');
  CheckProgramRefused('tls-outside-program');
  CheckProgramRefused('odd-relasz-program');

  CheckLibraryRefused('reloc-kernel-library.so');
  CheckLibraryRefused('reloc-outside-library.so');
  CheckLibraryRefused('odd-relasz-library.so');
  CheckLibraryRefused('init-array-kernel-library.so');
  CheckLibraryRefused('unterminated-strings-library.so');
  Handle := LoadLibrary(PChar(CraftedFolder + 'copy-provider-library.so'));
  Check('the copy relocation''s provider loads', Handle >= 0);
  CheckLibraryRefused('copy-kernel-library.so');
  CheckGapRelocation(MapShared, 'shared');
  CheckGapRelocation(MapPrivate, 'private');
  { A failed load leaves nothing behind: the same refusal again. }
  CheckLibraryRefused('reloc-gap-library.so');

  { The files are well formed apart from what each breaks. }
  Check('the good program runs', RunWithArgument(CraftedFolder + 'good-program', '') = GoodProgramExitCode);
  Handle := LoadLibrary(PChar(CraftedFolder + 'good-library.so'));
  Check('the good library loads after the refused ones', Handle >= 0);
  Check('the good library is relocated', (Handle >= 0) and SelfPointerHolds(Handle, 'loadertest_value'));
  CheckTextRelocation;
end;

{ --- What a user must not do ---------------------------------------------- }

{ Swaps the race link between the set-user-ID program and this one. }
function SwapLinks(Argument: Pointer): LongInt;
var
  PointsAtSelf: Boolean;
begin
  PointsAtSelf := False;
  while RaceRunning do
  begin
    KernelRemove(RaceLinkSpare);
    if PointsAtSelf then
      KernelCreateSymbolicLink(SetUserIdProgram, RaceLinkSpare)
    else
      KernelCreateSymbolicLink(SelfProgram, RaceLinkSpare);
    KernelRename(RaceLinkSpare, RaceLink);
    PointsAtSelf := not PointsAtSelf;
  end;
  Result := 0;
end;

procedure TestSetUserIdRace;
var
  Thread: Int64;
  Round: Integer;
  Outcome: LongInt;
  AsRoot: Integer;
  AsUser: Integer;
  SetUserIdRuns: Integer;
  ThreadExit: LongInt;
begin
  KernelRemove(RaceLink);
  KernelCreateSymbolicLink(SetUserIdProgram, RaceLink);
  RaceRunning := True;
  Thread := CreateThread(@SwapLinks, nil);
  Check('the link swapping thread starts', Thread >= 0);
  AsRoot := 0;
  AsUser := 0;
  SetUserIdRuns := 0;
  for Round := 1 to RaceRounds do
  begin
    Outcome := RunWithArgument(RaceLink, '--report-euid');
    if Outcome = RootExitCode then
      Inc(AsRoot)
    else if Outcome = UserExitCode then
      Inc(AsUser)
    else if Outcome = 0 then
      Inc(SetUserIdRuns);
  end;
  RaceRunning := False;
  if Thread >= 0 then
  begin
    WaitForThread(Thread, InfiniteWait, ThreadExit);
    CloseThreadHandle(Thread);
  end;
  KernelRemove(RaceLink);
  KernelRemove(RaceLinkSpare);
  WriteLn(Format('loadertest: race: %d set-user-ID runs, %d as the user, %d as root',
    [SetUserIdRuns, AsUser, AsRoot]));
  Check('no program got the set-user-ID program''s owner through a swapped link', AsRoot = 0);
  Check('the race ran both programs', (AsUser > 0) and (SetUserIdRuns > 0));
end;

procedure TestLimitsStayLowered;
var
  Resources: TAbiProcessResources;
  Lowered: QWord;
begin
  KernelGetProcessResources(0, Resources);
  Lowered := Resources.HandleCount + 64;
  Check('a user lowers its handle limit', KernelSetProcessLimit(ProcessLimitHandles, Lowered) >= 0);
  Check('a user cannot raise it again',
    KernelSetProcessLimit(ProcessLimitHandles, DefaultProcessHandleLimit) = -ErrorNotPermitted);
  KernelGetProcessResources(0, Resources);
  Check('the handle limit stays lowered', Resources.HandleLimit = Lowered);
end;

procedure TestOddTargets;
begin
  Check('stopping the lowest group number is refused',
    KernelStopProcesses(Low(Int64)) = -ErrorInvalidArgument);
  Check('stopping every process (-1) is refused', KernelStopProcesses(-1) = -ErrorInvalidArgument);
  Check('a signal to the lowest group number finds nobody',
    SystemCall(CallSendSignal, QWord(Low(Int64)), 0, 0, 0, 0, 0) = -ErrorNoSuchProcess);
end;

{ --- Processes and objects ------------------------------------------------- }

function RecurseWithoutEnd(Depth: LongInt): LongInt;
var
  Padding: array[0..255] of Byte;
begin
  Padding[Depth and 255] := Byte(Depth);
  Result := RecurseWithoutEnd(Depth + 1) + Padding[(Depth + 1) and 255];
end;

{ The thread id the thread block holds (ThreadBlockIdOffset). }
function ThreadBlockId: QWord; assembler; nostackframe;
asm
{$ifdef CPUX86_64}
  movq %fs:16, %rax
{$else}
  mrs x0, tpidr_el0
  ldr x0, [x0, #8]
{$endif}
end;

{ In a forked child: its thread block holds its own thread's id, and a
  stack overflow is an exception it can catch (its thread took over the
  forking thread's stack). Never returns. }
procedure RunForkedChild;
var
  Code: QWord;
begin
  Code := 0;
  { The thread asked about by the handle -1: the caller. }
  if ThreadBlockId <> QWord(SystemCall(CallGetThreadId, QWord(-1), 0, 0, 0, 0, 0)) then
    Code := Code or 1;
  try
    RecurseWithoutEnd(1);
    Code := Code or 2;
  except
    on E: EStackOverflow do ;
    on E: Exception do
      Code := Code or 4;
  end;
  SystemCall(CallExit, Code, 0, 0, 0, 0, 0);
end;

procedure TestForkedChild;
var
  Child: Int64;
  Status: LongInt;
begin
  Child := SystemCall(CallForkProcess, 0, 0, 0, 0, 0, 0);
  if Child = 0 then
    RunForkedChild;
  Check('fork starts a child', Child > 0);
  if Child <= 0 then
    Exit;
  Status := -1;
  SystemCall(CallWaitForChild, QWord(Child), QWord(@Status), 0, 0, 0, 0);
  { The Linux status word: the exit code in bits 8 to 15. }
  Check('the forked child ends normally (status ' + IntToHex(Status, 4) + ')', (Status and $7F) = 0);
  Check('the forked child''s thread block names its own thread', ((Status shr 8) and 1) = 0);
  Check('the forked child catches a stack overflow', ((Status shr 8) and 6) = ForkedChildPassed);
end;

function MarkStrayThread(Argument: Pointer): LongInt;
begin
  StrayThreadRan := True;
  Result := 0;
end;

{ No handle for a thread: the call fails and no thread runs. }
procedure TestThreadWithoutHandle;
var
  Resources: TAbiProcessResources;
  Thread: Int64;
  Previous: Int64;
begin
  KernelGetProcessResources(0, Resources);
  Previous := KernelSetProcessLimit(ProcessLimitHandles, Resources.HandleCount);
  Thread := CreateThread(@MarkStrayThread, nil);
  KernelSetProcessLimit(ProcessLimitHandles, QWord(Previous));
  SleepMilliseconds(200);
  Check('a thread is refused when its handle does not fit', Thread = -ErrorTooManyHandles);
  Check('the refused thread never ran', not StrayThreadRan);
end;

procedure TestThreadHandleNotSent;
var
  Ends: array[0..1] of Int64;
  Message: TAbiMessage;
  Passed: Int64;
  Thread: Int64;
  ThreadExit: LongInt;
begin
  Check('a channel is made', SystemCall(CallCreateChannel, QWord(@Ends[0]), 0, 0, 0, 0, 0) = 0);
  Thread := CreateThread(@MarkStrayThread, nil);
  Passed := Thread;
  FillChar(Message, SizeOf(Message), 0);
  Message.Data := QWord(@Passed);
  Message.Length := SizeOf(Passed);
  Message.Handles := QWord(@Passed);
  Message.HandleCount := 1;
  Check('a thread handle cannot be sent through a channel',
    SystemCall(CallSendMessage, QWord(Ends[0]), QWord(@Message), 0, 0, 0, 0) = -ErrorInvalidArgument);
  WaitForThread(Thread, InfiniteWait, ThreadExit);
  CloseThreadHandle(Thread);
  KernelClose(Ends[0]);
  KernelClose(Ends[1]);
end;

procedure TestSectionCharge;
var
  Resources: TAbiProcessResources;
  Section: Int64;
begin
  KernelGetProcessResources(0, Resources);
  KernelSetProcessLimit(ProcessLimitCommit, Resources.CommitChargePages + SectionPages div 2);
  Section := SystemCall(CallCreateSection, SectionPages * PageBytes, 0, 0, 0, 0, 0);
  Check('a section over the commit limit is refused', Section = -ErrorOutOfMemory);
  if Section >= 0 then
    KernelClose(Section);
  Section := SystemCall(CallCreateSection, 4 * PageBytes, 0, 0, 0, 0, 0);
  Check('a section within it is made', Section >= 0);
  if Section >= 0 then
    KernelClose(Section);
  { Root takes the limit away again. }
  KernelSetProcessLimit(ProcessLimitCommit, 0);
end;

{ Rewrites the snapshot file, two pages of one letter, then of another. }
function RewriteFile(Argument: Pointer): LongInt;
var
  Contents: array[0..2 * PageBytes - 1] of Byte;
  Letter: Byte;
  Handle: Int64;
begin
  Letter := Ord('A');
  while WriterRunning do
  begin
    FillChar(Contents, SizeOf(Contents), Letter);
    Handle := KernelOpen(SnapshotFile, OpenWrite);
    if Handle >= 0 then
    begin
      KernelWrite(Handle, @Contents[0], SizeOf(Contents));
      KernelClose(Handle);
    end;
    if Letter = Ord('A') then
      Letter := Ord('B')
    else
      Letter := Ord('A');
  end;
  Result := 0;
end;

{ A private mapping of a file another thread keeps rewriting shows one
  version of it, never a mix (its first page from one write, its second
  from the next). }
procedure TestPrivateMappingSnapshot;
var
  Contents: array[0..2 * PageBytes - 1] of Byte;
  Handle: Int64;
  Writer: Int64;
  Round: Integer;
  Mapped: Int64;
  Mixed: Integer;
  Failed: Integer;
  ThreadExit: LongInt;
begin
  FillChar(Contents, SizeOf(Contents), Ord('A'));
  Handle := KernelOpen(SnapshotFile, OpenWrite or OpenCreate or OpenTruncate);
  if Handle >= 0 then
  begin
    KernelWrite(Handle, @Contents[0], SizeOf(Contents));
    KernelClose(Handle);
  end;
  WriterRunning := True;
  Writer := CreateThread(@RewriteFile, nil);
  Mixed := 0;
  Failed := 0;
  for Round := 1 to SnapshotRounds do
  begin
    Handle := KernelOpen(SnapshotFile, OpenRead);
    Mapped := SystemCall(CallMapMemory, 0, 2 * PageBytes, ProtectRead, MapPrivate, QWord(Handle), 0);
    KernelClose(Handle);
    if Mapped <= 0 then
    begin
      Inc(Failed);
      Continue;
    end;
    { The second page touched a moment after the first. }
    SleepMilliseconds(1);
    if PByte(Mapped)^ <> PByte(Mapped + PageBytes)^ then
      Inc(Mixed);
    SystemCall(CallUnmapMemory, QWord(Mapped), 2 * PageBytes, 0, 0, 0, 0);
  end;
  WriterRunning := False;
  WaitForThread(Writer, InfiniteWait, ThreadExit);
  CloseThreadHandle(Writer);
  KernelRemove(SnapshotFile);
  Check('the file was mapped privately every time', Failed = 0);
  Check('a private mapping never mixes two versions of its file (' + IntToStr(Mixed) + ')', Mixed = 0);
end;

function ReportEffectiveUser: LongInt;
var
  Credentials: TAbiCredentials;
begin
  FillChar(Credentials, SizeOf(Credentials), $FF);
  KernelGetCredentials(Credentials);
  if Credentials.EffectiveUserId = 0 then
    Result := RootExitCode
  else
    Result := UserExitCode;
end;

begin
  if ParamStr(1) = '--report-euid' then
    Halt(ReportEffectiveUser);
  if ParamStr(1) = '--text-relocation-child' then
    Halt(RunTextRelocationChild);

  if ParamStr(1) = '--unprivileged' then
  begin
    TestSetUserIdRace;
    TestLimitsStayLowered;
  end
  else
  begin
    TestCraftedFiles;
    TestOddTargets;
    TestForkedChild;
    TestThreadWithoutHandle;
    TestThreadHandleNotSent;
    TestSectionCharge;
    TestPrivateMappingSnapshot;
  end;

  if Failures = 0 then
    WriteLn(Format('loadertest: all %d checks passed', [Checks]))
  else
    WriteLn(Format('loadertest: %d of %d checks FAILED', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.

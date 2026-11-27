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
  Getting stuck in the processor or in a wait of the kernel's: spinning
  (in one thread or several), sleeping, an event nobody sets, a lock
  another thread keeps, two threads deadlocked on each other's locks, a
  thread or child that never ends, a pipe nobody writes or reads, a
  FIFO nobody opens, a file lock another process keeps, a channel
  nobody sends on, a suspended thread, and a long run of memory
  allocations. Each never returns.
}
unit HangTest.Waits;

{$mode objfpc}{$H+}

interface

{ Runs Mode if it is one of these and returns False otherwise. }
function RunWaitMode(const Mode: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Locks,
  Sys.Memory,
  Sys.Objects,
  Sys.Processes,
  Sys.Threads,
  HangTest.Report;

const
  SpinningThreads = 4;
  FifoPath = '/tmp/hangtest.fifo';
  LockFilePath = '/tmp/hangtest.lock';

var
  FirstLock: TLock;
  SecondLock: TLock;

function SpinThread(Argument: Pointer): LongInt;
begin
  SpinForever;
  Result := 0;
end;

function SleepThread(Argument: Pointer): LongInt;
begin
  SleepForever;
  Result := 0;
end;

{ Takes the first lock and keeps it for ever. }
function KeepFirstLockThread(Argument: Pointer): LongInt;
begin
  AcquireLock(FirstLock);
  SleepForever;
  Result := 0;
end;

{ The other half of the deadlock: the second lock, then the first. }
function SecondThenFirstThread(Argument: Pointer): LongInt;
begin
  AcquireLock(SecondLock);
  SleepMilliseconds(200);
  AcquireLock(FirstLock);
  Result := 0;
end;

procedure Spin(const Mode: string; Threads: LongInt);
var
  Index: LongInt;
begin
  for Index := 2 to Threads do
    StartThreadOrGiveUp(@SpinThread, nil);
  SayReady(Mode);
  SpinForever;
end;

procedure WaitForEventNobodySets(const Mode: string; WithTimer: Boolean);
var
  Event: Int64;
  Timer: Int64;
begin
  Event := CreateEvent(True, False);
  if Event < 0 then
    GiveUp('creating an event', Event);
  SayReady(Mode);
  if WithTimer then
  begin
    Timer := CreateTimer(True);
    if Timer < 0 then
      GiveUp('creating a timer', Timer);
    WaitForHandles([Event, Timer, NotificationsHandle], InfiniteWait);
  end
  else
    WaitForHandle(Event, InfiniteWait);
  GiveUp('waiting for the event (it ended)', 0);
end;

procedure WaitForLockAnotherKeeps(const Mode: string);
begin
  InitializeLock(FirstLock);
  StartThreadOrGiveUp(@KeepFirstLockThread, nil);
  SleepMilliseconds(200);
  SayReady(Mode);
  AcquireLock(FirstLock);
  GiveUp('waiting for the lock (it was given)', 0);
end;

procedure Deadlock(const Mode: string);
var
  Handle: Int64;
  ExitCode: LongInt;
begin
  InitializeLock(FirstLock);
  InitializeLock(SecondLock);
  Handle := CreateThread(@SecondThenFirstThread, nil);
  if Handle < 0 then
    GiveUp('starting a thread', Handle);
  AcquireLock(FirstLock);
  SleepMilliseconds(200);
  SayReady(Mode);
  AcquireLock(SecondLock);
  WaitForThread(Handle, InfiniteWait, ExitCode);
  GiveUp('the deadlock (it ended)', 0);
end;

procedure WaitForThreadThatSleeps(const Mode: string);
var
  Handle: Int64;
  ExitCode: LongInt;
begin
  Handle := CreateThread(@SleepThread, nil);
  if Handle < 0 then
    GiveUp('starting a thread', Handle);
  SayReady(Mode);
  WaitForThread(Handle, InfiniteWait, ExitCode);
  GiveUp('waiting for the thread (it ended)', 0);
end;

procedure WaitForChildThatSleeps(const Mode: string);
var
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Child: Int64;
begin
  Arguments[0] := 'sleep';
  Arguments[1] := '100000';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Child := StartProgram('/bin/sleep', @Arguments[0], Options);
  if Child < 0 then
    GiveUp('starting the child', Child);
  SayReady(Mode);
  WaitForProgram(Child);
  GiveUp('waiting for the child (it ended)', 0);
end;

procedure ReadPipeNobodyWrites(const Mode: string);
var
  ReadEnd, WriteEnd: Int64;
  Buffer: array[0..15] of Byte;
begin
  if CreatePipe(ReadEnd, WriteEnd) <> 0 then
    GiveUp('creating a pipe', -1);
  SayReady(Mode);
  ReadFile(ReadEnd, @Buffer[0], SizeOf(Buffer));
  GiveUp('reading the pipe (it returned)', 0);
end;

procedure WritePipeNobodyReads(const Mode: string);
var
  ReadEnd, WriteEnd: Int64;
  Buffer: array[0..4095] of Byte;
begin
  if CreatePipe(ReadEnd, WriteEnd) <> 0 then
    GiveUp('creating a pipe', -1);
  FillChar(Buffer, SizeOf(Buffer), 0);
  SayReady(Mode);
  while WriteFile(WriteEnd, @Buffer[0], SizeOf(Buffer)) > 0 do
    ;
  GiveUp('writing the pipe (it failed)', 0);
end;

procedure OpenFifoNobodyWrites(const Mode: string);
begin
  RemovePath(FifoPath);
  if CreateFifo(FifoPath) <> 0 then
    GiveUp('creating a FIFO', -1);
  SayReady(Mode);
  OpenFile(FifoPath, OpenRead);
  GiveUp('opening the FIFO (it returned)', 0);
end;

{ A child (hangtest file-lock-holder) keeps the lock; this one waits. }
procedure WaitForFileLock(const Mode: string);
var
  Handle: Int64;
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Child: Int64;
begin
  Handle := OpenFile(LockFilePath, OpenRead or OpenWrite or OpenCreate);
  if Handle < 0 then
    GiveUp('opening the lock file', Handle);
  Arguments[0] := 'hangtest';
  Arguments[1] := 'file-lock-holder';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Child := StartProgram('/bin/hangtest', @Arguments[0], Options);
  if Child < 0 then
    GiveUp('starting the holder', Child);
  SleepMilliseconds(1000);
  SayReady(Mode);
  LockFile(Handle, FileLockExclusive);
  GiveUp('waiting for the file lock (it was given)', 0);
end;

procedure HoldFileLock;
var
  Handle: Int64;
begin
  Handle := OpenFile(LockFilePath, OpenRead or OpenWrite or OpenCreate);
  if (Handle < 0) or (LockFile(Handle, FileLockExclusive) <> 0) then
    GiveUp('taking the file lock', Handle);
  SleepForever;
end;

procedure WaitOnChannelNobodySendsOn(const Mode: string);
var
  First, Second: Int64;
begin
  if CreateChannel(First, Second) <> 0 then
    GiveUp('creating a channel', -1);
  SayReady(Mode);
  WaitForHandle(First, InfiniteWait);
  GiveUp('waiting on the channel (it ended)', 0);
end;

{ A thread suspends itself; the main one waits for it. }
function SuspendItselfThread(Argument: Pointer): LongInt;
begin
  SystemCall(CallSuspendThread, QWord(CurrentThreadHandle), 0, 0, 0, 0, 0);
  SleepForever;
  Result := 0;
end;

procedure WaitForSuspendedThread(const Mode: string);
var
  Handle: Int64;
  ExitCode: LongInt;
begin
  Handle := CreateThread(@SuspendItselfThread, nil);
  if Handle < 0 then
    GiveUp('starting a thread', Handle);
  SleepMilliseconds(200);
  SayReady(Mode);
  WaitForThread(Handle, InfiniteWait, ExitCode);
  GiveUp('waiting for the suspended thread (it ended)', 0);
end;

{ Large blocks taken, touched and given back, over and over: the time
  goes into system calls and page faults. }
procedure AllocateForever(const Mode: string);
const
  BlockBytes = 64 * 1024 * 1024;
  PageBytes = 4096;
var
  Block: PByte;
  Offset: QWord;
begin
  SayReady(Mode);
  while True do
  begin
    Block := PByte(AllocateMemory(BlockBytes));
    if Block = nil then
      Continue;
    Offset := 0;
    while Offset < BlockBytes do
    begin
      Block[Offset] := 1;
      Offset := Offset + PageBytes;
    end;
    FreeMemory(Block);
  end;
end;

function RunWaitMode(const Mode: string): Boolean;
begin
  Result := True;
  if Mode = 'spin' then
    Spin(Mode, 1)
  else if Mode = 'spin-threads' then
    Spin(Mode, SpinningThreads)
  else if Mode = 'sleep' then
  begin
    SayReady(Mode);
    SleepForever;
  end
  else if Mode = 'event' then
    WaitForEventNobodySets(Mode, False)
  else if Mode = 'wait-handles' then
    WaitForEventNobodySets(Mode, True)
  else if Mode = 'lock' then
    WaitForLockAnotherKeeps(Mode)
  else if Mode = 'deadlock' then
    Deadlock(Mode)
  else if Mode = 'thread-join' then
    WaitForThreadThatSleeps(Mode)
  else if Mode = 'child-wait' then
    WaitForChildThatSleeps(Mode)
  else if Mode = 'pipe-read' then
    ReadPipeNobodyWrites(Mode)
  else if Mode = 'pipe-write' then
    WritePipeNobodyReads(Mode)
  else if Mode = 'fifo-open' then
    OpenFifoNobodyWrites(Mode)
  else if Mode = 'file-lock' then
    WaitForFileLock(Mode)
  else if Mode = 'file-lock-holder' then
    HoldFileLock
  else if Mode = 'channel' then
    WaitOnChannelNobodySendsOn(Mode)
  else if Mode = 'suspended' then
    WaitForSuspendedThread(Mode)
  else if Mode = 'allocate' then
    AllocateForever(Mode)
  else
    Result := False;
end;

end.

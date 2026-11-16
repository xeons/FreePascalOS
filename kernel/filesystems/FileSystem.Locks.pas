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
  Advisory locks on whole files, as flock gives them.

  A lock belongs to an open file (every handle duplicated from it), not
  to a process: it lasts until the open file gives it up or is deleted
  with its last handle, so a program that ends never leaves a lock
  behind. Any number of open files may hold a shared lock on a file, or
  one may hold an exclusive lock. Locks hold back only other lock
  requests; reading and writing go on regardless. Programs use them to
  take turns at something bigger than one write: the settings library
  holds an exclusive lock on a settings folder while it reads a file,
  changes it and puts the new version in its place.

  The state lives with the node (TNode.LockState), which every open of
  the file shares through the node cache; it is made when the first lock
  is asked for and freed when nobody holds or waits for one. One mutex
  covers every lock state, and is held only for a few instructions at a
  time.

  Waiting: each release signals the state's synchronization event, which
  wakes one waiter; it looks again and either takes its lock or waits
  once more. A waiter let in to a shared lock passes the signal on, as
  further shared waiters may come in too. A waiter that finds the lock
  still taken lets the signal go: whoever holds the lock signals again
  when they give it up, so nobody is left waiting for a lock that is
  free.
}
unit FileSystem.Locks;

{$mode objfpc}

interface

uses
  FileSystem.Types,
  FileSystem.Files;

type
  TFileLockResult = (
    FileLockGranted,
    { Taken by another open file, and the caller would not wait. }
    FileLockBusy,
    { The wait was cut short (the thread was alerted). }
    FileLockInterrupted,
    { The caller may not read (shared) or write (exclusive) the file. }
    FileLockDenied,
    { The namespace root, which is not a file. }
    FileLockUnsupported,
    FileLockOutOfMemory
  );

procedure InitializeFileLocks;

{ Gives OpenedFile a lock of Kind on its file, first giving up the one
  it holds (if any). Waits while the lock is taken if Wait is set. }
function LockOpenFile(OpenedFile: POpenFile; Kind: TFileLockKind; Wait: Boolean): TFileLockResult;
{ Gives up OpenedFile's lock; nothing if it holds none. }
procedure UnlockOpenFile(OpenedFile: POpenFile);

implementation

uses
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Memory.KernelHeap,
  FileSystem.Security;

type
  PFileLockState = ^TFileLockState;
  TFileLockState = record
    SharedHolders: LongInt;
    ExclusiveHeld: Boolean;
    { Threads between deciding to wait and looking again: the state is
      not freed while there are any. }
    Waiters: LongInt;
    Released: TEvent;
  end;

var
  LocksLock: TMutex;

procedure InitializeFileLocks;
begin
  InitializeMutex(LocksLock);
end;

{ The node's lock state, made if it has none; nil if out of memory. }
function StateOfNode(Node: PNode): PFileLockState;
begin
  Result := PFileLockState(Node^.LockState);
  if Result <> nil then
    Exit;
  Result := PFileLockState(AllocateZeroedKernelMemory(SizeOf(TFileLockState)));
  if Result = nil then
    Exit;
  InitializeEvent(Result^.Released, EventKindSynchronization, False);
  Node^.LockState := Result;
end;

procedure FreeStateIfUnused(Node: PNode);
var
  State: PFileLockState;
begin
  State := PFileLockState(Node^.LockState);
  if State = nil then
    Exit;
  if (State^.SharedHolders = 0) and not State^.ExclusiveHeld and (State^.Waiters = 0) then
  begin
    Node^.LockState := nil;
    FreeKernelMemory(State);
  end;
end;

function LockIsAvailable(State: PFileLockState; Kind: TFileLockKind): Boolean;
begin
  if Kind = LockKindShared then
    Result := not State^.ExclusiveHeld
  else
    Result := not State^.ExclusiveHeld and (State^.SharedHolders = 0);
end;

{ Called with LocksLock held. }
procedure ReleaseLocked(OpenedFile: POpenFile);
var
  Node: PNode;
  State: PFileLockState;
begin
  Node := OpenedFile^.Node;
  State := PFileLockState(Node^.LockState);
  if State <> nil then
  begin
    if OpenedFile^.HeldLock = LockKindShared then
      Dec(State^.SharedHolders)
    else
      State^.ExclusiveHeld := False;
    if State^.Waiters > 0 then
      SignalEvent(State^.Released);
    FreeStateIfUnused(Node);
  end;
  OpenedFile^.HeldLock := LockKindNone;
end;

function LockOpenFile(OpenedFile: POpenFile; Kind: TFileLockKind; Wait: Boolean): TFileLockResult;
var
  Node: PNode;
  State: PFileLockState;
  Needed: LongWord;
  WaitResult: TWaitResult;
begin
  Node := OpenedFile^.Node;
  if (OpenedFile^.Volume = nil) or (Node = nil) or (Kind = LockKindNone) then
    Exit(FileLockUnsupported);
  if Kind = LockKindShared then
    Needed := AccessRead
  else
    Needed := AccessWrite;
  if not MayAccess(Node^.Information, Needed) then
    Exit(FileLockDenied);

  AcquireMutex(LocksLock);
  if OpenedFile^.HeldLock <> LockKindNone then
    ReleaseLocked(OpenedFile);
  State := StateOfNode(Node);
  if State = nil then
  begin
    ReleaseMutex(LocksLock);
    Exit(FileLockOutOfMemory);
  end;
  while not LockIsAvailable(State, Kind) do
  begin
    if not Wait then
    begin
      FreeStateIfUnused(Node);
      ReleaseMutex(LocksLock);
      Exit(FileLockBusy);
    end;
    Inc(State^.Waiters);
    ReleaseMutex(LocksLock);
    WaitResult := WaitForEventWithOptions(State^.Released, InfiniteTimeout, True);
    AcquireMutex(LocksLock);
    Dec(State^.Waiters);
    if WaitResult = WaitAlerted then
    begin
      { The signal may have been meant for this thread as it was
        alerted: hand it on (a waiter that finds nothing free just waits
        again). }
      if State^.Waiters > 0 then
        SignalEvent(State^.Released);
      FreeStateIfUnused(Node);
      ReleaseMutex(LocksLock);
      Exit(FileLockInterrupted);
    end;
  end;

  if Kind = LockKindShared then
  begin
    Inc(State^.SharedHolders);
    if State^.Waiters > 0 then
      SignalEvent(State^.Released);
  end
  else
    State^.ExclusiveHeld := True;
  OpenedFile^.HeldLock := Kind;
  ReleaseMutex(LocksLock);
  Result := FileLockGranted;
end;

procedure UnlockOpenFile(OpenedFile: POpenFile);
begin
  if OpenedFile^.HeldLock = LockKindNone then
    Exit;
  AcquireMutex(LocksLock);
  if OpenedFile^.HeldLock <> LockKindNone then
    ReleaseLocked(OpenedFile);
  ReleaseMutex(LocksLock);
end;

end.

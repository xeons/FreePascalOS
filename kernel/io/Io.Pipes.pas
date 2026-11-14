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
  Pipes: one-way byte channels between processes.

  A pipe is a fixed size ring buffer with a read end and a write end.
  Reading waits until data arrives and returns end of file (zero bytes)
  once every write end is closed and the buffer is empty. Writing waits
  for room and fails with "broken pipe" once every read end is closed.

  Ends are counted separately from object references (handles call
  OpenPipeEnd/ClosePipeEnd), so end of file is detected even while the
  pipe object itself is still referenced.

  Named pipes (FIFO nodes in a file system) are pipes found through a
  registry keyed by volume and node number: everyone who opens the node
  while one of its ends is open shares the same pipe. Opening one end
  waits until the other end is opened too.
}
unit Io.Pipes;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Mutex,
  Kernel.Events;

const
  PipeBufferSize = 4096;

type
  PPipe = ^TPipe;
  TPipe = record
    Lock: TMutex;
    Buffer: array[0..PipeBufferSize - 1] of Byte;
    ReadPosition: LongWord;
    ByteCount: LongWord;
    OpenReadEnds: LongInt;
    OpenWriteEnds: LongInt;
    { Synchronization events: signaled when data (or end of file) arrives,
      and when room (or a closed reader) appears. }
    DataAvailable: TEvent;
    SpaceAvailable: TEvent;
    { Named pipes only: the node it belongs to, and its registry link. }
    NamedVolume: Pointer;
    NamedNode: QWord;
    RegistryLink: TListEntry;
    IsRegistered: Boolean;
  end;

procedure InitializePipes;

{ Creates a pipe with no open ends; handles open them. }
function CreatePipe: PPipe;

procedure OpenPipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
procedure ClosePipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);

{ Opens one end of the named pipe of node NodeNumber on volume Volume
  and waits until its other end is open as well. Returns the pipe with a
  reference and with the end counted as open (the caller's handle opens
  it again; the caller then closes this extra end), or nil if the wait
  was cut short by an alert. }
function OpenNamedPipe(Volume: Pointer; NodeNumber: QWord; ForWriting: Boolean): PPipe;

const
  { No reader is left (WriteToPipe). }
  PipeBroken = -1;
  { The wait was cut short by an alert (its process is being ended or
    stopped) before anything was transferred. }
  PipeInterrupted = -2;

{ Reads up to ByteCount bytes, waiting for some. Returns the count, 0 at
  end of file, or PipeInterrupted. }
function ReadFromPipe(Pipe: PPipe; Destination: PByte; ByteCount: QWord): Int64;
{ Returns the number of bytes written, PipeBroken or PipeInterrupted. }
function WriteToPipe(Pipe: PPipe; Source: PByte; ByteCount: QWord): Int64;

implementation

uses
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager;

const
  PeerPollMilliseconds = 20;

var
  PipeObjectType: TObjectType;
  RegistryLock: TMutex;
  NamedPipes: TListEntry;

procedure DeletePipe(ObjectBody: Pointer);
var
  Pipe: PPipe;
begin
  Pipe := PPipe(ObjectBody);
  if Pipe^.NamedVolume = nil then
    Exit;
  AcquireMutex(RegistryLock);
  if Pipe^.IsRegistered then
  begin
    RemoveListEntry(@Pipe^.RegistryLink);
    Pipe^.IsRegistered := False;
  end;
  ReleaseMutex(RegistryLock);
end;

procedure InitializePipes;
begin
  RegisterObjectType(PipeObjectType, 'Pipe', SizeOf(TPipe), @DeletePipe);
  InitializeMutex(RegistryLock);
  InitializeListHead(NamedPipes);
end;

function CreatePipe: PPipe;
begin
  Result := PPipe(CreateObject(PipeObjectType, nil));
  if Result = nil then
    Exit;
  InitializeMutex(Result^.Lock);
  InitializeEvent(Result^.DataAvailable, EventKindSynchronization, False);
  InitializeEvent(Result^.SpaceAvailable, EventKindSynchronization, False);
end;

{ Finds the live pipe of a node (registry lock held). A registered pipe
  with no open ends is on its way out: it is dropped from the registry. }
function FindNamedPipeLocked(Volume: Pointer; NodeNumber: QWord): PPipe;
var
  Entry: PListEntry;
  Next: PListEntry;
  Pipe: PPipe;
begin
  Result := nil;
  Entry := NamedPipes.Next;
  while Entry <> @NamedPipes do
  begin
    Next := Entry^.Next;
    Pipe := PPipe(ContainingRecord(Entry, FieldOffset(PPipe(nil)^.RegistryLink)));
    if (Pipe^.NamedVolume = Volume) and (Pipe^.NamedNode = NodeNumber) then
    begin
      if Pipe^.OpenReadEnds + Pipe^.OpenWriteEnds > 0 then
        Exit(Pipe);
      RemoveListEntry(@Pipe^.RegistryLink);
      Pipe^.IsRegistered := False;
    end;
    Entry := Next;
  end;
end;

function OpenNamedPipe(Volume: Pointer; NodeNumber: QWord; ForWriting: Boolean): PPipe;
var
  Pipe: PPipe;
begin
  AcquireMutex(RegistryLock);
  Pipe := FindNamedPipeLocked(Volume, NodeNumber);
  if Pipe <> nil then
    { Open ends belong to handles, which hold references: it is alive. }
    ReferenceObject(Pipe)
  else
  begin
    Pipe := CreatePipe;
    if Pipe = nil then
    begin
      ReleaseMutex(RegistryLock);
      Exit(nil);
    end;
    Pipe^.NamedVolume := Volume;
    Pipe^.NamedNode := NodeNumber;
    InsertAtTail(NamedPipes, @Pipe^.RegistryLink);
    Pipe^.IsRegistered := True;
  end;
  OpenPipeEnd(Pipe, ForWriting);
  ReleaseMutex(RegistryLock);

  { A reader must not see end of file before any writer came, nor a
    writer a broken pipe before any reader: wait for the other end. }
  while ((ForWriting and (Pipe^.OpenReadEnds = 0)) or
         (not ForWriting and (Pipe^.OpenWriteEnds = 0))) do
  begin
    if not SleepAlertable(PeerPollMilliseconds) then
    begin
      ClosePipeEnd(Pipe, ForWriting);
      DereferenceObject(Pipe);
      Exit(nil);
    end;
  end;
  Result := Pipe;
end;

procedure OpenPipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
begin
  AcquireMutex(Pipe^.Lock);
  if IsWriteEnd then
    Inc(Pipe^.OpenWriteEnds)
  else
    Inc(Pipe^.OpenReadEnds);
  ReleaseMutex(Pipe^.Lock);
end;

procedure ClosePipeEnd(Pipe: PPipe; IsWriteEnd: Boolean);
begin
  AcquireMutex(Pipe^.Lock);
  if IsWriteEnd then
  begin
    Dec(Pipe^.OpenWriteEnds);
    { Wake a reader so it can see end of file. }
    SignalEvent(Pipe^.DataAvailable);
  end
  else
  begin
    Dec(Pipe^.OpenReadEnds);
    SignalEvent(Pipe^.SpaceAvailable);
  end;
  ReleaseMutex(Pipe^.Lock);
end;

function ReadFromPipe(Pipe: PPipe; Destination: PByte; ByteCount: QWord): Int64;
begin
  Result := 0;
  if ByteCount = 0 then
    Exit;

  AcquireMutex(Pipe^.Lock);
  while (Pipe^.ByteCount = 0) and (Pipe^.OpenWriteEnds > 0) do
  begin
    ReleaseMutex(Pipe^.Lock);
    if WaitForEventWithOptions(Pipe^.DataAvailable, InfiniteTimeout, True) = WaitAlerted then
      Exit(PipeInterrupted);
    AcquireMutex(Pipe^.Lock);
  end;

  while (Result < ByteCount) and (Pipe^.ByteCount > 0) do
  begin
    Destination[Result] := Pipe^.Buffer[Pipe^.ReadPosition];
    Pipe^.ReadPosition := (Pipe^.ReadPosition + 1) mod PipeBufferSize;
    Dec(Pipe^.ByteCount);
    Inc(Result);
  end;

  if Result > 0 then
    SignalEvent(Pipe^.SpaceAvailable);
  { Leave the signal for another reader if data remains. }
  if Pipe^.ByteCount > 0 then
    SignalEvent(Pipe^.DataAvailable);
  ReleaseMutex(Pipe^.Lock);
end;

function WriteToPipe(Pipe: PPipe; Source: PByte; ByteCount: QWord): Int64;
var
  Written: QWord;
  WritePosition: LongWord;
begin
  Written := 0;
  AcquireMutex(Pipe^.Lock);
  while Written < ByteCount do
  begin
    if Pipe^.OpenReadEnds <= 0 then
    begin
      ReleaseMutex(Pipe^.Lock);
      if Written > 0 then
        Exit(Int64(Written));
      Exit(PipeBroken);
    end;

    if Pipe^.ByteCount = PipeBufferSize then
    begin
      ReleaseMutex(Pipe^.Lock);
      if WaitForEventWithOptions(Pipe^.SpaceAvailable, InfiniteTimeout, True) = WaitAlerted then
      begin
        if Written > 0 then
          Exit(Int64(Written));
        Exit(PipeInterrupted);
      end;
      AcquireMutex(Pipe^.Lock);
      Continue;
    end;

    WritePosition := (Pipe^.ReadPosition + Pipe^.ByteCount) mod PipeBufferSize;
    Pipe^.Buffer[WritePosition] := Source[Written];
    Inc(Pipe^.ByteCount);
    Inc(Written);
    SignalEvent(Pipe^.DataAvailable);
  end;
  ReleaseMutex(Pipe^.Lock);
  Result := Int64(Written);
end;

end.

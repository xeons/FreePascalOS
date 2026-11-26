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
  Signal descriptors (signalfd): the waiting signals of a mask, read
  as records instead of delivered to handlers.

  A program blocks the signals (sigprocmask), so they wait for the
  process (Processes.Signals) instead of being delivered, and reads them
  from the descriptor: a read takes the lowest waiting signal of the
  mask - sent to the reading thread, or to its process - as a
  TAbiSignalDescriptorRecord, as many as fit, and waits while there is
  none (non-blocking: ErrorWouldBlock).

  The descriptor belongs to the process that made it (it holds a
  reference): it is ready while one of its signals waits for that
  process. Its Ready event follows the process's waiting signals:
  Processes.Signals tells this unit whenever a signal starts waiting
  (NoteSignalWaiting), which signals the Ready events of the process's
  descriptors whose mask has it; a read, and every look before a wait
  (RefreshSignalDescriptor), resets Ready first and signals it again if
  a signal of the mask still waits, so a signal taken some other way (a
  handler, sigwait) leaves no stale readiness behind, and one arriving
  meanwhile is not lost (it is made waiting before Ready is signaled).

  The descriptors are in one list under a spin lock, so a signal can be
  noted from any level up to DispatchLevel.
}
unit Processes.SignalDescriptors;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.Events,
  Processes.Process;

type
  PSignalDescriptor = ^TSignalDescriptor;
  TSignalDescriptor = record
    { The process whose signals it reports (referenced). }
    Process: PProcess;
    { Bit N - 1 for signal N. }
    Mask: QWord;
    NonBlocking: Boolean;
    Ready: TEvent;
    Link: TListEntry;
  end;

procedure InitializeSignalDescriptors;
{ A new descriptor for Process's signals in Mask, with one reference
  (the caller's); nil if memory ran out. }
function CreateSignalDescriptor(Process: PProcess; Mask: QWord; NonBlocking: Boolean): PSignalDescriptor;
procedure SetSignalDescriptorMask(Descriptor: PSignalDescriptor; Mask: QWord);

{ Reads records into Buffer (Capacity bytes, at least one record):
  returns the bytes, or a negative Abi error (ErrorWouldBlock,
  ErrorInterrupted). }
function ReadSignalDescriptor(Descriptor: PSignalDescriptor; Buffer: Pointer; Capacity: QWord): Int64;
{ Brings Ready up to date (before a wait on it). }
procedure RefreshSignalDescriptor(Descriptor: PSignalDescriptor);
function SignalDescriptorReadiness(Descriptor: PSignalDescriptor): LongWord;

{ From Processes.Signals: a signal began to wait for Process. }
procedure NoteSignalWaiting(Process: PProcess; Signal: LongInt);

{ The signals a descriptor never takes: SIGKILL and SIGSTOP. }
function SignalDescriptorMaskOf(Mask: QWord): QWord;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  Processes.PosixState,
  Processes.Signals,
  Processes.Thread;

var
  SignalDescriptorType: TObjectType;
  ListLock: TSpinLock;
  Descriptors: TListEntry;
  DescriptorCount: LongInt = 0;

function SignalBit(Signal: LongInt): QWord;
begin
  Result := QWord(1) shl (Signal - 1);
end;

function SignalDescriptorMaskOf(Mask: QWord): QWord;
begin
  Result := Mask and not (SignalBit(SignalKill) or SignalBit(SignalStop));
end;

function DescriptorFromLink(Entry: PListEntry): PSignalDescriptor;
begin
  Result := PSignalDescriptor(ContainingRecord(Entry, FieldOffset(PSignalDescriptor(nil)^.Link)));
end;

procedure DeleteSignalDescriptor(ObjectBody: Pointer);
var
  Descriptor: PSignalDescriptor;
  PreviousLevel: TPriorityLevel;
begin
  Descriptor := PSignalDescriptor(ObjectBody);
  PreviousLevel := AcquireSpinLock(ListLock);
  RemoveListEntry(@Descriptor^.Link);
  Dec(DescriptorCount);
  ReleaseSpinLock(ListLock, PreviousLevel);
  DereferenceObject(Descriptor^.Process);
end;

procedure InitializeSignalDescriptors;
begin
  RegisterObjectType(SignalDescriptorType, 'SignalDescriptor', SizeOf(TSignalDescriptor),
    @DeleteSignalDescriptor);
  InitializeSpinLock(ListLock);
  InitializeListHead(Descriptors);
end;

{ The signals of Mask waiting for the process. }
function WaitingSignals(Descriptor: PSignalDescriptor): QWord;
begin
  Result := Descriptor^.Process^.Posix.PendingSignals and Descriptor^.Mask;
end;

procedure RefreshSignalDescriptor(Descriptor: PSignalDescriptor);
begin
  ResetEvent(Descriptor^.Ready);
  if WaitingSignals(Descriptor) <> 0 then
    SignalEvent(Descriptor^.Ready);
end;

function CreateSignalDescriptor(Process: PProcess; Mask: QWord; NonBlocking: Boolean): PSignalDescriptor;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := PSignalDescriptor(CreateObject(SignalDescriptorType, nil));
  if Result = nil then
    Exit;
  ReferenceObject(Process);
  Result^.Process := Process;
  Result^.Mask := SignalDescriptorMaskOf(Mask);
  Result^.NonBlocking := NonBlocking;
  InitializeEvent(Result^.Ready, EventKindNotification, False);
  PreviousLevel := AcquireSpinLock(ListLock);
  InsertAtTail(Descriptors, @Result^.Link);
  Inc(DescriptorCount);
  ReleaseSpinLock(ListLock, PreviousLevel);
  RefreshSignalDescriptor(Result);
end;

procedure SetSignalDescriptorMask(Descriptor: PSignalDescriptor; Mask: QWord);
begin
  Descriptor^.Mask := SignalDescriptorMaskOf(Mask);
  RefreshSignalDescriptor(Descriptor);
end;

procedure NoteSignalWaiting(Process: PProcess; Signal: LongInt);
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  Descriptor: PSignalDescriptor;
begin
  if DescriptorCount = 0 then
    Exit;
  PreviousLevel := AcquireSpinLock(ListLock);
  Entry := Descriptors.Next;
  while Entry <> @Descriptors do
  begin
    Descriptor := DescriptorFromLink(Entry);
    if (Descriptor^.Process = Process) and ((Descriptor^.Mask and SignalBit(Signal)) <> 0) then
      SignalEvent(Descriptor^.Ready);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(ListLock, PreviousLevel);
end;

function CodeOf(Code: LongWord): LongInt;
begin
  case Code of
    SignalFromKernel: Result := SignalCodeKernel;
    SignalFromQueue: Result := SignalCodeQueue;
    SignalFromTimer: Result := SignalCodeTimer;
  else
    Result := SignalCodeUser;
  end;
end;

{ Takes the lowest signal of Mask waiting for Thread (when it is one of
  the process's) or the process into Item, a real-time one from its
  queue with its value (Processes.Signals.TakeSignal); False if none
  waits. }
function TakeSignal(Process: PProcess; Thread: PThread; Mask: QWord; out Item: TAbiSignalDescriptorRecord): Boolean;
var
  Information: TAbiSignalInformation;
  Signal: LongInt;
begin
  FillMemory(@Item, SizeOf(Item), 0);
  if (Thread <> nil) and (Thread^.Process <> Process) then
    Thread := nil;
  Signal := Processes.Signals.TakeSignal(Process, Thread, Mask, Information);
  Result := Signal <> 0;
  if not Result then
    Exit;
  Item.Signal := LongWord(Signal);
  Item.Code := CodeOf(Information.Code);
  Item.SenderProcessId := LongWord(Information.SenderProcessId);
  Item.SenderUserId := LongWord(Information.SenderUserId);
  Item.TimerId := Information.TimerId;
  Item.Overrun := Information.Overrun;
  Item.IntegerValue := LongInt(Information.Value);
  Item.PointerValue := QWord(Information.Value);
end;

function ReadSignalDescriptor(Descriptor: PSignalDescriptor; Buffer: Pointer; Capacity: QWord): Int64;
var
  Item: TAbiSignalDescriptorRecord;
  Thread: PThread;
  Used: QWord;
begin
  if Capacity < SizeOf(TAbiSignalDescriptorRecord) then
    Exit(-Int64(ErrorInvalidArgument));
  Thread := CurrentThreadObject;
  repeat
    Used := 0;
    while (Used + SizeOf(Item) <= Capacity) and
      TakeSignal(Descriptor^.Process, Thread, Descriptor^.Mask, Item) do
    begin
      CopyMemory(PByte(Buffer) + Used, @Item, SizeOf(Item));
      Used := Used + SizeOf(Item);
    end;
    RefreshSignalDescriptor(Descriptor);
    if Used > 0 then
      Exit(Int64(Used));
    if Descriptor^.NonBlocking then
      Exit(-Int64(ErrorWouldBlock));
    if WaitForEventWithOptions(Descriptor^.Ready, InfiniteTimeout, True) <> WaitSignaled then
      Exit(-Int64(ErrorInterrupted));
  until False;
end;

function SignalDescriptorReadiness(Descriptor: PSignalDescriptor): LongWord;
begin
  Result := 0;
  if WaitingSignals(Descriptor) <> 0 then
    Result := PollReadable;
end;

end.

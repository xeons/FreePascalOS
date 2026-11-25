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
  What every part of the network layer shares: its lock, the queue of
  received frames and the network thread's wake-ups.

  The network lock is one mutex over all protocol state: interfaces,
  the ARP cache, routes, fragments being put together, and every socket
  and connection. Protocol work happens at passive level only, under
  the lock: on the network thread (frames that arrived, timers) and on
  the threads of programs calling into their sockets. Holding the lock
  while sending is allowed, since drivers never wait in Transmit.

  Drivers hand frames over at dispatch level: the frame is copied into
  a packet and queued here under a spin lock (QueueReceivedPacket), and
  the network thread is woken; it takes them off (TakeReceivedPacket)
  and does the protocol work. The queue is bounded, so a flood costs
  memory only up to MaximumQueuedFrames.

  Timers (TCP retransmission, the ARP cache, fragment reassembly) run on
  the network thread. Whoever needs to be called by a time asks for it
  (RequestNetworkWakeAt, under the lock); the thread sleeps until the
  earliest time asked for, then calls every timer routine, each of
  which asks again for its next time.
}
unit Network.Core;

{$mode objfpc}

interface

uses
  Kernel.Events,
  Network.Packets;

const
  MaximumQueuedFrames = 512;
  { The thread looks at the timers at least this often. }
  IdleWakeNanoseconds = QWord(1000) * 1000 * 1000;

{ Sets the lock and the queue up; does nothing the second time. At
  passive level, while the system starts. }
procedure InitializeNetworkCore;
function NetworkCoreIsReady: Boolean;

procedure LockNetwork;
procedure UnlockNetwork;
function NetworkIsLockedByCurrentThread: Boolean;
{ For a wait that must let the network thread run: lets go of the lock
  however many times the current thread took it, and returns that
  count for ReacquireNetworkLock. }
function ReleaseNetworkLockFully: LongWord;
procedure ReacquireNetworkLock(Depth: LongWord);

{ At dispatch level or below: queues a received packet for the network
  thread and wakes it. False (and the packet freed) if the queue is
  full. }
function QueueReceivedPacket(Packet: PPacket): Boolean;
{ The next received packet; nil if none waits. }
function TakeReceivedPacket: PPacket;

{ Wakes the network thread (any level up to dispatch). }
procedure SignalNetworkWork;
function NetworkWorkEvent: PEvent;

{ The clock the network layer keeps time by: ClockNanoseconds. }
function NetworkNow: QWord;
{ Under the lock: the timer routines want to run by Deadline (a
  NetworkNow time). }
procedure RequestNetworkWakeAt(Deadline: QWord);
{ Under the lock, for the thread: when the timers are due next, and
  starting a new round of requests. }
function NextNetworkWake: QWord;
procedure BeginNetworkTimerRound;

implementation

uses
  Kernel.Mutex,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Clock;

var
  CoreIsReady: Boolean;
  NetworkLockMutex: TMutex;
  ReceiveQueueLock: TSpinLock;
  ReceiveQueue: TPacketQueue;
  WorkEvent: TEvent;
  WakeDeadline: QWord;

procedure InitializeNetworkCore;
begin
  if CoreIsReady then
    Exit;
  InitializeMutex(NetworkLockMutex);
  InitializeSpinLock(ReceiveQueueLock);
  InitializePacketQueue(ReceiveQueue);
  InitializeEvent(WorkEvent, EventKindSynchronization, False);
  WakeDeadline := ClockNanoseconds + IdleWakeNanoseconds;
  CoreIsReady := True;
end;

function NetworkCoreIsReady: Boolean;
begin
  Result := CoreIsReady;
end;

procedure LockNetwork;
begin
  AcquireMutex(NetworkLockMutex);
end;

procedure UnlockNetwork;
begin
  ReleaseMutex(NetworkLockMutex);
end;

function NetworkIsLockedByCurrentThread: Boolean;
begin
  Result := MutexIsOwnedByCurrentThread(NetworkLockMutex);
end;

function ReleaseNetworkLockFully: LongWord;
begin
  Result := 0;
  while MutexIsOwnedByCurrentThread(NetworkLockMutex) do
  begin
    ReleaseMutex(NetworkLockMutex);
    Inc(Result);
  end;
end;

procedure ReacquireNetworkLock(Depth: LongWord);
begin
  while Depth > 0 do
  begin
    AcquireMutex(NetworkLockMutex);
    Dec(Depth);
  end;
end;

function QueueReceivedPacket(Packet: PPacket): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(ReceiveQueueLock);
  Result := ReceiveQueue.Count < MaximumQueuedFrames;
  if Result then
    EnqueuePacket(ReceiveQueue, Packet);
  ReleaseSpinLock(ReceiveQueueLock, PreviousLevel);
  if Result then
    SignalEvent(WorkEvent)
  else
    FreePacket(Packet);
end;

function TakeReceivedPacket: PPacket;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(ReceiveQueueLock);
  Result := DequeuePacket(ReceiveQueue);
  ReleaseSpinLock(ReceiveQueueLock, PreviousLevel);
end;

procedure SignalNetworkWork;
begin
  SignalEvent(WorkEvent);
end;

function NetworkWorkEvent: PEvent;
begin
  Result := @WorkEvent;
end;

function NetworkNow: QWord;
begin
  Result := ClockNanoseconds;
end;

procedure RequestNetworkWakeAt(Deadline: QWord);
begin
  if Deadline < WakeDeadline then
  begin
    WakeDeadline := Deadline;
    SignalEvent(WorkEvent);
  end;
end;

function NextNetworkWake: QWord;
begin
  Result := WakeDeadline;
end;

procedure BeginNetworkTimerRound;
begin
  WakeDeadline := ClockNanoseconds + IdleWakeNanoseconds;
end;

end.

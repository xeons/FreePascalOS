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
  Messages between the parts of a program: windows, controls, and
  anything else that descends from TMessageReceiver.

  A message is a code and two parameters. DeliverMessage hands it to its
  receiver at once (ReceiveMessage, which a class overrides to act on
  the codes it knows and passes the rest to inherited). PostMessage
  queues it for the message loop instead, and may be called from any
  thread: the loop is woken through an event and delivers queued
  messages in order. A receiver that is freed takes its queued messages
  with it.

  Codes below MessageUser are the libraries' (controls tell their
  parents about clicks and changes with them); programs number theirs
  from MessageUser up.
}
unit Windowing.Messages;

{$mode objfpc}

interface

const
  { Sent by a control to its parent: Parameter1 is the control (as a
    pointer), Parameter2 what the control says (a code of its own). }
  MessageNotify = 1;
  { Programs' own codes start here. }
  MessageUser = $1000;

type
  TPostedMessage = record
    Code: LongWord;
    Parameter1: PtrInt;
    Parameter2: PtrInt;
  end;

  TMessageReceiver = class
  public
    destructor Destroy; override;
    { The default does nothing with any code. }
    procedure ReceiveMessage(var Message: TPostedMessage); virtual;
    { Called before a queued message is delivered: a window (and a
      control, through its window) selects its display's scale, as the
      receiver may lay out or draw in pixels. The default does nothing. }
    procedure PrepareToReceive; virtual;
  end;

procedure DeliverMessage(Receiver: TMessageReceiver; Code: LongWord; Parameter1: PtrInt = 0; Parameter2: PtrInt = 0);
{ Queues the message for the message loop; any thread. False if the
  queue is full. }
function PostMessage(Receiver: TMessageReceiver; Code: LongWord; Parameter1: PtrInt = 0;
  Parameter2: PtrInt = 0): Boolean;

{ For the message loop: the event signaled while messages are queued,
  and delivering them. }
function PostedMessageEvent: Int64;
procedure DeliverPostedMessages;

implementation

uses
  Sys.Locks,
  Sys.Objects;

const
  QueueCapacity = 1024;

type
  TQueuedMessage = record
    Receiver: TMessageReceiver;
    Message: TPostedMessage;
  end;

var
  Queue: array[0..QueueCapacity - 1] of TQueuedMessage;
  QueueStart: LongInt;
  QueueCount: LongInt;
  QueueLock: TLock;
  QueueEvent: Int64 = -1;

function PostedMessageEvent: Int64;
begin
  if QueueEvent < 0 then
    QueueEvent := CreateEvent(True, False);
  Result := QueueEvent;
end;

destructor TMessageReceiver.Destroy;
var
  Index: LongInt;
begin
  { Messages still queued for it go nowhere. }
  AcquireLock(QueueLock);
  for Index := 0 to QueueCount - 1 do
    if Queue[(QueueStart + Index) mod QueueCapacity].Receiver = Self then
      Queue[(QueueStart + Index) mod QueueCapacity].Receiver := nil;
  ReleaseLock(QueueLock);
  inherited Destroy;
end;

procedure TMessageReceiver.ReceiveMessage(var Message: TPostedMessage);
begin
end;

procedure TMessageReceiver.PrepareToReceive;
begin
end;

procedure DeliverMessage(Receiver: TMessageReceiver; Code: LongWord; Parameter1: PtrInt; Parameter2: PtrInt);
var
  Message: TPostedMessage;
begin
  if Receiver = nil then
    Exit;
  Message.Code := Code;
  Message.Parameter1 := Parameter1;
  Message.Parameter2 := Parameter2;
  Receiver.ReceiveMessage(Message);
end;

function PostMessage(Receiver: TMessageReceiver; Code: LongWord; Parameter1: PtrInt; Parameter2: PtrInt): Boolean;
var
  Slot: LongInt;
begin
  PostedMessageEvent;
  AcquireLock(QueueLock);
  Result := QueueCount < QueueCapacity;
  if Result then
  begin
    Slot := (QueueStart + QueueCount) mod QueueCapacity;
    Queue[Slot].Receiver := Receiver;
    Queue[Slot].Message.Code := Code;
    Queue[Slot].Message.Parameter1 := Parameter1;
    Queue[Slot].Message.Parameter2 := Parameter2;
    Inc(QueueCount);
    SetEvent(QueueEvent);
  end;
  ReleaseLock(QueueLock);
end;

procedure DeliverPostedMessages;
var
  Entry: TQueuedMessage;
  Taken: Boolean;
begin
  repeat
    AcquireLock(QueueLock);
    Taken := QueueCount > 0;
    if Taken then
    begin
      Entry := Queue[QueueStart];
      QueueStart := (QueueStart + 1) mod QueueCapacity;
      Dec(QueueCount);
    end
    else if QueueEvent >= 0 then
      ResetEvent(QueueEvent);
    ReleaseLock(QueueLock);
    { Delivered outside the lock: the receiver may post more. }
    if Taken and (Entry.Receiver <> nil) then
    begin
      Entry.Receiver.PrepareToReceive;
      Entry.Receiver.ReceiveMessage(Entry.Message);
    end;
  until not Taken;
end;

initialization
  InitializeLock(QueueLock);
end.

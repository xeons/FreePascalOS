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
  Objects for programs that work together: events, semaphores, timers,
  waiting on several handles, shared memory sections, ports and
  channels.

  A semaphore holds a count from 0 to its limit. A wait on its handle
  (WaitForHandle, WaitForHandles, WaitForAllHandles) takes one, waiting
  while there are none; ReleaseSemaphore gives some back. Sys.Semaphores
  wraps one in a class.

  Every routine returning LongInt returns ErrorNone or an error code;
  those returning Int64 a handle (or index) or minus an error code. The
  objects are handles like files: CloseHandle closes them, and they go
  to children and through channels.

  A channel carries messages of up to MaximumMessageBytes bytes and
  MaximumMessageHandles handles. CallChannel is a request and its reply:
  it sends a message and waits for the next one to come back (a server
  answers each request in turn).
}
unit Sys.Objects;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

procedure CloseHandle(Handle: Int64);

function CreateEvent(ManualReset, Signaled: Boolean): Int64;
function SetEvent(Handle: Int64): LongInt;
function ResetEvent(Handle: Int64): LongInt;
{ A semaphore counting from InitialCount, at most Limit (1 to
  MaximumSemaphoreLimit). }
function CreateSemaphore(InitialCount, Limit: LongInt): Int64;
{ Gives back ReleaseCount; PreviousCount is the count before.
  ErrorOverflow, changing nothing, past the limit. }
function ReleaseSemaphore(Handle: Int64; ReleaseCount: LongInt; out PreviousCount: LongInt): LongInt;
{ The count now, or minus an error. }
function GetSemaphoreCount(Handle: Int64): Int64;
function CreateTimer(ManualReset: Boolean): Int64;
{ Due in DueMilliseconds, then every PeriodMilliseconds (0: once). }
function SetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): LongInt;
{ The place in Handles of the first one signaled; -ErrorTimedOut after
  Timeout milliseconds (InfiniteWait: no limit). }
function WaitForHandles(const Handles: array of Int64; Timeout: Int64): Int64;
function WaitForHandle(Handle: Int64; Timeout: Int64): LongInt;
{ Waits until every one of Handles is signaled at the same time
  (ErrorNone); the automatic reset events and timers among them are
  consumed only then, all together. ErrorTimedOut after Timeout. }
function WaitForAllHandles(const Handles: array of Int64; Timeout: Int64): LongInt;

function CreateSection(Length: QWord): Int64;
{ Maps Length bytes of the section from Offset (page aligned); nil if
  that failed. Unmapped with UnmapSection. }
function MapSection(Handle: Int64; Offset, Length: QWord): Pointer;
procedure UnmapSection(Address: Pointer);

function CreatePort(Name: PChar): Int64;
function ConnectPort(Name: PChar): Int64;
function AcceptConnection(Port: Int64): Int64;
function CreateChannel(out First, Second: Int64): LongInt;
function SendMessage(Channel: Int64; Data: Pointer; Length: QWord; const Handles: array of Int64): LongInt;
{ Receives into Buffer (Capacity bytes) and Handles (as many as it
  holds): Length and HandleCount say what came. Does not wait:
  ErrorWouldBlock if nothing is there. }
function ReceiveMessage(Channel: Int64; Buffer: Pointer; Capacity: QWord; out Length: QWord;
  var Handles: array of Int64; out HandleCount: QWord): LongInt;
{ Waits up to Timeout for a message, then receives it. }
function WaitForMessage(Channel: Int64; Buffer: Pointer; Capacity: QWord; out Length: QWord;
  var Handles: array of Int64; out HandleCount: QWord; Timeout: Int64): LongInt;
{ Who holds the other end of Channel (process, user and group); an
  error while not known. }
function GetChannelPeer(Channel: Int64; out Peer: TAbiChannelPeer): LongInt;
{ Sends Request and waits up to Timeout for the reply. }
function CallChannel(Channel: Int64; Request: Pointer; RequestLength: QWord; Reply: Pointer; ReplyCapacity: QWord;
  out ReplyLength: QWord; Timeout: Int64): LongInt;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

procedure CloseHandle(Handle: Int64);
begin
  KernelClose(Handle);
end;

function CreateEvent(ManualReset, Signaled: Boolean): Int64;
var
  Flags: LongWord;
begin
  Flags := 0;
  if ManualReset then
    Flags := Flags or EventManualReset;
  if Signaled then
    Flags := Flags or EventSignaled;
  Result := KernelCreateEvent(Flags);
end;

function SetEvent(Handle: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelSetEvent(Handle));
end;

function ResetEvent(Handle: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelResetEvent(Handle));
end;

function CreateSemaphore(InitialCount, Limit: LongInt): Int64;
begin
  Result := KernelCreateSemaphore(InitialCount, Limit);
end;

function ReleaseSemaphore(Handle: Int64; ReleaseCount: LongInt; out PreviousCount: LongInt): LongInt;
var
  CallResult: Int64;
begin
  PreviousCount := 0;
  CallResult := KernelReleaseSemaphore(Handle, ReleaseCount);
  if CallResult >= 0 then
    PreviousCount := LongInt(CallResult);
  Result := ErrorCodeOf(CallResult);
end;

function GetSemaphoreCount(Handle: Int64): Int64;
begin
  Result := KernelGetSemaphoreCount(Handle);
end;

function CreateTimer(ManualReset: Boolean): Int64;
begin
  if ManualReset then
    Result := KernelCreateTimer(TimerManualReset)
  else
    Result := KernelCreateTimer(0);
end;

function SetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): LongInt;
begin
  Result := ErrorCodeOf(KernelSetTimer(Handle, DueMilliseconds, PeriodMilliseconds));
end;

function WaitForHandles(const Handles: array of Int64; Timeout: Int64): Int64;
begin
  if Length(Handles) = 0 then
    Exit(-ErrorInvalidArgument);
  Result := KernelWaitForHandles(@Handles[0], Length(Handles), Timeout, 0);
end;

function WaitForHandle(Handle: Int64; Timeout: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelWaitForHandles(@Handle, 1, Timeout, 0));
end;

function WaitForAllHandles(const Handles: array of Int64; Timeout: Int64): LongInt;
begin
  if Length(Handles) = 0 then
    Exit(ErrorInvalidArgument);
  Result := ErrorCodeOf(KernelWaitForHandles(@Handles[0], Length(Handles), Timeout, WaitForAll));
end;

function CreateSection(Length: QWord): Int64;
begin
  Result := KernelCreateSection(Length);
end;

function MapSection(Handle: Int64; Offset, Length: QWord): Pointer;
var
  Address: Int64;
begin
  Address := KernelMapHandle(Handle, Offset, Length);
  if Address < 0 then
    Exit(nil);
  Result := Pointer(Address);
end;

procedure UnmapSection(Address: Pointer);
begin
  if Address <> nil then
    KernelFreeMemory(Address);
end;

function CreatePort(Name: PChar): Int64;
begin
  Result := KernelCreatePort(Name);
end;

function ConnectPort(Name: PChar): Int64;
begin
  Result := KernelConnectPort(Name);
end;

function AcceptConnection(Port: Int64): Int64;
begin
  Result := KernelAcceptConnection(Port);
end;

function CreateChannel(out First, Second: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelCreateChannel(First, Second));
end;

function SendMessage(Channel: Int64; Data: Pointer; Length: QWord; const Handles: array of Int64): LongInt;
var
  Message: TAbiMessage;
begin
  Message.Data := QWord(Data);
  Message.Length := Length;
  Message.HandleCount := System.Length(Handles);
  if Message.HandleCount > 0 then
    Message.Handles := QWord(@Handles[0])
  else
    Message.Handles := 0;
  Result := ErrorCodeOf(KernelSendMessage(Channel, Message));
end;

function ReceiveMessage(Channel: Int64; Buffer: Pointer; Capacity: QWord; out Length: QWord;
  var Handles: array of Int64; out HandleCount: QWord): LongInt;
var
  Message: TAbiMessage;
begin
  Message.Data := QWord(Buffer);
  Message.Length := Capacity;
  Message.HandleCount := System.Length(Handles);
  if Message.HandleCount > 0 then
    Message.Handles := QWord(@Handles[0])
  else
    Message.Handles := 0;
  Result := ErrorCodeOf(KernelReceiveMessage(Channel, Message));
  Length := Message.Length;
  HandleCount := Message.HandleCount;
end;

function WaitForMessage(Channel: Int64; Buffer: Pointer; Capacity: QWord; out Length: QWord;
  var Handles: array of Int64; out HandleCount: QWord; Timeout: Int64): LongInt;
begin
  Length := 0;
  HandleCount := 0;
  Result := WaitForHandle(Channel, Timeout);
  if Result = ErrorNone then
    Result := ReceiveMessage(Channel, Buffer, Capacity, Length, Handles, HandleCount);
end;

function CallChannel(Channel: Int64; Request: Pointer; RequestLength: QWord; Reply: Pointer; ReplyCapacity: QWord;
  out ReplyLength: QWord; Timeout: Int64): LongInt;
var
  NoHandles: array[0..0] of Int64;
  HandleCount: QWord;
begin
  ReplyLength := 0;
  Result := SendMessage(Channel, Request, RequestLength, []);
  if Result = ErrorNone then
    Result := WaitForMessage(Channel, Reply, ReplyCapacity, ReplyLength, NoHandles, HandleCount, Timeout);
end;

function GetChannelPeer(Channel: Int64; out Peer: TAbiChannelPeer): LongInt;
begin
  Result := ErrorCodeOf(KernelGetChannelPeer(Channel, Peer));
end;

end.

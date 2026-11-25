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
  System calls for local (Unix domain) sockets (CallCreateLocalSocket
  to CallQueryLocalSocket), the network socket calls that take a local
  socket too (listen, accept, shutdown, the options, waiting), and
  CallRead and CallWrite on one.

  Sending copies the program's bytes into the message (a stream in
  pieces of TransferChunkSize, the first carrying the passed handles),
  looks up the handles to pass (each held as an open handle while in
  flight) and stamps the message with the sender's credentials and
  name. Receiving takes bytes into a kernel buffer (Processes.
  LocalSockets), copies them out, and installs the passed objects as
  new handles of the receiver.
}
unit Processes.LocalSocketCalls;

{$mode objfpc}
{$pointermath on}

interface

{ Whether Handle is a local socket of the calling process. }
function IsLocalSocketHandle(Handle: Int64): Boolean;
{ The network socket calls (CallListenSocket to CallWaitForSocket, by
  Number) on a local socket. }
function PerformSocketCallOnLocalSocket(Number: QWord; Handle: Int64; Argument1, Argument2,
  Argument3: QWord): Int64;

function PerformCreateLocalSocket(Kind, Flags, PairAddress: QWord): Int64;
function PerformBindLocalSocket(Handle: Int64; NameAddress: QWord): Int64;
function PerformConnectLocalSocket(Handle: Int64; NameAddress: QWord): Int64;
function PerformSendLocalMessage(Handle: Int64; MessageAddress, Flags: QWord): Int64;
function PerformReceiveLocalMessage(Handle: Int64; MessageAddress, Flags: QWord): Int64;
function PerformQueryLocalSocket(Handle: Int64; Which, BufferAddress: QWord): Int64;

{ CallRead and CallWrite on a local socket handle. }
function ReadLocalSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
function WriteLocalSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Objects.Manager,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.ObjectCalls,
  Processes.Restrictions,
  Processes.LocalSockets,
  Processes.LocalSocketNames;

const
  AddressFamilyLocal = 1;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function ReferenceLocalSocket(Handle: Int64): PLocalSocket;
begin
  Result := PLocalSocket(ReferenceHandleOfKind(Handle, HandleKindLocalSocket));
end;

function IsLocalSocketHandle(Handle: Int64): Boolean;
var
  Socket: PLocalSocket;
begin
  Socket := ReferenceLocalSocket(Handle);
  Result := Socket <> nil;
  if Result then
    DereferenceObject(Socket);
end;

procedure CallerCredentials(out Credentials: TAbiLocalCredentials);
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  FillMemory(@Credentials, SizeOf(Credentials), 0);
  Credentials.ProcessId := LongWord(Process^.ProcessId);
  Credentials.UserId := Process^.Credentials.EffectiveUserId;
  Credentials.GroupId := Process^.Credentials.EffectiveGroupId;
end;

{ A handle of the caller to Socket (the handle takes its own
  reference); minus an error if the table is full. }
function InsertLocalSocketHandle(Socket: PLocalSocket): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := InsertHandle(Process^.Handles, HandleKindLocalSocket, Socket, 0);
  ReleaseMutex(Process^.Lock);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

function CopyNameFromUser(NameAddress: QWord; out Name: TAbiLocalSocketName): LongInt;
begin
  FillMemory(@Name, SizeOf(Name), 0);
  if NameAddress = 0 then
    Exit(ErrorBadAddress);
  Result := CopyFromUser(@Name, NameAddress, SizeOf(Name));
  if Result = ErrorNone then
    Result := ValidateLocalSocketName(Name);
end;

{ --- Making, binding, connecting ------------------------------------------- }

function CreateForCaller(Kind: LongWord; NonBlocking: Boolean; out Socket: PLocalSocket): LongInt;
var
  Credentials: TAbiLocalCredentials;
begin
  CallerCredentials(Credentials);
  Result := CreateLocalSocket(Kind, NonBlocking, Credentials, Socket);
end;

function CreatePair(Kind: LongWord; NonBlocking: Boolean; PairAddress: QWord): Int64;
var
  First: PLocalSocket;
  Second: PLocalSocket;
  Handles: array[0..1] of Int64;
  Error: LongInt;
  Process: PProcess;
begin
  if not UserRangeIsValid(PairAddress, SizeOf(Handles), True) then
    Exit(Failure(ErrorBadAddress));
  Error := CreateForCaller(Kind, NonBlocking, First);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := CreateForCaller(Kind, NonBlocking, Second);
  if Error <> ErrorNone then
  begin
    DereferenceObject(First);
    Exit(Failure(Error));
  end;
  ConnectLocalPair(First, Second);
  Handles[0] := InsertLocalSocketHandle(First);
  Handles[1] := -1;
  if Handles[0] >= 0 then
    Handles[1] := InsertLocalSocketHandle(Second);
  DereferenceObject(First);
  DereferenceObject(Second);
  if Handles[1] < 0 then
  begin
    Process := CurrentProcess;
    if Handles[0] >= 0 then
    begin
      AcquireMutex(Process^.Lock);
      CloseHandle(Process^.Handles, Handles[0]);
      ReleaseMutex(Process^.Lock);
    end;
    Exit(Failure(ErrorTooManyHandles));
  end;
  Result := Failure(CopyToUser(PairAddress, @Handles[0], SizeOf(Handles)));
end;

function PerformCreateLocalSocket(Kind, Flags, PairAddress: QWord): Int64;
var
  Socket: PLocalSocket;
  Error: LongInt;
  NonBlocking: Boolean;
begin
  if (Flags and not QWord(LocalSocketNonBlocking)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  if not IsLocalSocketKind(LongWord(Kind and $FF)) or (Kind > $FF) then
    Exit(Failure(ErrorProtocolNotSupported));
  NonBlocking := (Flags and LocalSocketNonBlocking) <> 0;
  if PairAddress <> 0 then
    Exit(CreatePair(LongWord(Kind), NonBlocking, PairAddress));
  Error := CreateForCaller(LongWord(Kind), NonBlocking, Socket);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := InsertLocalSocketHandle(Socket);
  DereferenceObject(Socket);
end;

function PerformBindLocalSocket(Handle: Int64; NameAddress: QWord): Int64;
var
  Socket: PLocalSocket;
  Name: TAbiLocalSocketName;
  Error: LongInt;
begin
  Error := CopyNameFromUser(NameAddress, Name);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if (Name.Length > 0) and (Name.Bytes[0] <> #0) and CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Failure(BindLocalSocketName(Socket, Name));
  DereferenceObject(Socket);
end;

function PerformConnectLocalSocket(Handle: Int64; NameAddress: QWord): Int64;
var
  Socket: PLocalSocket;
  Target: PLocalSocket;
  Name: TAbiLocalSocketName;
  Credentials: TAbiLocalCredentials;
  Error: LongInt;
begin
  Error := CopyNameFromUser(NameAddress, Name);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := FindLocalSocketByName(Name, Target);
  if Error = ErrorNone then
  begin
    CallerCredentials(Credentials);
    Error := ConnectLocalSocket(Socket, Target, Credentials);
    DereferenceObject(Target);
  end;
  DereferenceObject(Socket);
  Result := Failure(Error);
end;

{ --- Sending ---------------------------------------------------------------- }

{ Looks up Count handles of the caller (numbers at HandlesAddress) into
  Passed, each held as an open handle. On failure nothing is held. }
function CollectPassedObjects(HandlesAddress: QWord; Count: LongWord; Passed: PLocalPassedObject): LongInt;
var
  Numbers: array[0..MaximumLocalMessageHandles - 1] of Int64;
  Index: LongWord;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if Count = 0 then
    Exit(ErrorNone);
  Result := CopyFromUser(@Numbers[0], HandlesAddress, QWord(Count) * SizeOf(Int64));
  if Result <> ErrorNone then
    Exit;
  Index := 0;
  while Index < Count do
  begin
    ObjectBody := ReferenceHandle(Numbers[Index], Kind);
    if ObjectBody = nil then
      Result := ErrorBadHandle
    else if (Kind = HandleKindThread) or (Kind = HandleKindReserved) then
      Result := ErrorInvalidArgument;
    if Result <> ErrorNone then
    begin
      if ObjectBody <> nil then
        DereferenceObject(ObjectBody);
      Break;
    end;
    TakeHandleReference(Kind, ObjectBody);
    DereferenceObject(ObjectBody);
    Passed[Index].Kind := Kind;
    Passed[Index].ObjectBody := ObjectBody;
    Inc(Index);
  end;
  if Result <> ErrorNone then
    while Index > 0 do
    begin
      Dec(Index);
      DropHandleReference(Passed[Index].Kind, Passed[Index].ObjectBody);
    end;
end;

{ The sender's credentials and name on a message. }
procedure StampMessage(Socket: PLocalSocket; Message: PLocalMessage);
begin
  CallerCredentials(Message^.Sender);
  LockLocalSockets;
  Message^.SenderName := Socket^.Name;
  UnlockLocalSockets;
end;

{ One message of Length bytes from BufferAddress (with Count passed
  handles); the bytes sent or minus an error. }
function SendOneMessage(Socket: PLocalSocket; BufferAddress, Length: QWord; HandlesAddress: QWord;
  HandleCount: LongWord; Destination: PLocalSocket; DontWait: Boolean): Int64;
var
  Message: PLocalMessage;
  Error: LongInt;
begin
  Message := AllocateLocalMessage(Length, HandleCount);
  if Message = nil then
    Exit(Failure(ErrorOutOfMemory));
  Message^.PassedCount := 0;
  Error := CopyFromUser(Message^.Data, BufferAddress, Length);
  if Error = ErrorNone then
    Error := CollectPassedObjects(HandlesAddress, HandleCount, Message^.Passed);
  if Error = ErrorNone then
  begin
    Message^.PassedCount := HandleCount;
    StampMessage(Socket, Message);
    Error := SendLocalMessage(Socket, Message, Destination, DontWait);
  end;
  if Error <> ErrorNone then
  begin
    FreeLocalMessage(Message);
    Exit(Failure(Error));
  end;
  Result := Int64(Length);
end;

{ A stream in pieces (the first carrying the handles); a datagram or
  packet whole. }
function SendBytes(Socket: PLocalSocket; BufferAddress, Length: QWord; HandlesAddress: QWord;
  HandleCount: LongWord; Destination: PLocalSocket; DontWait: Boolean): Int64;
var
  Total: QWord;
  Piece: QWord;
  Sent: Int64;
begin
  if not UserRangeIsValid(BufferAddress, Length, False) then
    Exit(Failure(ErrorBadAddress));
  if Socket^.Kind <> LocalSocketStream then
  begin
    if Length > LocalDatagramLimit then
      Exit(Failure(ErrorMessageTooLong));
    Exit(SendOneMessage(Socket, BufferAddress, Length, HandlesAddress, HandleCount, Destination, DontWait));
  end;
  if (Length = 0) and (HandleCount = 0) then
    Exit(0);
  Total := 0;
  Result := 0;
  repeat
    Piece := Length - Total;
    if Piece > TransferChunkSize then
      Piece := TransferChunkSize;
    Sent := SendOneMessage(Socket, BufferAddress + Total, Piece, HandlesAddress, HandleCount, nil, DontWait);
    if Sent < 0 then
    begin
      if Total = 0 then
        Result := Sent;
      Break;
    end;
    HandleCount := 0;
    Total := Total + QWord(Sent);
  until Total >= Length;
  if Total > 0 then
    Result := Int64(Total);
end;

function PerformSendLocalMessage(Handle: Int64; MessageAddress, Flags: QWord): Int64;
var
  Socket: PLocalSocket;
  Destination: PLocalSocket;
  Request: TAbiLocalMessage;
  Name: TAbiLocalSocketName;
  Error: LongInt;
begin
  Error := CopyFromUser(@Request, MessageAddress, SizeOf(Request));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if Request.HandleCount > MaximumLocalMessageHandles then
    Exit(Failure(ErrorInvalidArgument));
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Destination := nil;
  Error := ErrorNone;
  if Request.NameAddress <> 0 then
  begin
    Error := CopyNameFromUser(Request.NameAddress, Name);
    if (Error = ErrorNone) and (Socket^.Kind <> LocalSocketDatagram) then
      { A connected socket ignores the name (Linux: EISCONN unless it
        matches; programs pass their peer's). }
      Error := ErrorNone
    else if Error = ErrorNone then
      Error := FindLocalSocketByName(Name, Destination);
  end;
  if Error = ErrorNone then
    Result := SendBytes(Socket, Request.BufferAddress, Request.Length, Request.HandlesAddress,
      Request.HandleCount, Destination, (Flags and LocalMessageDontWait) <> 0)
  else
    Result := Failure(Error);
  if Destination <> nil then
    DereferenceObject(Destination);
  DereferenceObject(Socket);
end;

{ --- Receiving -------------------------------------------------------------- }

{ Installs the receipt's objects as handles of the caller (up to
  Capacity, numbers to HandlesAddress); the rest are closed. Returns
  how many were installed; Cut says some were not. }
function InstallPassedObjects(var Receipt: TLocalReceipt; HandlesAddress: QWord; Capacity: LongWord;
  out Cut: Boolean): LongWord;
var
  Numbers: array[0..MaximumLocalMessageHandles - 1] of Int64;
  Process: PProcess;
  Index: LongWord;
  Number: Integer;
begin
  Result := 0;
  Cut := False;
  if Receipt.PassedCount = 0 then
    Exit;
  if Capacity > MaximumLocalMessageHandles then
    Capacity := MaximumLocalMessageHandles;
  Process := CurrentProcess;
  Index := 0;
  while Index < Receipt.PassedCount do
  begin
    Number := -1;
    if Result < Capacity then
    begin
      AcquireMutex(Process^.Lock);
      Number := InsertHandle(Process^.Handles, Receipt.Passed[Index].Kind, Receipt.Passed[Index].ObjectBody, 0);
      ReleaseMutex(Process^.Lock);
    end;
    if Number >= 0 then
    begin
      Numbers[Result] := Number;
      Inc(Result);
    end
    else
      Cut := True;
    { The handle holds its own; the in-flight hold goes. }
    DropHandleReference(Receipt.Passed[Index].Kind, Receipt.Passed[Index].ObjectBody);
    Inc(Index);
  end;
  FreeKernelMemory(Receipt.Passed);
  Receipt.Passed := nil;
  Receipt.PassedCount := 0;
  if (Result > 0) and (CopyToUser(HandlesAddress, @Numbers[0], QWord(Result) * SizeOf(Int64)) <> ErrorNone) then
    Cut := True;
end;

{ Receives up to Length bytes to BufferAddress. A stream takes what is
  there (and with LocalMessageWaitAll waits for all of it), in rounds of
  one kernel buffer; the first receipt's sender and objects are kept in
  First. Returns the bytes received or minus an error. }
function ReceiveBytes(Socket: PLocalSocket; BufferAddress, Length: QWord; Flags: LongWord;
  out First: TLocalReceipt): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Receipt: TLocalReceipt;
  Total: QWord;
  RoundFlags: LongWord;
  Error: LongInt;
begin
  FillMemory(@First, SizeOf(First), 0);
  if not UserRangeIsValid(BufferAddress, Length, True) then
    Exit(Failure(ErrorBadAddress));
  if Socket^.Kind = LocalSocketStream then
    BufferSize := TransferChunkSize
  else
    BufferSize := LocalDatagramLimit;
  if BufferSize > Length then
    BufferSize := Length;
  Buffer := PByte(AllocateKernelMemory(BufferSize + 1));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Total := 0;
  Result := 0;
  RoundFlags := Flags;
  repeat
    Error := ReceiveLocalMessage(Socket, Buffer, BufferSize, RoundFlags, Receipt);
    if Error <> ErrorNone then
    begin
      if Total = 0 then
        Result := Failure(Error);
      Break;
    end;
    if (Receipt.ByteCount > 0) and (CopyToUser(BufferAddress + Total, Buffer, Receipt.ByteCount) <> ErrorNone) then
    begin
      DropReceiptObjects(Receipt, 0);
      if Total = 0 then
        Result := Failure(ErrorBadAddress);
      Break;
    end;
    if Total = 0 then
      First := Receipt
    else
      DropReceiptObjects(Receipt, 0);
    Total := Total + Receipt.ByteCount;
    { A datagram, the end of the stream, a peek, objects (they go with
      the bytes they came with): one round. }
    if (Socket^.Kind <> LocalSocketStream) or Receipt.EndOfStream or (Receipt.ByteCount = 0) or
       ((Flags and LocalMessagePeek) <> 0) or (First.PassedCount > 0) or (Total >= Length) then
      Break;
    if Length - Total < BufferSize then
      BufferSize := Length - Total;
    RoundFlags := (Flags or LocalReceiveStopAtPassed) and not LongWord(LocalMessageWaitAll);
    if (Flags and LocalMessageWaitAll) = 0 then
      RoundFlags := RoundFlags or LocalMessageDontWait
    else
      RoundFlags := RoundFlags and not LongWord(LocalMessageDontWait);
  until False;
  if Total > 0 then
    Result := Int64(Total);
  FreeKernelMemory(Buffer);
end;

function PerformReceiveLocalMessage(Handle: Int64; MessageAddress, Flags: QWord): Int64;
var
  Socket: PLocalSocket;
  Request: TAbiLocalMessage;
  Receipt: TLocalReceipt;
  Installed: LongWord;
  Cut: Boolean;
  Error: LongInt;
begin
  Error := CopyFromUser(@Request, MessageAddress, SizeOf(Request));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Result := ReceiveBytes(Socket, Request.BufferAddress, Request.Length,
    LongWord(Flags) and (LocalMessagePeek or LocalMessageDontWait or LocalMessageWaitAll), Receipt);
  DereferenceObject(Socket);
  if Result < 0 then
    Exit;
  Installed := InstallPassedObjects(Receipt, Request.HandlesAddress, Request.HandleCount, Cut);
  Request.HandleCount := Installed;
  Request.Flags := 0;
  if Receipt.Truncated then
    Request.Flags := Request.Flags or LocalMessageTruncated;
  if Cut then
    Request.Flags := Request.Flags or LocalMessageHandlesCut;
  Request.Credentials := Receipt.Sender;
  Error := ErrorNone;
  if Request.NameAddress <> 0 then
    Error := CopyToUser(Request.NameAddress, @Receipt.SenderName, SizeOf(Receipt.SenderName));
  if Error = ErrorNone then
    Error := CopyToUser(MessageAddress, @Request, SizeOf(Request));
  if Error <> ErrorNone then
    Result := Failure(Error);
end;

{ --- Asking ------------------------------------------------------------------- }

function PerformQueryLocalSocket(Handle: Int64; Which, BufferAddress: QWord): Int64;
var
  Socket: PLocalSocket;
  Name: TAbiLocalSocketName;
  Credentials: TAbiLocalCredentials;
  Kind: THandleKind;
  Body: Pointer;
  Error: LongInt;
begin
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
  begin
    Body := ReferenceHandle(Handle, Kind);
    if Body = nil then
      Exit(Failure(ErrorBadHandle));
    DereferenceObject(Body);
    if Kind = HandleKindSocket then
      Exit(Failure(ErrorUnsupported));
    Exit(Failure(ErrorBadHandle));
  end;
  Error := ErrorNone;
  Result := 0;
  case Which of
    LocalQueryKind:
      Result := Socket^.Kind;
    LocalQueryName:
      begin
        LockLocalSockets;
        Name := Socket^.Name;
        UnlockLocalSockets;
        Error := CopyToUser(BufferAddress, @Name, SizeOf(Name));
      end;
    LocalQueryPeerName, LocalQueryPeerCredentials:
      begin
        Error := GetLocalPeer(Socket, Name, Credentials);
        if Error = ErrorNone then
        begin
          if Which = LocalQueryPeerName then
            Error := CopyToUser(BufferAddress, @Name, SizeOf(Name))
          else
            Error := CopyToUser(BufferAddress, @Credentials, SizeOf(Credentials));
        end;
      end;
  else
    Error := ErrorInvalidArgument;
  end;
  DereferenceObject(Socket);
  if Error <> ErrorNone then
    Result := Failure(Error);
end;

{ --- The network socket calls ------------------------------------------------- }

function AcceptLocal(Socket: PLocalSocket; PeerAddress: QWord): Int64;
var
  Accepted: PLocalSocket;
  Address: TAbiSocketAddress;
  Error: LongInt;
begin
  Error := AcceptOnLocalSocket(Socket, Accepted);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := ErrorNone;
  if PeerAddress <> 0 then
  begin
    FillMemory(@Address, SizeOf(Address), 0);
    Address.Family := AddressFamilyLocal;
    Error := CopyToUser(PeerAddress, @Address, SizeOf(Address));
  end;
  if Error = ErrorNone then
    Result := InsertLocalSocketHandle(Accepted)
  else
    Result := Failure(Error);
  DereferenceObject(Accepted);
end;

function ReceivePlain(Socket: PLocalSocket; BufferAddress, Length: QWord; Flags: LongWord): Int64;
var
  Receipt: TLocalReceipt;
begin
  Result := ReceiveBytes(Socket, BufferAddress, Length, Flags, Receipt);
  { Objects nobody asked for are closed (as recv does). }
  DropReceiptObjects(Receipt, 0);
end;

function NetworkFlagsToLocal(Flags: QWord): LongWord;
begin
  Result := 0;
  if (Flags and SocketFlagPeek) <> 0 then
    Result := Result or LocalMessagePeek;
  if (Flags and SocketFlagDontWait) <> 0 then
    Result := Result or LocalMessageDontWait;
end;

function PerformSocketCallOnLocalSocket(Number: QWord; Handle: Int64; Argument1, Argument2,
  Argument3: QWord): Int64;
var
  Socket: PLocalSocket;
  Value: Int64;
  Error: LongInt;
begin
  Socket := ReferenceLocalSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  case Number of
    CallListenSocket: Result := Failure(ListenOnLocalSocket(Socket, LongWord(Argument1 and $FFFF)));
    CallAcceptSocket: Result := AcceptLocal(Socket, Argument1);
    CallSendSocket:
      Result := SendBytes(Socket, Argument1, Argument2, 0, 0, nil, (Argument3 and SocketFlagDontWait) <> 0);
    CallReceiveSocket: Result := ReceivePlain(Socket, Argument1, Argument2, NetworkFlagsToLocal(Argument3));
    CallShutdownSocket: Result := Failure(ShutdownLocalSocket(Socket, LongWord(Argument1 and $FF)));
    CallGetSocketOption:
      begin
        Error := GetLocalSocketOption(Socket, LongWord(Argument1), Value);
        if Error = ErrorNone then
          Result := Value
        else
          Result := Failure(Error);
      end;
    CallSetSocketOption: Result := Failure(SetLocalSocketOption(Socket, LongWord(Argument1), Int64(Argument2)));
    CallWaitForSocket: Result := WaitForLocalSocket(Socket, LongWord(Argument1), Int64(Argument2));
  else
    { connect and the addresses take a network address. }
    Result := Failure(ErrorAddressFamilyNotSupported);
  end;
  DereferenceObject(Socket);
end;

function ReadLocalSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  ReferenceObject(ObjectBody);
  Result := ReceivePlain(PLocalSocket(ObjectBody), BufferAddress, ByteCount, 0);
  DereferenceObject(ObjectBody);
end;

function WriteLocalSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  ReferenceObject(ObjectBody);
  Result := SendBytes(PLocalSocket(ObjectBody), BufferAddress, ByteCount, 0, 0, nil, False);
  DereferenceObject(ObjectBody);
end;

end.

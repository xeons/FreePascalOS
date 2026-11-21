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
  One end of the browser's channel to a content process, carrying
  protocol messages (WebIpc.Messages) in pieces (WebIpc.Fragments).

  Sending never waits. A channel queues at most 64 messages at the
  other end and then refuses more (ErrorWouldBlock) rather than make
  the sender wait; the endpoint keeps what was refused, in order, and
  everything sent after it, until Flush gets it through. Whoever owns
  the endpoint calls Flush while HasPending (the browser's IPC thread
  and the content process's loop wait at most a few milliseconds while
  something is pending). So a renderer that stops reading never blocks
  the browser: its messages pile up in the browser's memory until the
  renderer is declared hung and ended.

  Sending is thread safe (the page thread, network threads and the GUI
  thread all send); receiving is for one thread. Handles given to Send
  are the endpoint's from then on: closed once the kernel took its own
  reference with the message (or when the message cannot go).
}
unit WebIpc.Endpoints;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebIpc.Messages,
  WebIpc.Fragments;

type
  TIpcReceiveStatus = (IpcReceived, IpcNothing, IpcBroken);

  TIpcEndpoint = class
  private
    FChannel: Int64;
    FLock: TRTLCriticalSection;
    FPending: TList;
    FReassembler: TIpcReassembler;
    FBroken: Boolean;
    FReceiveBuffer: TBytes;
    FSentCount: QWord;
    function TrySend(Item: TObject): LongInt;
    procedure DropPending;
  public
    { Takes Channel (closed with the endpoint). }
    constructor Create(Channel: Int64);
    destructor Destroy; override;
    { Queues or sends the message; False once the channel is broken. }
    function Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes;
      const Handles: array of Int64): Boolean; overload;
    function Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): Boolean; overload;
    { Sends what is waiting; True when nothing is left. }
    function Flush: Boolean;
    function HasPending: Boolean;
    { One whole message, if one is there (the caller frees it). A peer
      that sent pieces that do not fit together counts as broken. }
    function Receive(out Message: TIpcMessage): TIpcReceiveStatus;
    { Closes the channel (the other side sees it broken). }
    procedure Close;
    property Channel: Int64 read FChannel;
    property Broken: Boolean read FBroken;
    { Channel messages sent so far. }
    property SentCount: QWord read FSentCount;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  WebIpc.Wire;

type
  TPendingChunk = class
  public
    Chunk: TBytes;
    Handles: array of Int64;
    destructor Destroy; override;
  end;

destructor TPendingChunk.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Handles) do
    if Handles[Index] >= 0 then
      CloseHandle(Handles[Index]);
  inherited Destroy;
end;

constructor TIpcEndpoint.Create(Channel: Int64);
begin
  inherited Create;
  FChannel := Channel;
  InitCriticalSection(FLock);
  FPending := TList.Create;
  FReassembler := TIpcReassembler.Create;
  SetLength(FReceiveBuffer, ChannelMessageLimit);
end;

destructor TIpcEndpoint.Destroy;
begin
  Close;
  DropPending;
  FPending.Free;
  FReassembler.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TIpcEndpoint.DropPending;
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for Index := 0 to FPending.Count - 1 do
      TPendingChunk(FPending[Index]).Free;
    FPending.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TIpcEndpoint.Close;
begin
  if FChannel >= 0 then
  begin
    CloseHandle(FChannel);
    FChannel := -1;
  end;
  FBroken := True;
end;

{ Under the lock. }
function TIpcEndpoint.TrySend(Item: TObject): LongInt;
var
  Pending: TPendingChunk;
  Index: Integer;
begin
  Pending := TPendingChunk(Item);
  Result := SendMessage(FChannel, @Pending.Chunk[0], Length(Pending.Chunk), Pending.Handles);
  if Result = ErrorNone then
  begin
    Inc(FSentCount);
    { The message holds its own references now. }
    for Index := 0 to High(Pending.Handles) do
    begin
      CloseHandle(Pending.Handles[Index]);
      Pending.Handles[Index] := -1;
    end;
  end;
end;

function TIpcEndpoint.Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes;
  const Handles: array of Int64): Boolean;
var
  Pieces: TFragmentList;
  Index, HandleIndex: Integer;
  Pending: TPendingChunk;
  Error: LongInt;
begin
  Pieces := SplitMessage(Kind, ViewId, RequestId, Payload);
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(Pieces) do
    begin
      Pending := TPendingChunk.Create;
      Pending.Chunk := Pieces[Index];
      if Index = 0 then
      begin
        SetLength(Pending.Handles, Length(Handles));
        for HandleIndex := 0 to High(Handles) do
          Pending.Handles[HandleIndex] := Handles[HandleIndex];
      end;
      if FBroken then
      begin
        Pending.Free;
        Continue;
      end;
      if FPending.Count = 0 then
      begin
        Error := TrySend(Pending);
        if Error = ErrorNone then
        begin
          Pending.Free;
          Continue;
        end;
        if Error <> ErrorWouldBlock then
        begin
          FBroken := True;
          Pending.Free;
          Continue;
        end;
      end;
      FPending.Add(Pending);
    end;
    Result := not FBroken;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TIpcEndpoint.Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): Boolean;
begin
  Result := Send(Kind, ViewId, RequestId, Payload, []);
end;

function TIpcEndpoint.Flush: Boolean;
var
  Error: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    while (FPending.Count > 0) and not FBroken do
    begin
      Error := TrySend(TObject(FPending[0]));
      if Error = ErrorWouldBlock then
        Break;
      if Error <> ErrorNone then
        FBroken := True;
      TPendingChunk(FPending[0]).Free;
      FPending.Delete(0);
    end;
    Result := FPending.Count = 0;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FBroken then
    DropPending;
end;

function TIpcEndpoint.HasPending: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FPending.Count > 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TIpcEndpoint.Receive(out Message: TIpcMessage): TIpcReceiveStatus;
var
  Handles: array[0..7] of Int64;
  Length_, HandleCount: QWord;
  Error: LongInt;
  Chunk: TBytes;
  Index: Integer;
begin
  Message := nil;
  if FChannel < 0 then
    Exit(IpcBroken);
  repeat
    Error := ReceiveMessage(FChannel, @FReceiveBuffer[0], Length(FReceiveBuffer), Length_, Handles, HandleCount);
    if Error = ErrorWouldBlock then
      Exit(IpcNothing);
    if Error <> ErrorNone then
    begin
      FBroken := True;
      Exit(IpcBroken);
    end;
    Chunk := nil;
    SetLength(Chunk, Length_);
    if Length_ > 0 then
      Move(FReceiveBuffer[0], Chunk[0], Length_);
    try
      Message := FReassembler.Feed(Chunk, Slice(Handles, HandleCount));
    except
      on EIpcMalformed do
      begin
        for Index := 0 to Integer(HandleCount) - 1 do
          CloseHandle(Handles[Index]);
        FBroken := True;
        Exit(IpcBroken);
      end;
    end;
  until Message <> nil;
  Result := IpcReceived;
end;

end.

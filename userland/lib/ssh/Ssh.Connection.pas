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
  The connection protocol (RFC 4254), for either side: channels, their
  windows and their requests, several at once over one connection, and
  global requests.

  A program says what a channel is by deriving from TSshChannel (the
  handlers of its requests, data and end). Channels the peer opens come
  through OnChannelOpen, which makes one or refuses; a channel may
  answer later (DeferOpenConfirmation, then ConfirmOpen or RejectOpen),
  as a forwarded connection does once its socket has connected.
  Channels this side opens go through OpenChannel and hear back in
  HandleOpenConfirmed or HandleOpenFailed.

  Data to send is queued on the channel (SendData, SendErrorData) and
  goes out in Flush as far as the peer's window and largest packet
  allow; data received counts against the window this side gave, which
  grows again as the program says it took the data (InputConsumed), so
  a peer cannot send more than the program keeps up with. Finish ends a
  channel the orderly way once its output is out: EOF, exit-status (if
  any), CLOSE.

  Global requests go to OnGlobalRequest (refused without one); this
  side's own (SendGlobalRequest) get their replies in order.
}
unit Ssh.Connection;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Wire,
  Ssh.Transport;

const
  { What this side lets the peer send before it must wait. }
  ChannelInitialWindow = 2 * 1024 * 1024;
  ChannelMaximumPacket = 32 * 1024;

type
  TSshConnection = class;

  TSshChannelState = (ChannelStateOpen, ChannelStateOpening, ChannelStateAwaitingConfirmation, ChannelStateFailed);

  TSshChannel = class
  private
    FConnection: TSshConnection;
    FState: TSshChannelState;
    FDeferOpenConfirmation: Boolean;
    FLocalId: LongWord;
    FRemoteId: LongWord;
    FRemoteWindow: QWord;
    FRemoteMaximumPacket: LongWord;
    FLocalWindow: QWord;
    FConsumed: QWord;
    FOutput: string;
    FErrorOutput: string;
    FEofSent: Boolean;
    FEofReceived: Boolean;
    FCloseSent: Boolean;
    FCloseReceived: Boolean;
    FCloseReplyDeferred: Boolean;
    FFinishRequested: Boolean;
    FEofRequested: Boolean;
    FHasExitStatus: Boolean;
    FExitStatus: LongWord;
    FPendingReplies: Integer;
    procedure SendChunks(var Queue: string; Extended: Boolean);
    procedure Flush;
    procedure ReceiveData(const Data: string);
    procedure ReceiveExtendedData(DataType: LongWord; const Data: string);
    procedure ReceiveEof;
    procedure ReceiveClose;
    procedure SendCloseNow;
    procedure SendConfirmation;
  protected
    { A request of the peer's; True for success. Reader is past the
      request type and the want-reply flag. }
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; virtual;
    procedure HandleData(const Data: string); virtual;
    { Extended data (standard error from a server): taken and dropped. }
    procedure HandleExtendedData(DataType: LongWord; const Data: string); virtual;
    procedure HandleEof; virtual;
    { The peer closed the channel: let go of what it uses. This side's
      CLOSE goes back on its own, unless HandleClose sets
      CloseReplyDeferred: then the channel calls CloseNow itself once
      what it still has to write out (data received before the CLOSE)
      is out. }
    procedure HandleClose; virtual;
    property CloseReplyDeferred: Boolean read FCloseReplyDeferred write FCloseReplyDeferred;
    { Channels this side opened: the peer's answer. }
    procedure HandleOpenConfirmed; virtual;
    procedure HandleOpenFailed(Reason: LongWord; const Description: string); virtual;
    { The reply to a request sent with SendRequestWithReply. }
    procedure HandleRequestReply(Succeeded: Boolean); virtual;
  public
    constructor Create(Connection: TSshConnection);
    procedure SendData(const Data: string);
    procedure SendErrorData(const Data: string);
    { A request without a reply (exit-status, exit-signal, ...). }
    procedure SendRequest(const RequestType, Data: string);
    { A request answered with HandleRequestReply. }
    procedure SendRequestWithReply(const RequestType, Data: string);
    { EOF once all output is sent, the channel staying open. }
    procedure SendEofWhenFlushed;
    { Once all output is sent: EOF, exit-status (when HasExitStatus),
      then CLOSE. }
    procedure Finish(HasExitStatus: Boolean; ExitStatus: LongWord);
    { CLOSE now, whatever is queued. }
    procedure CloseNow;
    { The program took Count bytes of the data received. }
    procedure InputConsumed(Count: QWord);
    { For a channel the peer opened with DeferOpenConfirmation set. }
    procedure ConfirmOpen;
    procedure RejectOpen(Reason: LongWord; const Description: string);
    function PendingOutput: Integer;
    function IsOpen: Boolean;
    property LocalId: LongWord read FLocalId;
    property State: TSshChannelState read FState;
    property EofReceived: Boolean read FEofReceived;
    property EofSent: Boolean read FEofSent;
    property CloseReceived: Boolean read FCloseReceived;
    property CloseSent: Boolean read FCloseSent;
    property Connection: TSshConnection read FConnection;
    { Set in the constructor of a channel that answers its open later. }
    property DeferOpenConfirmation: Boolean read FDeferOpenConfirmation write FDeferOpenConfirmation;
  end;

  { Makes the channel for an open request of ChannelType (Reader is
    past the peer's id, window and packet size), or returns nil with
    a failure reason (OpenUnknownChannelType, ...). }
  TSshChannelOpenEvent = function(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
    out FailureReason: LongWord): TSshChannel of object;

  { A global request of the peer's (Reader past the name and the
    want-reply flag); True for success, with ReplyData after
    REQUEST_SUCCESS. }
  TSshGlobalRequestEvent = function(Connection: TSshConnection; const RequestName: string; var Reader: TSshReader;
    out ReplyData: string): Boolean of object;

  { The reply to one of this side's global requests. }
  TSshGlobalReplyEvent = procedure(Succeeded: Boolean; const ReplyData: string) of object;

  TSshConnection = class
  private
    FTransport: TSshTransport;
    FChannels: array of TSshChannel;
    FNextLocalId: LongWord;
    FOnChannelOpen: TSshChannelOpenEvent;
    FOnGlobalRequest: TSshGlobalRequestEvent;
    FPendingGlobalReplies: array of TSshGlobalReplyEvent;
    function FindChannel(LocalId: LongWord): TSshChannel;
    procedure AddChannel(Channel: TSshChannel);
    procedure HandleChannelOpen(const Payload: string);
    procedure HandleGlobalRequest(const Payload: string);
    procedure HandleGlobalReply(Succeeded: Boolean; const Payload: string);
    procedure HandleChannelMessage(MessageType: Byte; const Payload: string);
    procedure RemoveFinishedChannels;
  public
    constructor Create(Transport: TSshTransport);
    destructor Destroy; override;
    { Handles the connection protocol's messages; False for others. }
    function HandleMessage(const Message: TSshReceivedMessage): Boolean;
    { Opens a channel of this side's: Extra follows the window and
      packet size in CHANNEL_OPEN. The connection owns the channel. }
    procedure OpenChannel(Channel: TSshChannel; const ChannelType, Extra: string);
    procedure SendGlobalRequest(const RequestName, Data: string; WantReply: Boolean; OnReply: TSshGlobalReplyEvent);
    function PendingGlobalReplies: Integer;
    { Sends what the channels have queued and frees the channels closed
      both ways. }
    procedure Flush;
    function ChannelCount: Integer;
    function ChannelAt(Index: Integer): TSshChannel;
    property Transport: TSshTransport read FTransport;
    property OnChannelOpen: TSshChannelOpenEvent read FOnChannelOpen write FOnChannelOpen;
    property OnGlobalRequest: TSshGlobalRequestEvent read FOnGlobalRequest write FOnGlobalRequest;
  end;

implementation

uses
  SysUtils,
  Ssh.Constants;

constructor TSshChannel.Create(Connection: TSshConnection);
begin
  inherited Create;
  FConnection := Connection;
  FLocalWindow := ChannelInitialWindow;
end;

function TSshChannel.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
begin
  Result := False;
end;

procedure TSshChannel.HandleData(const Data: string);
begin
  InputConsumed(Length(Data));
end;

procedure TSshChannel.HandleExtendedData(DataType: LongWord; const Data: string);
begin
  InputConsumed(Length(Data));
end;

procedure TSshChannel.HandleEof;
begin
end;

procedure TSshChannel.HandleClose;
begin
end;

procedure TSshChannel.HandleOpenConfirmed;
begin
end;

procedure TSshChannel.HandleOpenFailed(Reason: LongWord; const Description: string);
begin
end;

procedure TSshChannel.HandleRequestReply(Succeeded: Boolean);
begin
end;

function TSshChannel.IsOpen: Boolean;
begin
  Result := (FState = ChannelStateOpen) and not FCloseSent and not FCloseReceived;
end;

procedure TSshChannel.SendData(const Data: string);
begin
  if not FCloseSent and not FEofSent then
    FOutput := FOutput + Data;
end;

procedure TSshChannel.SendErrorData(const Data: string);
begin
  if not FCloseSent and not FEofSent then
    FErrorOutput := FErrorOutput + Data;
end;

procedure TSshChannel.SendRequest(const RequestType, Data: string);
begin
  if FCloseSent or (FState <> ChannelStateOpen) then
    Exit;
  FConnection.FTransport.Send(SshByte(MessageChannelRequest) + SshUInt32(FRemoteId) + SshString(RequestType) +
    SshBoolean(False) + Data);
end;

procedure TSshChannel.SendRequestWithReply(const RequestType, Data: string);
begin
  if FCloseSent or (FState <> ChannelStateOpen) then
  begin
    HandleRequestReply(False);
    Exit;
  end;
  Inc(FPendingReplies);
  FConnection.FTransport.Send(SshByte(MessageChannelRequest) + SshUInt32(FRemoteId) + SshString(RequestType) +
    SshBoolean(True) + Data);
end;

procedure TSshChannel.SendEofWhenFlushed;
begin
  FEofRequested := True;
end;

procedure TSshChannel.Finish(HasExitStatus: Boolean; ExitStatus: LongWord);
begin
  if FFinishRequested then
    Exit;
  FFinishRequested := True;
  FHasExitStatus := HasExitStatus;
  FExitStatus := ExitStatus;
end;

procedure TSshChannel.CloseNow;
begin
  if FState = ChannelStateAwaitingConfirmation then
  begin
    RejectOpen(OpenConnectFailed, 'closed');
    Exit;
  end;
  if FState = ChannelStateOpen then
    SendCloseNow;
end;

procedure TSshChannel.InputConsumed(Count: QWord);
begin
  FConsumed := FConsumed + Count;
  if FCloseSent or FCloseReceived or FEofReceived or (FState <> ChannelStateOpen) then
    Exit;
  if FConsumed >= ChannelInitialWindow div 2 then
  begin
    FConnection.FTransport.Send(SshByte(MessageChannelWindowAdjust) + SshUInt32(FRemoteId) +
      SshUInt32(LongWord(FConsumed)));
    FLocalWindow := FLocalWindow + FConsumed;
    FConsumed := 0;
  end;
end;

procedure TSshChannel.SendConfirmation;
begin
  FConnection.FTransport.Send(SshByte(MessageChannelOpenConfirmation) + SshUInt32(FRemoteId) + SshUInt32(FLocalId) +
    SshUInt32(ChannelInitialWindow) + SshUInt32(ChannelMaximumPacket));
end;

procedure TSshChannel.ConfirmOpen;
begin
  if FState <> ChannelStateAwaitingConfirmation then
    Exit;
  FState := ChannelStateOpen;
  SendConfirmation;
end;

procedure TSshChannel.RejectOpen(Reason: LongWord; const Description: string);
begin
  if FState <> ChannelStateAwaitingConfirmation then
    Exit;
  FState := ChannelStateFailed;
  FConnection.FTransport.Send(SshByte(MessageChannelOpenFailure) + SshUInt32(FRemoteId) + SshUInt32(Reason) +
    SshString(Description) + SshString(''));
end;

function TSshChannel.PendingOutput: Integer;
begin
  Result := Length(FOutput) + Length(FErrorOutput);
end;

procedure TSshChannel.SendChunks(var Queue: string; Extended: Boolean);
var
  Size: QWord;
  Chunk: string;
begin
  while (Queue <> '') and (FRemoteWindow > 0) do
  begin
    Size := Length(Queue);
    if Size > FRemoteWindow then
      Size := FRemoteWindow;
    if Size > FRemoteMaximumPacket then
      Size := FRemoteMaximumPacket;
    if Size > ChannelMaximumPacket then
      Size := ChannelMaximumPacket;
    Chunk := Copy(Queue, 1, Integer(Size));
    Delete(Queue, 1, Integer(Size));
    if Extended then
      FConnection.FTransport.Send(SshByte(MessageChannelExtendedData) + SshUInt32(FRemoteId) +
        SshUInt32(ExtendedDataStandardError) + SshString(Chunk))
    else
      FConnection.FTransport.Send(SshByte(MessageChannelData) + SshUInt32(FRemoteId) + SshString(Chunk));
    FRemoteWindow := FRemoteWindow - Size;
  end;
end;

procedure TSshChannel.SendCloseNow;
begin
  if FCloseSent then
    Exit;
  FConnection.FTransport.Send(SshByte(MessageChannelClose) + SshUInt32(FRemoteId));
  FCloseSent := True;
  FOutput := '';
  FErrorOutput := '';
end;

procedure TSshChannel.Flush;
begin
  if FCloseSent or (FState <> ChannelStateOpen) then
    Exit;
  if FRemoteMaximumPacket = 0 then
    FRemoteMaximumPacket := 1;
  SendChunks(FOutput, False);
  SendChunks(FErrorOutput, True);
  if FEofRequested and not FEofSent and not FCloseReceived and (PendingOutput = 0) then
  begin
    FConnection.FTransport.Send(SshByte(MessageChannelEof) + SshUInt32(FRemoteId));
    FEofSent := True;
  end;
  if FFinishRequested and (PendingOutput = 0) then
  begin
    if not FEofSent and not FCloseReceived then
    begin
      FConnection.FTransport.Send(SshByte(MessageChannelEof) + SshUInt32(FRemoteId));
      FEofSent := True;
    end;
    if FHasExitStatus and not FCloseReceived then
      SendRequest('exit-status', SshUInt32(FExitStatus));
    SendCloseNow;
  end;
end;

procedure TSshChannel.ReceiveData(const Data: string);
begin
  if FEofReceived or FCloseReceived then
    raise ESshProtocolError.Create('data after EOF');
  if QWord(Length(Data)) > FLocalWindow then
    raise ESshProtocolError.Create('data beyond the channel window');
  FLocalWindow := FLocalWindow - QWord(Length(Data));
  HandleData(Data);
end;

procedure TSshChannel.ReceiveExtendedData(DataType: LongWord; const Data: string);
begin
  if FEofReceived or FCloseReceived then
    raise ESshProtocolError.Create('data after EOF');
  if QWord(Length(Data)) > FLocalWindow then
    raise ESshProtocolError.Create('data beyond the channel window');
  FLocalWindow := FLocalWindow - QWord(Length(Data));
  HandleExtendedData(DataType, Data);
end;

procedure TSshChannel.ReceiveEof;
begin
  if FEofReceived then
    Exit;
  FEofReceived := True;
  HandleEof;
end;

procedure TSshChannel.ReceiveClose;
begin
  if FCloseReceived then
    Exit;
  FCloseReceived := True;
  HandleClose;
  if not FCloseReplyDeferred then
    SendCloseNow;
end;

constructor TSshConnection.Create(Transport: TSshTransport);
begin
  inherited Create;
  FTransport := Transport;
end;

destructor TSshConnection.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FChannels) do
    FChannels[Index].Free;
  FChannels := nil;
  inherited Destroy;
end;

function TSshConnection.FindChannel(LocalId: LongWord): TSshChannel;
var
  Index: Integer;
begin
  for Index := 0 to High(FChannels) do
    if (FChannels[Index].FLocalId = LocalId) and (FChannels[Index].FState <> ChannelStateFailed) then
      Exit(FChannels[Index]);
  raise ESshProtocolError.Create('no such channel');
end;

procedure TSshConnection.AddChannel(Channel: TSshChannel);
var
  Count: Integer;
begin
  Channel.FLocalId := FNextLocalId;
  Inc(FNextLocalId);
  Count := Length(FChannels);
  SetLength(FChannels, Count + 1);
  FChannels[Count] := Channel;
end;

function TSshConnection.HandleMessage(const Message: TSshReceivedMessage): Boolean;
var
  MessageType: Byte;
begin
  MessageType := Ord(Message.Payload[1]);
  Result := True;
  case MessageType of
    MessageGlobalRequest: HandleGlobalRequest(Message.Payload);
    MessageChannelOpen: HandleChannelOpen(Message.Payload);
    MessageChannelOpenConfirmation, MessageChannelOpenFailure,
    MessageChannelWindowAdjust, MessageChannelData, MessageChannelExtendedData, MessageChannelEof,
    MessageChannelClose, MessageChannelRequest, MessageChannelSuccess, MessageChannelFailure:
      HandleChannelMessage(MessageType, Message.Payload);
    MessageRequestSuccess: HandleGlobalReply(True, Message.Payload);
    MessageRequestFailure: HandleGlobalReply(False, Message.Payload);
  else
    Result := False;
  end;
end;

procedure TSshConnection.HandleGlobalRequest(const Payload: string);
var
  Reader: TSshReader;
  RequestName, ReplyData: string;
  WantReply, Succeeded: Boolean;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  RequestName := Reader.ReadString;
  WantReply := Reader.ReadBoolean;
  Succeeded := False;
  ReplyData := '';
  if Assigned(FOnGlobalRequest) then
  begin
    try
      Succeeded := FOnGlobalRequest(Self, RequestName, Reader, ReplyData);
    except
      on ESshProtocolError do
        Succeeded := False;
    end;
  end;
  if WantReply then
    if Succeeded then
      FTransport.Send(SshByte(MessageRequestSuccess) + ReplyData)
    else
      FTransport.Send(SshByte(MessageRequestFailure));
end;

procedure TSshConnection.SendGlobalRequest(const RequestName, Data: string; WantReply: Boolean;
  OnReply: TSshGlobalReplyEvent);
begin
  FTransport.Send(SshByte(MessageGlobalRequest) + SshString(RequestName) + SshBoolean(WantReply) + Data);
  if WantReply then
  begin
    SetLength(FPendingGlobalReplies, Length(FPendingGlobalReplies) + 1);
    FPendingGlobalReplies[High(FPendingGlobalReplies)] := OnReply;
  end;
end;

function TSshConnection.PendingGlobalReplies: Integer;
begin
  Result := Length(FPendingGlobalReplies);
end;

procedure TSshConnection.HandleGlobalReply(Succeeded: Boolean; const Payload: string);
var
  OnReply: TSshGlobalReplyEvent;
  Index: Integer;
begin
  if Length(FPendingGlobalReplies) = 0 then
    Exit;
  OnReply := FPendingGlobalReplies[0];
  for Index := 1 to High(FPendingGlobalReplies) do
    FPendingGlobalReplies[Index - 1] := FPendingGlobalReplies[Index];
  SetLength(FPendingGlobalReplies, Length(FPendingGlobalReplies) - 1);
  if Assigned(OnReply) then
    OnReply(Succeeded, Copy(Payload, 2, MaxInt));
end;

procedure TSshConnection.OpenChannel(Channel: TSshChannel; const ChannelType, Extra: string);
begin
  AddChannel(Channel);
  Channel.FState := ChannelStateOpening;
  FTransport.Send(SshByte(MessageChannelOpen) + SshString(ChannelType) + SshUInt32(Channel.FLocalId) +
    SshUInt32(ChannelInitialWindow) + SshUInt32(ChannelMaximumPacket) + Extra);
end;

procedure TSshConnection.HandleChannelOpen(const Payload: string);
var
  Reader: TSshReader;
  ChannelType: string;
  RemoteId, RemoteWindow, RemoteMaximumPacket: LongWord;
  Channel: TSshChannel;
  FailureReason: LongWord;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  ChannelType := Reader.ReadString;
  RemoteId := Reader.ReadUInt32;
  RemoteWindow := Reader.ReadUInt32;
  RemoteMaximumPacket := Reader.ReadUInt32;
  Channel := nil;
  FailureReason := OpenUnknownChannelType;
  if Assigned(FOnChannelOpen) then
  begin
    try
      Channel := FOnChannelOpen(Self, ChannelType, Reader, FailureReason);
    except
      on ESshProtocolError do
      begin
        Channel := nil;
        FailureReason := OpenConnectFailed;
      end;
    end;
  end;
  if Channel = nil then
  begin
    FTransport.Send(SshByte(MessageChannelOpenFailure) + SshUInt32(RemoteId) + SshUInt32(FailureReason) +
      SshString('cannot open a channel of type ' + ChannelType) + SshString(''));
    Exit;
  end;
  AddChannel(Channel);
  Channel.FRemoteId := RemoteId;
  Channel.FRemoteWindow := RemoteWindow;
  Channel.FRemoteMaximumPacket := RemoteMaximumPacket;
  if Channel.FDeferOpenConfirmation then
    Channel.FState := ChannelStateAwaitingConfirmation
  else
  begin
    Channel.FState := ChannelStateOpen;
    Channel.SendConfirmation;
  end;
end;

procedure TSshConnection.HandleChannelMessage(MessageType: Byte; const Payload: string);
var
  Reader: TSshReader;
  Channel: TSshChannel;
  RequestType, Description: string;
  WantReply: Boolean;
  Succeeded: Boolean;
  Reason, DataType: LongWord;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Channel := FindChannel(Reader.ReadUInt32);
  if (Channel.FState = ChannelStateOpening) <>
    (MessageType in [MessageChannelOpenConfirmation, MessageChannelOpenFailure]) then
    raise ESshProtocolError.Create('channel message out of turn');
  if Channel.FState = ChannelStateAwaitingConfirmation then
    raise ESshProtocolError.Create('channel message before the channel was confirmed');
  case MessageType of
    MessageChannelOpenConfirmation:
      begin
        Channel.FRemoteId := Reader.ReadUInt32;
        Channel.FRemoteWindow := Reader.ReadUInt32;
        Channel.FRemoteMaximumPacket := Reader.ReadUInt32;
        Channel.FState := ChannelStateOpen;
        Channel.HandleOpenConfirmed;
      end;
    MessageChannelOpenFailure:
      begin
        Reason := Reader.ReadUInt32;
        Description := Reader.ReadString;
        Channel.FState := ChannelStateFailed;
        Channel.HandleOpenFailed(Reason, Description);
      end;
    MessageChannelWindowAdjust:
      Channel.FRemoteWindow := Channel.FRemoteWindow + Reader.ReadUInt32;
    MessageChannelData:
      Channel.ReceiveData(Reader.ReadString);
    MessageChannelExtendedData:
      begin
        DataType := Reader.ReadUInt32;
        Channel.ReceiveExtendedData(DataType, Reader.ReadString);
      end;
    MessageChannelEof:
      Channel.ReceiveEof;
    MessageChannelClose:
      Channel.ReceiveClose;
    MessageChannelRequest:
      begin
        RequestType := Reader.ReadString;
        WantReply := Reader.ReadBoolean;
        Succeeded := False;
        if not Channel.FCloseSent then
        begin
          try
            Succeeded := Channel.HandleRequest(RequestType, Reader);
          except
            on ESshProtocolError do
              Succeeded := False;
          end;
        end;
        if WantReply and not Channel.FCloseSent then
          if Succeeded then
            FTransport.Send(SshByte(MessageChannelSuccess) + SshUInt32(Channel.FRemoteId))
          else
            FTransport.Send(SshByte(MessageChannelFailure) + SshUInt32(Channel.FRemoteId));
      end;
    MessageChannelSuccess, MessageChannelFailure:
      if Channel.FPendingReplies > 0 then
      begin
        Dec(Channel.FPendingReplies);
        Channel.HandleRequestReply(MessageType = MessageChannelSuccess);
      end;
  end;
end;

procedure TSshConnection.RemoveFinishedChannels;
var
  Index, Kept: Integer;
  Finished: Boolean;
begin
  Kept := 0;
  for Index := 0 to High(FChannels) do
  begin
    Finished := (FChannels[Index].FState = ChannelStateFailed) or
      (FChannels[Index].FCloseSent and FChannels[Index].FCloseReceived);
    if Finished then
      FChannels[Index].Free
    else
    begin
      FChannels[Kept] := FChannels[Index];
      Inc(Kept);
    end;
  end;
  SetLength(FChannels, Kept);
end;

procedure TSshConnection.Flush;
var
  Index: Integer;
begin
  for Index := 0 to High(FChannels) do
    FChannels[Index].Flush;
  RemoveFinishedChannels;
end;

function TSshConnection.ChannelCount: Integer;
begin
  Result := Length(FChannels);
end;

function TSshConnection.ChannelAt(Index: Integer): TSshChannel;
begin
  Result := FChannels[Index];
end;

end.

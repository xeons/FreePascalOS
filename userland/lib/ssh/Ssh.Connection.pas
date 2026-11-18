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
  The connection protocol (RFC 4254): channels, their windows and their
  requests, several at once over one connection.

  The server program says what a channel is by deriving from
  TSshChannel (the handlers of its requests, data and end) and by
  OnChannelOpen, which makes one for each channel the client opens or
  refuses it. Data to send is queued on the channel (SendData,
  SendErrorData) and goes out in Flush as far as the client's window
  and largest packet allow; data received counts against the window the
  server gave, which grows again as the program says it took the data
  (InputConsumed), so a client cannot send more than the program keeps
  up with. Finish ends a channel the orderly way once its output is out:
  EOF, exit-status, CLOSE.

  Global requests are refused (with a reply when one is wanted).
}
unit Ssh.Connection;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Wire,
  Ssh.ServerTransport;

const
  { What the server lets a client send before it must wait. }
  ChannelInitialWindow = 2 * 1024 * 1024;
  ChannelMaximumPacket = 32 * 1024;

type
  TSshConnection = class;

  TSshChannel = class
  private
    FConnection: TSshConnection;
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
    FFinishRequested: Boolean;
    FHasExitStatus: Boolean;
    FExitStatus: LongWord;
    procedure SendChunks(var Queue: string; Extended: Boolean);
    procedure Flush;
    procedure ReceiveData(const Data: string);
    procedure ReceiveEof;
    procedure ReceiveClose;
    procedure SendCloseNow;
  protected
    { A request of the client's; True for success. Reader is past the
      request type and the want-reply flag. }
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; virtual;
    procedure HandleData(const Data: string); virtual;
    procedure HandleEof; virtual;
    { The client closed the channel: let go of what it uses. The server's
      CLOSE goes back on its own. }
    procedure HandleClose; virtual;
  public
    constructor Create(Connection: TSshConnection);
    procedure SendData(const Data: string);
    procedure SendErrorData(const Data: string);
    { A request without a reply (exit-status, exit-signal, ...). }
    procedure SendRequest(const RequestType, Data: string);
    { Once all output is sent: EOF, exit-status (when HasExitStatus),
      then CLOSE. }
    procedure Finish(HasExitStatus: Boolean; ExitStatus: LongWord);
    { The program took Count bytes of the data received. }
    procedure InputConsumed(Count: QWord);
    function PendingOutput: Integer;
    property LocalId: LongWord read FLocalId;
    property EofReceived: Boolean read FEofReceived;
    property CloseReceived: Boolean read FCloseReceived;
    property CloseSent: Boolean read FCloseSent;
    property Connection: TSshConnection read FConnection;
  end;

  { Makes the channel for an open request of ChannelType (Reader is
    past the client's id, window and packet size), or returns nil with
    a failure reason (OpenUnknownChannelType, ...). }
  TSshChannelOpenEvent = function(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
    out FailureReason: LongWord): TSshChannel of object;

  TSshConnection = class
  private
    FTransport: TSshServerTransport;
    FChannels: array of TSshChannel;
    FNextLocalId: LongWord;
    FOnChannelOpen: TSshChannelOpenEvent;
    function FindChannel(LocalId: LongWord): TSshChannel;
    procedure HandleChannelOpen(const Payload: string);
    procedure HandleGlobalRequest(const Payload: string);
    procedure HandleChannelMessage(MessageType: Byte; const Payload: string);
    procedure RemoveFinishedChannels;
  public
    constructor Create(Transport: TSshServerTransport);
    destructor Destroy; override;
    { Handles the connection protocol's messages; False for others. }
    function HandleMessage(const Message: TSshReceivedMessage): Boolean;
    { Sends what the channels have queued and frees the channels closed
      both ways. }
    procedure Flush;
    function ChannelCount: Integer;
    function ChannelAt(Index: Integer): TSshChannel;
    property Transport: TSshServerTransport read FTransport;
    property OnChannelOpen: TSshChannelOpenEvent read FOnChannelOpen write FOnChannelOpen;
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

procedure TSshChannel.HandleEof;
begin
end;

procedure TSshChannel.HandleClose;
begin
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
  if FCloseSent then
    Exit;
  FConnection.FTransport.Send(SshByte(MessageChannelRequest) + SshUInt32(FRemoteId) + SshString(RequestType) +
    SshBoolean(False) + Data);
end;

procedure TSshChannel.Finish(HasExitStatus: Boolean; ExitStatus: LongWord);
begin
  if FFinishRequested then
    Exit;
  FFinishRequested := True;
  FHasExitStatus := HasExitStatus;
  FExitStatus := ExitStatus;
end;

procedure TSshChannel.InputConsumed(Count: QWord);
begin
  FConsumed := FConsumed + Count;
  if FCloseSent or FCloseReceived or FEofReceived then
    Exit;
  if FConsumed >= ChannelInitialWindow div 2 then
  begin
    FConnection.FTransport.Send(SshByte(MessageChannelWindowAdjust) + SshUInt32(FRemoteId) +
      SshUInt32(LongWord(FConsumed)));
    FLocalWindow := FLocalWindow + FConsumed;
    FConsumed := 0;
  end;
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
  if FCloseSent then
    Exit;
  if FRemoteMaximumPacket = 0 then
    FRemoteMaximumPacket := 1;
  SendChunks(FOutput, False);
  SendChunks(FErrorOutput, True);
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
  SendCloseNow;
end;

constructor TSshConnection.Create(Transport: TSshServerTransport);
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
    if FChannels[Index].FLocalId = LocalId then
      Exit(FChannels[Index]);
  raise ESshProtocolError.Create('no such channel');
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
    MessageChannelWindowAdjust, MessageChannelData, MessageChannelExtendedData, MessageChannelEof,
    MessageChannelClose, MessageChannelRequest, MessageChannelSuccess, MessageChannelFailure:
      HandleChannelMessage(MessageType, Message.Payload);
    MessageRequestSuccess, MessageRequestFailure:
      { Answers to requests the server never makes. }
      ;
  else
    Result := False;
  end;
end;

procedure TSshConnection.HandleGlobalRequest(const Payload: string);
var
  Reader: TSshReader;
  WantReply: Boolean;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Reader.ReadString;
  WantReply := Reader.ReadBoolean;
  if WantReply then
    FTransport.Send(SshByte(MessageRequestFailure));
end;

procedure TSshConnection.HandleChannelOpen(const Payload: string);
var
  Reader: TSshReader;
  ChannelType: string;
  RemoteId, RemoteWindow, RemoteMaximumPacket: LongWord;
  Channel: TSshChannel;
  FailureReason: LongWord;
  Count: Integer;
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
    Channel := FOnChannelOpen(Self, ChannelType, Reader, FailureReason);
  if Channel = nil then
  begin
    FTransport.Send(SshByte(MessageChannelOpenFailure) + SshUInt32(RemoteId) + SshUInt32(FailureReason) +
      SshString('cannot open a channel of type ' + ChannelType) + SshString(''));
    Exit;
  end;
  Channel.FLocalId := FNextLocalId;
  Inc(FNextLocalId);
  Channel.FRemoteId := RemoteId;
  Channel.FRemoteWindow := RemoteWindow;
  Channel.FRemoteMaximumPacket := RemoteMaximumPacket;
  Count := Length(FChannels);
  SetLength(FChannels, Count + 1);
  FChannels[Count] := Channel;
  FTransport.Send(SshByte(MessageChannelOpenConfirmation) + SshUInt32(RemoteId) + SshUInt32(Channel.FLocalId) +
    SshUInt32(ChannelInitialWindow) + SshUInt32(ChannelMaximumPacket));
end;

procedure TSshConnection.HandleChannelMessage(MessageType: Byte; const Payload: string);
var
  Reader: TSshReader;
  Channel: TSshChannel;
  RequestType: string;
  WantReply: Boolean;
  Succeeded: Boolean;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Channel := FindChannel(Reader.ReadUInt32);
  case MessageType of
    MessageChannelWindowAdjust:
      Channel.FRemoteWindow := Channel.FRemoteWindow + Reader.ReadUInt32;
    MessageChannelData:
      Channel.ReceiveData(Reader.ReadString);
    MessageChannelExtendedData:
      begin
        { No extended data is defined towards a server: counted and
          dropped. }
        Reader.ReadUInt32;
        RequestType := Reader.ReadString;
        if QWord(Length(RequestType)) > Channel.FLocalWindow then
          raise ESshProtocolError.Create('data beyond the channel window');
        Channel.FLocalWindow := Channel.FLocalWindow - QWord(Length(RequestType));
        Channel.InputConsumed(Length(RequestType));
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
      ;
  end;
end;

procedure TSshConnection.RemoveFinishedChannels;
var
  Index, Kept: Integer;
begin
  Kept := 0;
  for Index := 0 to High(FChannels) do
    if FChannels[Index].FCloseSent and FChannels[Index].FCloseReceived then
      FChannels[Index].Free
    else
    begin
      FChannels[Kept] := FChannels[Index];
      Inc(Kept);
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

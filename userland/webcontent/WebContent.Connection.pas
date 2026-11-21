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
  The content process's channel to the browser. Besides sending, it
  can ask and wait for the answer (Call): the page's thread waits for
  an alert's answer, the clipboard, a cookie, a local file. While it
  waits it answers pings (so a page showing a dialog is not taken for
  hung) and puts everything else aside, in order, for the loop to
  handle afterwards (Next).
}
unit WebContent.Connection;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebIpc.Messages,
  WebIpc.Endpoints;

type
  TContentConnection = class
  private
    FEndpoint: TIpcEndpoint;
    FDeferred: TList;
    FNextRequestId: LongWord;
    procedure AnswerPing(Message: TIpcMessage);
  public
    constructor Create(Channel: Int64);
    destructor Destroy; override;
    procedure Send(Kind: Word; ViewId: LongWord; const Payload: TBytes); overload;
    procedure Send(Kind: Word; ViewId: LongWord; const Payload: TBytes; const Handles: array of Int64); overload;
    procedure Reply(Request: TIpcMessage; const Payload: TBytes);
    { Sends a request and waits for its answer (the caller frees it); nil
      when the browser is gone or Timeout milliseconds passed. }
    function Call(Kind: Word; ViewId: LongWord; const Payload: TBytes; Timeout: Int64): TIpcMessage;
    { The next message to handle (a ping is answered here and not
      returned): one put aside, else one from the channel. }
    function Next(out Message: TIpcMessage): Boolean;
    function Broken: Boolean;
    property Endpoint: TIpcEndpoint read FEndpoint;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects;

constructor TContentConnection.Create(Channel: Int64);
begin
  inherited Create;
  FEndpoint := TIpcEndpoint.Create(Channel);
  FDeferred := TList.Create;
end;

destructor TContentConnection.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FDeferred.Count - 1 do
    TIpcMessage(FDeferred[Index]).Free;
  FDeferred.Free;
  FEndpoint.Free;
  inherited Destroy;
end;

function TContentConnection.Broken: Boolean;
begin
  Result := FEndpoint.Broken;
end;

procedure TContentConnection.Send(Kind: Word; ViewId: LongWord; const Payload: TBytes);
begin
  FEndpoint.Send(Kind, ViewId, 0, Payload, []);
end;

procedure TContentConnection.Send(Kind: Word; ViewId: LongWord; const Payload: TBytes; const Handles: array of Int64);
begin
  FEndpoint.Send(Kind, ViewId, 0, Payload, Handles);
end;

procedure TContentConnection.Reply(Request: TIpcMessage; const Payload: TBytes);
begin
  FEndpoint.Send(IpcReply, Request.ViewId, Request.RequestId, Payload, []);
end;

procedure TContentConnection.AnswerPing(Message: TIpcMessage);
begin
  FEndpoint.Send(IpcPong, 0, 0, Message.Payload, []);
end;

function TContentConnection.Call(Kind: Word; ViewId: LongWord; const Payload: TBytes; Timeout: Int64): TIpcMessage;
var
  RequestId: LongWord;
  Message: TIpcMessage;
  Status: TIpcReceiveStatus;
  Started: QWord;
  Wait: Int64;
begin
  Result := nil;
  Inc(FNextRequestId);
  if FNextRequestId = 0 then
    FNextRequestId := 1;
  RequestId := FNextRequestId;
  FEndpoint.Send(Kind, ViewId, RequestId, Payload, []);
  Started := GetTickCount64;
  repeat
    FEndpoint.Flush;
    Status := FEndpoint.Receive(Message);
    if Status = IpcBroken then
      Exit;
    if Status = IpcReceived then
    begin
      if (Message.Kind = IpcReply) and (Message.RequestId = RequestId) then
        Exit(Message);
      if Message.Kind = IpcPing then
      begin
        AnswerPing(Message);
        Message.Free;
      end
      else
        FDeferred.Add(Message);
      Continue;
    end;
    if (Timeout >= 0) and (GetTickCount64 - Started >= QWord(Timeout)) then
      Exit;
    if FEndpoint.HasPending then
      Wait := 5
    else
      Wait := 1000;
    WaitForHandle(FEndpoint.Channel, Wait);
  until False;
end;

function TContentConnection.Next(out Message: TIpcMessage): Boolean;
begin
  repeat
    if FDeferred.Count > 0 then
    begin
      Message := TIpcMessage(FDeferred[0]);
      FDeferred.Delete(0);
    end
    else if FEndpoint.Receive(Message) <> IpcReceived then
    begin
      Message := nil;
      Exit(False);
    end;
    if Message.Kind <> IpcPing then
      Exit(True);
    AnswerPing(Message);
    Message.Free;
  until False;
end;

end.

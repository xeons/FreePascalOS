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
  IndexedDB, the Cache API and navigator.storage of the content
  process's pages, kept by the browser's storage service: each request
  goes to the browser (IpcIndexedDbRequest, with the script context's
  client id and the origin; the browser refuses origins of other sites
  than this process's) and its reply comes back unchanged; a context
  that goes is told (IpcIndexedDbClientClosed); the service's notices
  for a context come as IpcIndexedDbNotice and are handed to its client.
}
unit WebContent.IndexedDb;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.IndexedDb.Service,
  WebIpc.Messages,
  WebContent.Connection;

type
  TContentIndexedDbBackend = class(TIndexedDbBackend)
  private
    FConnection: TContentConnection;
    FClients: TList;
    FIds: array of LongWord;
    FNextId: LongWord;
    function IdOf(Client: TIndexedDbClient; Assign: Boolean): Integer;
  public
    constructor Create(Connection: TContentConnection);
    destructor Destroy; override;
    function Execute(Client: TIndexedDbClient; const Origin: string; const Request: TBytes): TBytes; override;
    procedure ClientClosed(Client: TIndexedDbClient); override;
    { An IpcIndexedDbNotice from the browser. }
    procedure DeliverNotice(Message: TIpcMessage);
  end;

implementation

uses
  Web.IndexedDb.Wire,
  WebIpc.NetworkMessages;

const
  RequestTimeout = 30000;

constructor TContentIndexedDbBackend.Create(Connection: TContentConnection);
begin
  inherited Create;
  FConnection := Connection;
  FClients := TList.Create;
end;

destructor TContentIndexedDbBackend.Destroy;
begin
  FClients.Free;
  inherited Destroy;
end;

{ The client's position in the lists (-1: unknown and not assigned). }
function TContentIndexedDbBackend.IdOf(Client: TIndexedDbClient; Assign: Boolean): Integer;
begin
  Result := FClients.IndexOf(Client);
  if (Result >= 0) or not Assign then
    Exit;
  Inc(FNextId);
  FClients.Add(Client);
  SetLength(FIds, FClients.Count);
  Result := FClients.Count - 1;
  FIds[Result] := FNextId;
end;

function FailureReply(const Text: string): TBytes;
var
  Writer: TIdbWriter;
begin
  Writer := TIdbWriter.Create;
  try
    Writer.WriteByte(IdbStatusUnknown);
    Writer.WriteRaw(Text);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function TContentIndexedDbBackend.Execute(Client: TIndexedDbClient; const Origin: string;
  const Request: TBytes): TBytes;
var
  Answer: TIpcMessage;
  Position: Integer;
begin
  Position := IdOf(Client, True);
  Answer := FConnection.Call(IpcIndexedDbRequest, 0, EncodeIndexedDbRequest(FIds[Position], Origin, Request),
    RequestTimeout);
  if Answer = nil then
    Exit(FailureReply('The storage service did not answer.'));
  try
    Result := Answer.Payload;
  finally
    Answer.Free;
  end;
  if Length(Result) = 0 then
    Result := FailureReply('The storage service refused the request.');
end;

procedure TContentIndexedDbBackend.ClientClosed(Client: TIndexedDbClient);
var
  Position, Last: Integer;
begin
  Position := IdOf(Client, False);
  if Position < 0 then
    Exit;
  FConnection.Send(IpcIndexedDbClientClosed, 0, EncodeIndexedDbNotice(FIds[Position], nil));
  Last := FClients.Count - 1;
  FIds[Position] := FIds[Last];
  FClients[Position] := FClients[Last];
  FClients.Delete(Last);
  SetLength(FIds, Last);
end;

procedure TContentIndexedDbBackend.DeliverNotice(Message: TIpcMessage);
var
  ClientId: LongWord;
  Notice: TBytes;
  Position: Integer;
begin
  DecodeIndexedDbNotice(Message.Payload, ClientId, Notice);
  for Position := 0 to High(FIds) do
    if FIds[Position] = ClientId then
    begin
      TIndexedDbClient(FClients[Position]).Notice(Notice);
      Exit;
    end;
end;

end.

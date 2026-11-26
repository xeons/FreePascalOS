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
  The browser's side of one content process (a renderer: /bin/webcontent):
  the process, its channel, the site it is locked to, the views it
  hosts, and when it last answered a ping. And what the IPC thread
  hands the GUI thread about it (TContentDelivery: a message, or the
  process's end), through a queue the GUI drains when woken.
}
unit WebView.ContentProcess;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebIpc.Messages,
  WebIpc.Endpoints;

type
  { A view's ear on its content process (called on the GUI thread). }
  TContentClient = class
  public
    ViewId: LongWord;
    { A message for the view (freed after this returns). }
    procedure Received(Message: TIpcMessage); virtual; abstract;
    { The process ended: Crashed when it was not asked to (a crash, an
      out-of-memory end, killed as hung). }
    procedure ProcessEnded(Crashed: Boolean; ExitCode: LongInt); virtual; abstract;
    { The process stopped answering pings (False) or answers again. }
    procedure ProcessResponsive(Responsive: Boolean); virtual; abstract;
  end;

  TContentProcess = class
  private
    FEndpoint: TIpcEndpoint;
    FSite: string;
    FClients: TList;
  public
    ProcessHandle: Int64;
    ProcessId: Int64;
    { Milliseconds of uptime when the process last answered a ping (the
      IPC thread writes it). }
    LastPong: QWord;
    PingSequence: LongWord;
    Hung: Boolean;
    { The browser asked it to end (no views left) or ended it; when
      (milliseconds of uptime), and whether it was then ended by force
      for not ending in time (busy in a script, or swapping). }
    ShutdownSent: Boolean;
    ShutdownSentAt: QWord;
    ShutdownForced: Boolean;
    KilledAsHung: Boolean;
    { The IPC thread saw it end and no longer looks at it. }
    Ended: Boolean;
    ExitCode: LongInt;
    { The network service's part (WebView.NetworkService), used on the
      IPC thread and the network threads. }
    Network: TObject;
    constructor Create(Endpoint: TIpcEndpoint; const ASite: string);
    destructor Destroy; override;
    function Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): Boolean; overload;
    function Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes;
      const Handles: array of Int64): Boolean; overload;
    function ClientCount: Integer;
    function Client(Index: Integer): TContentClient;
    function FindClient(ViewId: LongWord): TContentClient;
    procedure AddClient(AClient: TContentClient);
    procedure RemoveClient(AClient: TContentClient);
    property Endpoint: TIpcEndpoint read FEndpoint;
    { The site every document it shows belongs to (WebView.Sites; '' for
      one that only shows pages without a site, about:blank). }
    property Site: string read FSite;
  end;

  { What the IPC thread hands the GUI thread. }
  TContentDelivery = class
  public
    Process: TContentProcess;
    { nil for the process's end. }
    Message: TIpcMessage;
    destructor Destroy; override;
  end;

  TDeliveryQueue = class
  private
    FItems: TList;
    FLock: TRTLCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(Item: TContentDelivery);
    { Everything queued, oldest first (the caller frees them). }
    function TakeAll: TList;
  end;

implementation

constructor TContentProcess.Create(Endpoint: TIpcEndpoint; const ASite: string);
begin
  inherited Create;
  FEndpoint := Endpoint;
  FSite := ASite;
  FClients := TList.Create;
  ProcessHandle := -1;
end;

destructor TContentProcess.Destroy;
begin
  Network.Free;
  FEndpoint.Free;
  FClients.Free;
  inherited Destroy;
end;

function TContentProcess.Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes): Boolean;
begin
  Result := FEndpoint.Send(Kind, ViewId, RequestId, Payload, []);
end;

function TContentProcess.Send(Kind: Word; ViewId, RequestId: LongWord; const Payload: TBytes;
  const Handles: array of Int64): Boolean;
begin
  Result := FEndpoint.Send(Kind, ViewId, RequestId, Payload, Handles);
end;

function TContentProcess.ClientCount: Integer;
begin
  Result := FClients.Count;
end;

function TContentProcess.Client(Index: Integer): TContentClient;
begin
  Result := TContentClient(FClients[Index]);
end;

function TContentProcess.FindClient(ViewId: LongWord): TContentClient;
var
  Index: Integer;
begin
  for Index := 0 to FClients.Count - 1 do
    if TContentClient(FClients[Index]).ViewId = ViewId then
      Exit(TContentClient(FClients[Index]));
  Result := nil;
end;

procedure TContentProcess.AddClient(AClient: TContentClient);
begin
  FClients.Add(AClient);
end;

procedure TContentProcess.RemoveClient(AClient: TContentClient);
begin
  FClients.Remove(AClient);
end;

destructor TContentDelivery.Destroy;
begin
  Message.Free;
  inherited Destroy;
end;

constructor TDeliveryQueue.Create;
begin
  inherited Create;
  FItems := TList.Create;
  InitCriticalSection(FLock);
end;

destructor TDeliveryQueue.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FItems.Count - 1 do
    TContentDelivery(FItems[Index]).Free;
  FItems.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TDeliveryQueue.Push(Item: TContentDelivery);
begin
  EnterCriticalSection(FLock);
  try
    FItems.Add(Item);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TDeliveryQueue.TakeAll: TList;
begin
  EnterCriticalSection(FLock);
  try
    Result := FItems;
    FItems := TList.Create;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.

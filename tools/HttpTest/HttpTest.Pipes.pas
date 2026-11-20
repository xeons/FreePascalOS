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
  In-memory byte pipes for the loopback tests: a pair of transports,
  what one writes the other reads, with blocking reads (a timeout, and
  0 once the other end closed), so libhttp's connections talk to a
  test server in another thread without sockets.
}
unit HttpTest.Pipes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.Transports;

type
  TPipe = class
  private
    FLock: TRTLCriticalSection;
    FEvent: PRTLEvent;
    FData: TBytes;
    FCount: Integer;
    FClosed: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Put(Buffer: Pointer; Count: Integer);
    { Bytes taken, 0 when closed and empty, -1 on a timeout. }
    function Take(Buffer: Pointer; Count: Integer; TimeoutMilliseconds: Int64): Integer;
    procedure CloseWriting;
  end;

  TPipeTransport = class(THttpTransport)
  private
    FIncoming: TPipe;
    FOutgoing: TPipe;
  public
    constructor Create(Incoming, Outgoing: TPipe; const Protocol: string);
    function Read(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function Write(Buffer: Pointer; Count: PtrUInt): Boolean; override;
    procedure Shutdown; override;
    procedure Close; override;
    { Bytes written so far (for counting what went out). }
  end;

  { Two transports joined: the client's and the server's. }
  TPipePair = class
  public
    ToServer, ToClient: TPipe;
    Client, Server: TPipeTransport;
    constructor Create(const Protocol: string);
    destructor Destroy; override;
  end;

implementation

constructor TPipe.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FEvent := RTLEventCreate;
end;

destructor TPipe.Destroy;
begin
  RTLEventDestroy(FEvent);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPipe.Put(Buffer: Pointer; Count: Integer);
begin
  EnterCriticalSection(FLock);
  if Length(FData) < FCount + Count then
    SetLength(FData, (FCount + Count) * 2);
  Move(Buffer^, FData[FCount], Count);
  Inc(FCount, Count);
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FEvent);
end;

function TPipe.Take(Buffer: Pointer; Count: Integer; TimeoutMilliseconds: Int64): Integer;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while True do
  begin
    EnterCriticalSection(FLock);
    if FCount > 0 then
    begin
      Result := FCount;
      if Result > Count then
        Result := Count;
      Move(FData[0], Buffer^, Result);
      { FData[Result] is past the end when everything was taken (a range
        error under -Cr, raised with the lock held). }
      if FCount > Result then
        Move(FData[Result], FData[0], FCount - Result);
      Dec(FCount, Result);
      LeaveCriticalSection(FLock);
      Exit;
    end;
    if FClosed then
    begin
      LeaveCriticalSection(FLock);
      Exit(0);
    end;
    RTLEventResetEvent(FEvent);
    LeaveCriticalSection(FLock);
    if (TimeoutMilliseconds > 0) and (GetTickCount64 - Started >= QWord(TimeoutMilliseconds)) then
      Exit(-1);
    RTLEventWaitFor(FEvent, 50);
  end;
end;

procedure TPipe.CloseWriting;
begin
  EnterCriticalSection(FLock);
  FClosed := True;
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FEvent);
end;

constructor TPipeTransport.Create(Incoming, Outgoing: TPipe; const Protocol: string);
begin
  inherited Create;
  FIncoming := Incoming;
  FOutgoing := Outgoing;
  FNegotiatedProtocol := Protocol;
  FTimeoutMilliseconds := 5000;
end;

function TPipeTransport.Read(Buffer: Pointer; Count: PtrUInt): Int64;
begin
  Result := FIncoming.Take(Buffer, Count, FTimeoutMilliseconds);
  if Result < 0 then
    SetFailure(TransportFailureTimeout, 110, 'Connection timed out');
end;

function TPipeTransport.Write(Buffer: Pointer; Count: PtrUInt): Boolean;
begin
  FOutgoing.Put(Buffer, Count);
  Result := True;
end;

procedure TPipeTransport.Shutdown;
begin
  FIncoming.CloseWriting;
end;

procedure TPipeTransport.Close;
begin
  FOutgoing.CloseWriting;
end;

constructor TPipePair.Create(const Protocol: string);
begin
  inherited Create;
  ToServer := TPipe.Create;
  ToClient := TPipe.Create;
  Client := TPipeTransport.Create(ToClient, ToServer, Protocol);
  Server := TPipeTransport.Create(ToServer, ToClient, Protocol);
end;

destructor TPipePair.Destroy;
begin
  Server.Free;
  ToServer.Free;
  ToClient.Free;
  inherited Destroy;
end;

end.

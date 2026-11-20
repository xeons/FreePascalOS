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
  The connections a client keeps, per origin ("https://host:443"):

  - a request takes an idle HTTP/1.1 connection of its origin, or
    shares an HTTP/2 (or HTTP/3) connection that can take another
    stream; otherwise the client opens a new one and adds it;
  - when an exchange ends the connection is released: kept when it is
    still usable, closed otherwise; an idle HTTP/1.1 connection waits
    for the next request, at most MaximumIdlePerOrigin per origin and
    MaximumIdle in all (the oldest idle one closed first) and at most
    IdleTimeout milliseconds; wget keeps one, as GNU wget does;
  - the pool owns its connections and frees them.

  Thread safe. Plain Pascal (the RTL only), checked on the host by
  tools/HttpTest.
}
unit Http.ConnectionPool;

{$mode objfpc}
{$H+}

interface

uses
  Http.Connections;

type
  TPooledConnection = record
    Connection: THttpConnection;
    { Exchanges in progress on it. }
    Active: Integer;
  end;

  THttpConnectionPool = class
  private
    FEntries: array of TPooledConnection;
    FLock: TRTLCriticalSection;
    FMaximumIdle: Integer;
    FMaximumIdlePerOrigin: Integer;
    FIdleTimeout: QWord;
    function IndexOf(Connection: THttpConnection): Integer;
    procedure CloseAt(Index: Integer);
    procedure CloseExpired;
    procedure EnforceIdleLimits(const OriginKey: string);
    function IdleCount(const OriginKey: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { A connection of the origin (speaking one of Protocols) that started
      an exchange for the caller (both returned), or nil. }
    function Acquire(const OriginKey: string; out Exchange: THttpExchange;
      Protocols: THttpProtocols = [HttpProtocol11, HttpProtocol2, HttpProtocol3]): THttpConnection;
    { A new connection (with one exchange about to start on it). }
    procedure Add(Connection: THttpConnection);
    { An exchange on the connection ended (the exchange is finished and
      freed by the caller first). }
    procedure Release(Connection: THttpConnection);
    procedure CloseIdle;
    procedure CloseAll;
    function ConnectionCount: Integer;
    property MaximumIdle: Integer read FMaximumIdle write FMaximumIdle;
    property MaximumIdlePerOrigin: Integer read FMaximumIdlePerOrigin write FMaximumIdlePerOrigin;
    property IdleTimeout: QWord read FIdleTimeout write FIdleTimeout;
  end;

implementation

uses
  SysUtils;

constructor THttpConnectionPool.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FMaximumIdle := 32;
  FMaximumIdlePerOrigin := 6;
  FIdleTimeout := 60 * 1000;
end;

destructor THttpConnectionPool.Destroy;
begin
  CloseAll;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THttpConnectionPool.IndexOf(Connection: THttpConnection): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    if FEntries[Index].Connection = Connection then
      Exit(Index);
  Result := -1;
end;

procedure THttpConnectionPool.CloseAt(Index: Integer);
var
  Connection: THttpConnection;
begin
  Connection := FEntries[Index].Connection;
  Delete(FEntries, Index, 1);
  Connection.Free;
end;

procedure THttpConnectionPool.CloseExpired;
var
  Index: Integer;
  Now: QWord;
begin
  Now := GetTickCount64;
  Index := High(FEntries);
  while Index >= 0 do
  begin
    if (FEntries[Index].Active = 0) and
       (not FEntries[Index].Connection.IsUsable or (Now - FEntries[Index].Connection.IdleSince > FIdleTimeout)) then
      CloseAt(Index);
    Dec(Index);
  end;
end;

function THttpConnectionPool.IdleCount(const OriginKey: string): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Active = 0) and ((OriginKey = '') or (FEntries[Index].Connection.OriginKey = OriginKey)) then
      Inc(Result);
end;

procedure THttpConnectionPool.EnforceIdleLimits(const OriginKey: string);
var
  Index, Oldest: Integer;

  function OldestIdle(const Key: string): Integer;
  var
    Candidate: Integer;
  begin
    OldestIdle := -1;
    for Candidate := 0 to High(FEntries) do
      if (FEntries[Candidate].Active = 0) and ((Key = '') or (FEntries[Candidate].Connection.OriginKey = Key)) and
         ((OldestIdle < 0) or
         (FEntries[Candidate].Connection.IdleSince < FEntries[OldestIdle].Connection.IdleSince)) then
        OldestIdle := Candidate;
  end;

begin
  while IdleCount(OriginKey) > FMaximumIdlePerOrigin do
  begin
    Oldest := OldestIdle(OriginKey);
    if Oldest < 0 then
      Break;
    CloseAt(Oldest);
  end;
  while IdleCount('') > FMaximumIdle do
  begin
    { The connection just released is the newest: others go first. }
    Index := OldestIdle('');
    if Index < 0 then
      Break;
    CloseAt(Index);
  end;
end;

function THttpConnectionPool.Acquire(const OriginKey: string; out Exchange: THttpExchange;
  Protocols: THttpProtocols): THttpConnection;
var
  Index: Integer;
  Candidate: THttpConnection;
begin
  Result := nil;
  Exchange := nil;
  EnterCriticalSection(FLock);
  try
    CloseExpired;
    { Multiplexed connections first: they are shared anyway. }
    for Index := 0 to High(FEntries) do
    begin
      Candidate := FEntries[Index].Connection;
      if (Candidate.OriginKey <> OriginKey) or not (Candidate.Protocol in Protocols) or not Candidate.IsUsable then
        Continue;
      if not Candidate.IsMultiplexed and (FEntries[Index].Active > 0) then
        Continue;
      Exchange := Candidate.StartExchange;
      if Exchange = nil then
        Continue;
      Inc(FEntries[Index].Active);
      Exit(Candidate);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpConnectionPool.Add(Connection: THttpConnection);
begin
  EnterCriticalSection(FLock);
  try
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)].Connection := Connection;
    FEntries[High(FEntries)].Active := 1;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpConnectionPool.Release(Connection: THttpConnection);
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := IndexOf(Connection);
    if Index < 0 then
      Exit;
    if FEntries[Index].Active > 0 then
      Dec(FEntries[Index].Active);
    if FEntries[Index].Active > 0 then
      Exit;
    if not Connection.IsUsable then
    begin
      CloseAt(Index);
      Exit;
    end;
    Connection.IdleSince := GetTickCount64;
    EnforceIdleLimits(Connection.OriginKey);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpConnectionPool.CloseIdle;
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := High(FEntries);
    while Index >= 0 do
    begin
      if FEntries[Index].Active = 0 then
        CloseAt(Index);
      Dec(Index);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpConnectionPool.CloseAll;
begin
  EnterCriticalSection(FLock);
  try
    while Length(FEntries) > 0 do
      CloseAt(High(FEntries));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THttpConnectionPool.ConnectionCount: Integer;
begin
  EnterCriticalSection(FLock);
  Result := Length(FEntries);
  LeaveCriticalSection(FLock);
end;

end.

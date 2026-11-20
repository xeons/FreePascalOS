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
  Alternative services (RFC 7838) and the place HTTP/3 plugs in:

  - Alt-Svc values ('h3=":443"; ma=86400, h2="alt.example:443"', or
    "clear") are parsed and kept per origin until their max-age (24
    hours by default) runs out; a new value replaces the old ones;
  - a connection factory can be registered for an ALPN protocol id
    ("h3"): when an origin advertises it, the client asks the factory
    for a connection to the alternative (libquic's HTTP/3 connection
    will register itself this way); an alternative that fails is
    marked broken for five minutes and the origin's own connection is
    used meanwhile;
  - without a factory for any advertised protocol nothing changes.

  Thread safe. Plain Pascal (the RTL only), checked on the host by
  tools/HttpTest.
}
unit Http.AltServices;

{$mode objfpc}
{$H+}

interface

uses
  Http.Connections,
  Http.Observers,
  Http.Results,
  Url.Records;

const
  DefaultAltServiceMaxAge = 86400;
  BrokenAltServiceSeconds = 300;

type
  THttpAltService = record
    { The ALPN protocol id ("h3"). }
    ProtocolId: string;
    { '' for the origin's own host. }
    Host: string;
    Port: Word;
    { Unix seconds. }
    Expires: Int64;
    BrokenUntil: Int64;
  end;

  THttpAltServiceArray = array of THttpAltService;

  { A connection to Service for the origin of Url, or nil (Failure set). }
  THttpConnectionFactory = function(constref Url: TUrlRecord; constref Service: THttpAltService;
    constref Settings: THttpClientSettings; out Failure: THttpResult): THttpConnection;

  TAltServiceOrigin = record
    OriginKey: string;
    Services: THttpAltServiceArray;
  end;

  THttpAltServiceCache = class
  private
    FOrigins: array of TAltServiceOrigin;
    FLock: TRTLCriticalSection;
    function IndexOf(const OriginKey: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { An Alt-Svc field value received from the origin. }
    procedure Update(const OriginKey, FieldValue: string; Now: Int64);
    { The first live alternative with a registered factory, if any. }
    function Choose(const OriginKey: string; Now: Int64; out Service: THttpAltService;
      out Factory: THttpConnectionFactory): Boolean;
    procedure MarkBroken(const OriginKey, ProtocolId: string; Now: Int64);
    function ServicesOf(const OriginKey: string; Now: Int64): THttpAltServiceArray;
    procedure Clear;
  end;

{ False when the value does not parse; Clear for "clear". }
function ParseAltSvc(const Value: string; Now: Int64; out Services: THttpAltServiceArray; out Clear: Boolean): Boolean;
procedure RegisterConnectionFactory(const ProtocolId: string; Factory: THttpConnectionFactory);
function FindConnectionFactory(const ProtocolId: string): THttpConnectionFactory;

implementation

uses
  SysUtils,
  Http.FieldValues,
  Url.PercentEncoding;

type
  TFactoryEntry = record
    ProtocolId: string;
    Factory: THttpConnectionFactory;
  end;

var
  Factories: array of TFactoryEntry;
  FactoriesLock: TRTLCriticalSection;
  FactoriesLockReady: LongInt = 0;

procedure EnsureFactoriesLock;
begin
  if InterLockedCompareExchange(FactoriesLockReady, 1, 0) = 0 then
  begin
    InitCriticalSection(FactoriesLock);
    InterLockedExchange(FactoriesLockReady, 2);
  end;
  while FactoriesLockReady <> 2 do
    ThreadSwitch;
end;

procedure RegisterConnectionFactory(const ProtocolId: string; Factory: THttpConnectionFactory);
var
  Index: Integer;
begin
  EnsureFactoriesLock;
  EnterCriticalSection(FactoriesLock);
  try
    for Index := 0 to High(Factories) do
      if Factories[Index].ProtocolId = ProtocolId then
      begin
        Factories[Index].Factory := Factory;
        Exit;
      end;
    SetLength(Factories, Length(Factories) + 1);
    Factories[High(Factories)].ProtocolId := ProtocolId;
    Factories[High(Factories)].Factory := Factory;
  finally
    LeaveCriticalSection(FactoriesLock);
  end;
end;

function FindConnectionFactory(const ProtocolId: string): THttpConnectionFactory;
var
  Entry: TFactoryEntry;
begin
  Result := nil;
  EnsureFactoriesLock;
  EnterCriticalSection(FactoriesLock);
  try
    for Entry in Factories do
      if Entry.ProtocolId = ProtocolId then
        Exit(Entry.Factory);
  finally
    LeaveCriticalSection(FactoriesLock);
  end;
end;

{ 'alt.example:443' or ':443' into Host and Port. }
function ParseAuthority(const Text: string; out Host: string; out Port: Word): Boolean;
var
  Colon, Number: Integer;
begin
  Host := '';
  Port := 0;
  Colon := LastDelimiter(':', Text);
  if Colon = 0 then
    Exit(False);
  Host := LowerCase(Copy(Text, 1, Colon - 1));
  if not TryStrToInt(Copy(Text, Colon + 1, MaxInt), Number) or (Number <= 0) or (Number > 65535) then
    Exit(False);
  Port := Number;
  Result := True;
end;

function ParseAltSvc(const Value: string; Now: Int64; out Services: THttpAltServiceArray; out Clear: Boolean): Boolean;
var
  Member: string;
  Parameters: THttpParameterList;
  Parameter: THttpParameter;
  Service: THttpAltService;
  Index: Integer;
  MaxAge: Int64;
begin
  Services := nil;
  Clear := False;
  if SameText(Trim(Value), 'clear') then
  begin
    Clear := True;
    Exit(True);
  end;
  for Member in SplitFieldList(Value) do
  begin
    Parameters := ParseParameters(Member, ';');
    if (Length(Parameters) = 0) or not Parameters[0].HasValue then
      Continue;
    Service := Default(THttpAltService);
    { The protocol id is percent-encoded (RFC 7838 section 3). }
    Service.ProtocolId := PercentDecode(Parameters[0].Name);
    if not ParseAuthority(Parameters[0].Value, Service.Host, Service.Port) then
      Continue;
    MaxAge := DefaultAltServiceMaxAge;
    for Index := 1 to High(Parameters) do
    begin
      Parameter := Parameters[Index];
      if (Parameter.Name = 'ma') and not ParseDecimalNumber(Parameter.Value, MaxAge) then
        MaxAge := DefaultAltServiceMaxAge;
    end;
    Service.Expires := Now + MaxAge;
    SetLength(Services, Length(Services) + 1);
    Services[High(Services)] := Service;
  end;
  Result := True;
end;

constructor THttpAltServiceCache.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor THttpAltServiceCache.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THttpAltServiceCache.IndexOf(const OriginKey: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FOrigins) do
    if FOrigins[Index].OriginKey = OriginKey then
      Exit(Index);
  Result := -1;
end;

procedure THttpAltServiceCache.Update(const OriginKey, FieldValue: string; Now: Int64);
var
  Services: THttpAltServiceArray;
  Cleared: Boolean;
  Index: Integer;
begin
  if not ParseAltSvc(FieldValue, Now, Services, Cleared) then
    Exit;
  EnterCriticalSection(FLock);
  try
    Index := IndexOf(OriginKey);
    if Cleared or (Length(Services) = 0) then
    begin
      if Index >= 0 then
        Delete(FOrigins, Index, 1);
      Exit;
    end;
    if Index < 0 then
    begin
      SetLength(FOrigins, Length(FOrigins) + 1);
      Index := High(FOrigins);
      FOrigins[Index].OriginKey := OriginKey;
    end;
    FOrigins[Index].Services := Services;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THttpAltServiceCache.Choose(const OriginKey: string; Now: Int64; out Service: THttpAltService;
  out Factory: THttpConnectionFactory): Boolean;
var
  Candidate: THttpAltService;
begin
  Service := Default(THttpAltService);
  Factory := nil;
  for Candidate in ServicesOf(OriginKey, Now) do
  begin
    if Candidate.BrokenUntil > Now then
      Continue;
    Factory := FindConnectionFactory(Candidate.ProtocolId);
    if Assigned(Factory) then
    begin
      Service := Candidate;
      Exit(True);
    end;
  end;
  Result := False;
end;

procedure THttpAltServiceCache.MarkBroken(const OriginKey, ProtocolId: string; Now: Int64);
var
  Index, Position: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := IndexOf(OriginKey);
    if Index < 0 then
      Exit;
    for Position := 0 to High(FOrigins[Index].Services) do
      if FOrigins[Index].Services[Position].ProtocolId = ProtocolId then
        FOrigins[Index].Services[Position].BrokenUntil := Now + BrokenAltServiceSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THttpAltServiceCache.ServicesOf(const OriginKey: string; Now: Int64): THttpAltServiceArray;
var
  Index: Integer;
  Service: THttpAltService;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    Index := IndexOf(OriginKey);
    if Index < 0 then
      Exit;
    for Service in FOrigins[Index].Services do
      if Service.Expires > Now then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Service;
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpAltServiceCache.Clear;
begin
  EnterCriticalSection(FLock);
  FOrigins := nil;
  LeaveCriticalSection(FLock);
end;

end.

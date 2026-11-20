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

  - Alt-Svc values ('h3=":443"; ma=86400, h2="alt.example:443";
    persist=1', or "clear") are parsed and kept per origin until their
    max-age (24 hours by default) runs out; a new value replaces the
    old ones, "clear" forgets them; at most eight alternatives an origin
    and 512 origins (the least recently updated go first);
  - persist=1 is kept with the entry: such entries would outlive a
    change of network, the others not (the system tells programs of
    none, so nothing is dropped for it yet); SaveText and LoadText keep
    the cache in a file between runs (wget --alt-svc-file);
  - a connection factory can be registered for an ALPN protocol id
    ("h3"): when an origin advertises it, the client asks the factory
    for a connection to the alternative (libquic's
    Http3.SystemConnections registers HTTP/3's with EnableHttp3); an
    alternative that fails is marked broken for five minutes and the
    origin's own connection is used meanwhile;
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
  MaximumAltServicesPerOrigin = 8;
  MaximumAltServiceOrigins = 512;

type
  THttpAltService = record
    { The ALPN protocol id ("h3"). }
    ProtocolId: string;
    { '' for the origin's own host; an IPv6 address without brackets. }
    Host: string;
    Port: Word;
    { Unix seconds. }
    Expires: Int64;
    { persist=1: kept across changes of network. }
    Persist: Boolean;
    BrokenUntil: Int64;
  end;

  THttpAltServiceArray = array of THttpAltService;

  { A connection to Service for the origin of Url (the certificate must
    be good for the origin's host), or nil (Failure set). The observer
    hears the attempt. }
  THttpConnectionFactory = function(constref Url: TUrlRecord; constref Service: THttpAltService;
    constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Failure: THttpResult): THttpConnection;

  TAltServiceOrigin = record
    OriginKey: string;
    Services: THttpAltServiceArray;
  end;

  THttpAltServiceCache = class
  private
    FOrigins: array of TAltServiceOrigin;
    FLock: TRTLCriticalSection;
    function IndexOf(const OriginKey: string): Integer;
    procedure Store(const OriginKey: string; constref Services: THttpAltServiceArray);
  public
    constructor Create;
    destructor Destroy; override;
    { An Alt-Svc field value received from the origin. }
    procedure Update(const OriginKey, FieldValue: string; Now: Int64);
    { The first live alternative with a registered factory, if any;
      HTTP/3's ("h3") only when AllowHttp3. }
    function Choose(const OriginKey: string; Now: Int64; AllowHttp3: Boolean; out Service: THttpAltService;
      out Factory: THttpConnectionFactory): Boolean;
    procedure MarkBroken(const OriginKey, ProtocolId: string; Now: Int64);
    function ServicesOf(const OriginKey: string; Now: Int64): THttpAltServiceArray;
    function OriginCount: Integer;
    procedure Clear;
    { Lines "ORIGIN PROTOCOL HOST PORT EXPIRES PERSIST" (HOST "-" for the
      origin's own, PROTOCOL percent-encoded) for the live entries. }
    function SaveText(Now: Int64): string;
    { Takes what SaveText wrote (bad and expired lines skipped). }
    procedure LoadText(const Text: string; Now: Int64);
  end;

{ False when the value does not parse; Clear for "clear". }
function ParseAltSvc(const Value: string; Now: Int64; out Services: THttpAltServiceArray; out Clear: Boolean): Boolean;
{ "h3" and the drafts' "h3-29" ... }
function IsHttp3ProtocolId(const ProtocolId: string): Boolean;
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

function IsHttp3ProtocolId(const ProtocolId: string): Boolean;
begin
  Result := (ProtocolId = 'h3') or (Copy(ProtocolId, 1, 3) = 'h3-');
end;

{ 'alt.example:443', '[2001:db8::1]:443' or ':443' into Host and Port. }
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
  if (Length(Host) >= 2) and (Host[1] = '[') and (Host[Length(Host)] = ']') then
    Host := Copy(Host, 2, Length(Host) - 2)
  else if Pos(':', Host) > 0 then
    Exit(False);
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
  MaxAge, Number: Int64;
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
    if (Service.ProtocolId = '') or not ParseAuthority(Parameters[0].Value, Service.Host, Service.Port) then
      Continue;
    MaxAge := DefaultAltServiceMaxAge;
    for Index := 1 to High(Parameters) do
    begin
      Parameter := Parameters[Index];
      { Parameters that do not parse are ignored (section 3.1). }
      if (Parameter.Name = 'ma') and ParseDecimalNumber(Parameter.Value, Number) then
        MaxAge := Number
      else if (Parameter.Name = 'persist') and (Parameter.Value = '1') then
        Service.Persist := True;
    end;
    if MaxAge <= 0 then
      Continue;
    Service.Expires := Now + MaxAge;
    if Length(Services) < MaximumAltServicesPerOrigin then
    begin
      SetLength(Services, Length(Services) + 1);
      Services[High(Services)] := Service;
    end;
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

{ Under the lock: the origin's entries replaced and the origin moved to
  the end (the most recently updated); the oldest go past the limit. }
procedure THttpAltServiceCache.Store(const OriginKey: string; constref Services: THttpAltServiceArray);
var
  Index: Integer;
  Entry: TAltServiceOrigin;
begin
  Index := IndexOf(OriginKey);
  if Index >= 0 then
    Delete(FOrigins, Index, 1);
  if Length(Services) = 0 then
    Exit;
  while Length(FOrigins) >= MaximumAltServiceOrigins do
    Delete(FOrigins, 0, 1);
  Entry.OriginKey := OriginKey;
  Entry.Services := Services;
  SetLength(FOrigins, Length(FOrigins) + 1);
  FOrigins[High(FOrigins)] := Entry;
end;

procedure THttpAltServiceCache.Update(const OriginKey, FieldValue: string; Now: Int64);
var
  Services: THttpAltServiceArray;
  Cleared: Boolean;
  Index, Position: Integer;
  Old: THttpAltService;
begin
  if not ParseAltSvc(FieldValue, Now, Services, Cleared) then
    Exit;
  EnterCriticalSection(FLock);
  try
    { An alternative marked broken stays broken when advertised again. }
    Index := IndexOf(OriginKey);
    if Index >= 0 then
      for Old in FOrigins[Index].Services do
        for Position := 0 to High(Services) do
          if (Services[Position].ProtocolId = Old.ProtocolId) and (Services[Position].Host = Old.Host) and
             (Services[Position].Port = Old.Port) then
            Services[Position].BrokenUntil := Old.BrokenUntil;
    Store(OriginKey, Services);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THttpAltServiceCache.Choose(const OriginKey: string; Now: Int64; AllowHttp3: Boolean;
  out Service: THttpAltService; out Factory: THttpConnectionFactory): Boolean;
var
  Candidate: THttpAltService;
begin
  Service := Default(THttpAltService);
  Factory := nil;
  for Candidate in ServicesOf(OriginKey, Now) do
  begin
    if (Candidate.BrokenUntil > Now) or (not AllowHttp3 and IsHttp3ProtocolId(Candidate.ProtocolId)) then
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

function THttpAltServiceCache.OriginCount: Integer;
begin
  EnterCriticalSection(FLock);
  Result := Length(FOrigins);
  LeaveCriticalSection(FLock);
end;

procedure THttpAltServiceCache.Clear;
begin
  EnterCriticalSection(FLock);
  FOrigins := nil;
  LeaveCriticalSection(FLock);
end;

function THttpAltServiceCache.SaveText(Now: Int64): string;
const
  PersistText: array[Boolean] of string = ('0', '1');
var
  Origin: TAltServiceOrigin;
  Service: THttpAltService;
  Host: string;
begin
  Result := '';
  EnterCriticalSection(FLock);
  try
    for Origin in FOrigins do
      for Service in Origin.Services do
      begin
        if Service.Expires <= Now then
          Continue;
        Host := Service.Host;
        if Host = '' then
          Host := '-';
        Result := Result + Origin.OriginKey + ' ' + PercentEncode(Service.ProtocolId, EncodeComponent) + ' ' +
          Host + ' ' + IntToStr(Service.Port) + ' ' + IntToStr(Service.Expires) + ' ' +
          PersistText[Service.Persist] + #10;
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ One line of SaveText's into its origin and alternative; False when it
  is not one, or has expired. }
function ParseSavedLine(const Line: string; Now: Int64; out OriginKey: string;
  out Service: THttpAltService): Boolean;
var
  Words: TStringArray;
  Port, Expires: Int64;
begin
  OriginKey := '';
  Service := Default(THttpAltService);
  Words := Trim(Line).Split([' '], TStringSplitOptions.ExcludeEmpty);
  if (Length(Words) <> 6) or (Copy(Words[0], 1, 8) <> 'https://') then
    Exit(False);
  if not ParseDecimalNumber(Words[3], Port) or (Port <= 0) or (Port > 65535) or
     not ParseDecimalNumber(Words[4], Expires) or (Expires <= Now) then
    Exit(False);
  OriginKey := Words[0];
  Service.ProtocolId := PercentDecode(Words[1]);
  Service.Host := Words[2];
  if Service.Host = '-' then
    Service.Host := '';
  Service.Port := Port;
  Service.Expires := Expires;
  Service.Persist := Words[5] = '1';
  Result := Service.ProtocolId <> '';
end;

procedure THttpAltServiceCache.LoadText(const Text: string; Now: Int64);
var
  Line, OriginKey: string;
  Service: THttpAltService;
  Services: THttpAltServiceArray;
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for Line in Text.Split([#10]) do
    begin
      if not ParseSavedLine(Line, Now, OriginKey, Service) then
        Continue;
      Index := IndexOf(OriginKey);
      Services := nil;
      if Index >= 0 then
        Services := Copy(FOrigins[Index].Services);
      if Length(Services) >= MaximumAltServicesPerOrigin then
        Continue;
      SetLength(Services, Length(Services) + 1);
      Services[High(Services)] := Service;
      Store(OriginKey, Services);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.

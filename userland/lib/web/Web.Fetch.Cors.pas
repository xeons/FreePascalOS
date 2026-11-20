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
  CORS, the protocol's decisions (Fetch Standard sections 3.2 and 4.8
  to 4.10):

  - CORS-safelisted methods and request headers (Accept, Accept-Language,
    Content-Language, Content-Type of the three form types, a simple
    Range; values of at most 128 bytes, 1024 in all; no CORS-unsafe
    bytes), the CORS-unsafe request-header names (sorted, lower case),
    and whether a request needs a preflight;
  - the CORS check (Access-Control-Allow-Origin "*" without credentials,
    or the request's serialized origin, and then
    Access-Control-Allow-Credentials "true" when credentials are
    included);
  - the preflight's own checks (allowed methods and headers, "*" only
    without credentials and never covering Authorization) and its cache
    (per origin, URL and credentials, Access-Control-Max-Age seconds,
    5 by default and at most 7200);
  - the CORS-safelisted response header names plus
    Access-Control-Expose-Headers, which is what a script may read.
}
unit Web.Fetch.Cors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Http.HeaderFields;

const
  DefaultPreflightMaxAge = 5;
  MaximumPreflightMaxAge = 7200;

type
  TCorsPreflightResult = record
    Ok: Boolean;
    Reason: string;
    Methods: TStringArray;
    HeaderNames: TStringArray;
    MaxAge: Int64;
  end;

  TPreflightCacheEntry = record
    Key: string;
    { A method (as given) or a header name (lower case). }
    Item: string;
    IsMethod: Boolean;
    Expiry: Double;
  end;

  { Milliseconds, for the cache's expiry. }
  TPreflightClock = function: Double of object;

  TCorsPreflightCache = class
  private
    FLock: TRTLCriticalSection;
    FEntries: array of TPreflightCacheEntry;
    function Find(const Key, Item: string; IsMethod: Boolean; Now: Double): Integer;
    procedure Store(const Key, Item: string; IsMethod: Boolean; Expiry: Double);
  public
    constructor Create;
    destructor Destroy; override;
    { The key of a request: origin, URL, credentials included. }
    class function KeyFor(const SerializedOrigin, Url: string; CredentialsIncluded: Boolean): string;
    function HasMethod(const Key, Method: string; Now: Double): Boolean;
    function HasHeader(const Key, Name: string; Now: Double): Boolean;
    { What a passed preflight allowed. }
    procedure Add(const Key: string; constref Preflight: TCorsPreflightResult; const Method: string;
      const UnsafeNames: TStringArray; Now: Double);
    procedure Clear;
    function Count: Integer;
  end;

function IsCorsSafelistedMethod(const Method: string): Boolean;
function IsCorsSafelistedRequestHeader(const Name, Value: string): Boolean;
{ The sorted lower case names of the request's CORS-unsafe headers. }
function CorsUnsafeRequestHeaderNames(Headers: THttpHeaders): TStringArray;
function CorsNeedsPreflight(const Method: string; Headers: THttpHeaders; UseCorsPreflight: Boolean): Boolean;
{ The CORS check of a response's fields. }
function CorsCheck(ResponseHeaders: THttpHeaders; const SerializedOrigin: string; CredentialsIncluded: Boolean;
  out Reason: string): Boolean;
{ The checks of a preflight's response (after the CORS check passed). }
function CheckPreflightResponse(ResponseHeaders: THttpHeaders; Status: Integer; const Method: string;
  const UnsafeNames: TStringArray; CredentialsIncluded, UseCorsPreflight: Boolean): TCorsPreflightResult;
{ The names a script may read from a CORS response (lower case). }
function CorsExposedHeaderNames(ResponseHeaders: THttpHeaders; CredentialsIncluded: Boolean): TStringArray;
function IsCorsSafelistedResponseHeaderName(const Name: string): Boolean;
{ Fetch's forbidden request-header names (a script cannot set them). }
function IsForbiddenRequestHeader(const Name: string): Boolean;

implementation

uses
  Http.FieldValues,
  Web.Fetch.MimeTypes;

function IsCorsSafelistedMethod(const Method: string): Boolean;
begin
  Result := (Method = 'GET') or (Method = 'HEAD') or (Method = 'POST');
end;

function IsCorsUnsafeRequestHeaderByte(Value: Byte): Boolean;
begin
  Result := ((Value < $20) and (Value <> $09)) or (Value in [$22, $28, $29, $3A, $3C, $3E, $3F, $40, $5B, $5C, $5D,
    $7B, $7D, $7F]);
end;

function HasUnsafeBytes(const Value: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Value) do
    if IsCorsUnsafeRequestHeaderByte(Ord(Value[Index])) then
      Exit(True);
  Result := False;
end;

function IsLanguageValue(const Value: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Value) do
    if not (Value[Index] in ['0'..'9', 'A'..'Z', 'a'..'z', ' ', '*', ',', '-', '.', ';', '=']) then
      Exit(False);
  Result := True;
end;

{ "bytes=" start "-" [end], start <= end. }
function IsSimpleRangeValue(const Value: string): Boolean;
var
  Position, Start: Integer;
  First, Last: Int64;
  HasLast: Boolean;
begin
  if Copy(Value, 1, 6) <> 'bytes=' then
    Exit(False);
  Position := 7;
  Start := Position;
  while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) do
    Inc(Position);
  if (Position = Start) or (Position > Length(Value)) or (Value[Position] <> '-') then
    Exit(False);
  if not TryStrToInt64(Copy(Value, Start, Position - Start), First) then
    Exit(False);
  Inc(Position);
  Start := Position;
  while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) do
    Inc(Position);
  if Position <= Length(Value) then
    Exit(False);
  HasLast := Position > Start;
  if HasLast then
  begin
    if not TryStrToInt64(Copy(Value, Start, Position - Start), Last) then
      Exit(False);
    if First > Last then
      Exit(False);
  end;
  Result := True;
end;

function IsCorsSafelistedRequestHeader(const Name, Value: string): Boolean;
var
  Lower, Essence: string;
begin
  if Length(Value) > 128 then
    Exit(False);
  Lower := LowerCase(Name);
  if Lower = 'accept' then
    Result := not HasUnsafeBytes(Value)
  else if (Lower = 'accept-language') or (Lower = 'content-language') then
    Result := IsLanguageValue(Value)
  else if Lower = 'content-type' then
  begin
    if HasUnsafeBytes(Value) then
      Exit(False);
    Essence := MimeEssence(ParseMimeType(Value));
    Result := (Essence = 'application/x-www-form-urlencoded') or (Essence = 'multipart/form-data') or
      (Essence = 'text/plain');
  end
  else if Lower = 'range' then
    Result := IsSimpleRangeValue(Value)
  else
    Result := False;
end;

function CorsUnsafeRequestHeaderNames(Headers: THttpHeaders): TStringArray;
var
  Index, Total: Integer;
  Names: TStringList;
  Field: THttpHeaderField;
begin
  Result := nil;
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    Total := 0;
    for Index := 0 to Headers.Count - 1 do
    begin
      Field := Headers[Index];
      if IsCorsSafelistedRequestHeader(Field.Name, Field.Value) then
        Inc(Total, Length(Field.Value))
      else
        Names.Add(LowerCase(Field.Name));
    end;
    { Over 1024 bytes of safelisted values: they all count as unsafe. }
    if Total > 1024 then
      for Index := 0 to Headers.Count - 1 do
        if IsCorsSafelistedRequestHeader(Headers[Index].Name, Headers[Index].Value) then
          Names.Add(LowerCase(Headers[Index].Name));
    SetLength(Result, Names.Count);
    for Index := 0 to Names.Count - 1 do
      Result[Index] := Names[Index];
  finally
    Names.Free;
  end;
end;

function CorsNeedsPreflight(const Method: string; Headers: THttpHeaders; UseCorsPreflight: Boolean): Boolean;
begin
  Result := UseCorsPreflight or not IsCorsSafelistedMethod(Method) or
    (Length(CorsUnsafeRequestHeaderNames(Headers)) > 0);
end;

function CorsCheck(ResponseHeaders: THttpHeaders; const SerializedOrigin: string; CredentialsIncluded: Boolean;
  out Reason: string): Boolean;
var
  Values: TStringArray;
  Origin: string;
begin
  Reason := '';
  Values := ResponseHeaders.GetAll('access-control-allow-origin');
  if Length(Values) <> 1 then
  begin
    if Length(Values) = 0 then
      Reason := 'no Access-Control-Allow-Origin'
    else
      Reason := 'more than one Access-Control-Allow-Origin';
    Exit(False);
  end;
  Origin := TrimHttpWhitespace(Values[0]);
  if not CredentialsIncluded and (Origin = '*') then
    Exit(True);
  if Origin <> SerializedOrigin then
  begin
    Reason := 'Access-Control-Allow-Origin ' + Origin + ' is not ' + SerializedOrigin;
    Exit(False);
  end;
  if not CredentialsIncluded then
    Exit(True);
  if TrimHttpWhitespace(ResponseHeaders.Value('access-control-allow-credentials')) <> 'true' then
  begin
    Reason := 'credentials not allowed (Access-Control-Allow-Credentials)';
    Exit(False);
  end;
  Result := True;
end;

function ListContains(const List: TStringArray; const Item: string; IgnoreCase: Boolean): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if (List[Index] = Item) or IgnoreCase and SameText(List[Index], Item) then
      Exit(True);
  Result := False;
end;

function ParseTokenList(const Value: string): TStringArray;
var
  Items: TStringArray;
  Index: Integer;
begin
  Result := nil;
  Items := SplitFieldList(Value);
  for Index := 0 to High(Items) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Items[Index];
  end;
end;

function CheckPreflightResponse(ResponseHeaders: THttpHeaders; Status: Integer; const Method: string;
  const UnsafeNames: TStringArray; CredentialsIncluded, UseCorsPreflight: Boolean): TCorsPreflightResult;
var
  Index: Integer;
  MaxAgeText: string;
  MaxAge: Int64;
begin
  Result := Default(TCorsPreflightResult);
  if (Status < 200) or (Status > 299) then
  begin
    Result.Reason := 'the preflight answered ' + IntToStr(Status);
    Exit;
  end;
  Result.Methods := ParseTokenList(ResponseHeaders.Combined('access-control-allow-methods'));
  Result.HeaderNames := ParseTokenList(ResponseHeaders.Combined('access-control-allow-headers'));
  if (Length(Result.Methods) = 0) and UseCorsPreflight then
  begin
    SetLength(Result.Methods, 1);
    Result.Methods[0] := Method;
  end;
  if not ListContains(Result.Methods, Method, False) and not IsCorsSafelistedMethod(Method) and
     not (ListContains(Result.Methods, '*', False) and not CredentialsIncluded) then
  begin
    Result.Reason := 'method ' + Method + ' not allowed by the preflight';
    Exit;
  end;
  for Index := 0 to High(UnsafeNames) do
    if not ListContains(Result.HeaderNames, UnsafeNames[Index], True) and
       not (ListContains(Result.HeaderNames, '*', False) and not CredentialsIncluded and
         (UnsafeNames[Index] <> 'authorization')) then
    begin
      Result.Reason := 'header ' + UnsafeNames[Index] + ' not allowed by the preflight';
      Exit;
    end;
  Result.MaxAge := DefaultPreflightMaxAge;
  MaxAgeText := TrimHttpWhitespace(ResponseHeaders.Value('access-control-max-age'));
  if (MaxAgeText <> '') and ParseDecimalNumber(MaxAgeText, MaxAge) then
  begin
    if MaxAge > MaximumPreflightMaxAge then
      MaxAge := MaximumPreflightMaxAge;
    Result.MaxAge := MaxAge;
  end;
  Result.Ok := True;
end;

function IsCorsSafelistedResponseHeaderName(const Name: string): Boolean;
begin
  case LowerCase(Name) of
    'cache-control', 'content-language', 'content-length', 'content-type', 'expires', 'last-modified', 'pragma':
      Result := True;
  else
    Result := False;
  end;
end;

function CorsExposedHeaderNames(ResponseHeaders: THttpHeaders; CredentialsIncluded: Boolean): TStringArray;
var
  Exposed: TStringArray;
  Index: Integer;
  All: Boolean;
  Name: string;

  procedure AddName(const Item: string);
  begin
    if not ListContains(Result, Item, False) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Item;
    end;
  end;

begin
  Result := nil;
  Exposed := ParseTokenList(ResponseHeaders.Combined('access-control-expose-headers'));
  All := ListContains(Exposed, '*', False) and not CredentialsIncluded;
  for Index := 0 to ResponseHeaders.Count - 1 do
  begin
    Name := LowerCase(ResponseHeaders[Index].Name);
    if (Name = 'set-cookie') or (Name = 'set-cookie2') then
      Continue;
    if All or IsCorsSafelistedResponseHeaderName(Name) or ListContains(Exposed, Name, True) then
      AddName(Name);
  end;
end;

function IsForbiddenRequestHeader(const Name: string): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(Name);
  case Lower of
    'accept-charset', 'accept-encoding', 'access-control-request-headers', 'access-control-request-method',
    'connection', 'content-length', 'cookie', 'cookie2', 'date', 'dnt', 'expect', 'host', 'keep-alive', 'origin',
    'referer', 'set-cookie', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'via':
      Exit(True);
  end;
  Result := (Copy(Lower, 1, 6) = 'proxy-') or (Copy(Lower, 1, 4) = 'sec-');
end;

constructor TCorsPreflightCache.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor TCorsPreflightCache.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

class function TCorsPreflightCache.KeyFor(const SerializedOrigin, Url: string; CredentialsIncluded: Boolean): string;
begin
  Result := SerializedOrigin + ' ' + Url + ' ' + BoolToStr(CredentialsIncluded, '1', '0');
end;

function TCorsPreflightCache.Find(const Key, Item: string; IsMethod: Boolean; Now: Double): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Key = Key) and (FEntries[Index].IsMethod = IsMethod) and
       (FEntries[Index].Item = Item) and (FEntries[Index].Expiry > Now) then
      Exit(Index);
  Result := -1;
end;

procedure TCorsPreflightCache.Store(const Key, Item: string; IsMethod: Boolean; Expiry: Double);
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Key = Key) and (FEntries[Index].IsMethod = IsMethod) and (FEntries[Index].Item = Item) then
    begin
      FEntries[Index].Expiry := Expiry;
      Exit;
    end;
  SetLength(FEntries, Length(FEntries) + 1);
  FEntries[High(FEntries)].Key := Key;
  FEntries[High(FEntries)].Item := Item;
  FEntries[High(FEntries)].IsMethod := IsMethod;
  FEntries[High(FEntries)].Expiry := Expiry;
end;

function TCorsPreflightCache.HasMethod(const Key, Method: string; Now: Double): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := (Find(Key, Method, True, Now) >= 0) or (Find(Key, '*', True, Now) >= 0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TCorsPreflightCache.HasHeader(const Key, Name: string; Now: Double): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := Find(Key, LowerCase(Name), False, Now) >= 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCorsPreflightCache.Add(const Key: string; constref Preflight: TCorsPreflightResult; const Method: string;
  const UnsafeNames: TStringArray; Now: Double);
var
  Expiry: Double;
  Index: Integer;
  Kept: array of TPreflightCacheEntry;
begin
  Expiry := Now + Preflight.MaxAge * 1000.0;
  EnterCriticalSection(FLock);
  try
    { Expired entries go first. }
    Kept := nil;
    for Index := 0 to High(FEntries) do
      if FEntries[Index].Expiry > Now then
      begin
        SetLength(Kept, Length(Kept) + 1);
        Kept[High(Kept)] := FEntries[Index];
      end;
    FEntries := Kept;
    if Preflight.MaxAge <= 0 then
      Exit;
    if not IsCorsSafelistedMethod(Method) then
      Store(Key, Method, True, Expiry);
    for Index := 0 to High(UnsafeNames) do
      Store(Key, LowerCase(UnsafeNames[Index]), False, Expiry);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCorsPreflightCache.Clear;
begin
  EnterCriticalSection(FLock);
  try
    FEntries := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TCorsPreflightCache.Count: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := Length(FEntries);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.

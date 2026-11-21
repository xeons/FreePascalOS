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
  A private HTTP cache (RFC 9111), in memory and, when given a folder,
  on disk too (Http.DiskCache):

  - stored: complete responses to GET with a final status, unless
    no-store (request or response) or Vary: *; they need an explicit
    lifetime (max-age, Expires), a validator, or a status cacheable by
    default (section 4.2.2);
  - looked up by URL (without fragment), the stored response matching
    only if the request's fields named by its Vary are the same;
  - fresh (section 4.2): the lifetime from max-age, else Expires minus
    Date, else 10% of the time since Last-Modified (at most a day) for
    statuses cacheable by default; the age from Age, Date and the
    request and response times (section 4.2.3); no-cache in the
    response, or no-cache or max-age=0 in the request, makes it stale;
    max-stale and min-fresh are honoured;
  - a stale response with a validator is revalidated: If-None-Match
    (ETag) or If-Modified-Since (Last-Modified); a 304 freshens the
    stored fields (section 4.3.4) and the stored content is used;
  - a successful unsafe request (POST, PUT, DELETE...) removes the
    URL's response (section 4.4);
  - memory is bounded (32 MiB by default, an entry at most an eighth of
    it), the least recently used going first.

  Thread safe. Plain Pascal (the RTL and Classes), checked on the host
  by tools/HttpTest.
}
unit Http.Cache;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.HeaderFields,
  Url.Records;

const
  DefaultCacheMemoryLimit = 32 * 1024 * 1024;
  HeuristicLifetimeCeiling = 86400;

type
  THttpCacheEntry = class
  public
    Key: string;
    Status: Integer;
    Reason: string;
    Fields: THttpHeaderFieldArray;
    Body: TBytes;
    RequestTime: Int64;
    ResponseTime: Int64;
    { The request's values of the fields Vary names. }
    VaryKey: string;
    LastUsed: QWord;
    function Clone: THttpCacheEntry;
    function Size: Int64;
  end;

  THttpCacheLookup = (CacheMiss, CacheFresh, CacheStale);

  THttpCache = class
  private
    FEntries: array of THttpCacheEntry;
    FMemoryLimit: Int64;
    FMemoryUsed: Int64;
    FDirectory: string;
    FLock: TRTLCriticalSection;
    FUseCounter: QWord;
    function IndexOfKey(const Key, VaryKey: string): Integer;
    procedure RemoveAt(Index: Integer);
    procedure MakeRoom(Needed: Int64);
    procedure Insert(Entry: THttpCacheEntry);
  public
    { Directory: '' for memory only. }
    constructor Create(MemoryLimit: Int64 = DefaultCacheMemoryLimit; const Directory: string = '');
    destructor Destroy; override;
    { What the cache has for a GET of the URL: CacheFresh or CacheStale
      with Entry a copy for the caller (free it), or CacheMiss. }
    function Lookup(constref Url: TUrlRecord; RequestFields: THttpHeaders; Now: Int64;
      out Entry: THttpCacheEntry): THttpCacheLookup;
    function IsStorable(const Method: string; Status: Integer; RequestFields: THttpHeaders;
      constref ResponseFields: THttpHeaderFieldArray): Boolean;
    procedure Store(constref Url: TUrlRecord; RequestFields: THttpHeaders; Status: Integer; const Reason: string;
      constref ResponseFields: THttpHeaderFieldArray; const Body: TBytes; RequestTime, ResponseTime: Int64);
    { A 304 for a stored response: its fields freshened. Returns the
      updated copy (free it), or nil when nothing is stored. }
    function Freshen(constref Url: TUrlRecord; RequestFields: THttpHeaders;
      constref NotModifiedFields: THttpHeaderFieldArray; RequestTime, ResponseTime: Int64): THttpCacheEntry;
    procedure Invalidate(constref Url: TUrlRecord);
    procedure Clear;
    { A new limit for the memory the entries take: the least recently
      used go at once until the rest fit. }
    procedure SetMemoryLimit(Limit: Int64);
    property MemoryUsed: Int64 read FMemoryUsed;
    property MemoryLimit: Int64 read FMemoryLimit;
    property Directory: string read FDirectory;
  end;

{ The URL as a cache key: without its fragment. }
function CacheKeyOf(constref Url: TUrlRecord): string;
{ How long a response stays fresh, in seconds (RFC 9111 4.2.1). }
function FreshnessLifetime(constref Fields: THttpHeaderFieldArray; Status: Integer): Int64;
{ Its current age (RFC 9111 4.2.3). }
function CurrentAge(constref Fields: THttpHeaderFieldArray; RequestTime, ResponseTime, Now: Int64): Int64;
{ If-None-Match and If-Modified-Since for revalidating Entry. }
procedure AddValidators(Entry: THttpCacheEntry; RequestFields: THttpHeaders);
function HasValidator(constref Fields: THttpHeaderFieldArray): Boolean;

implementation

uses
  Http.CacheControl,
  Http.Dates,
  Http.DiskCache,
  Http.FieldValues,
  Http.StatusCodes;

function CacheKeyOf(constref Url: TUrlRecord): string;
begin
  Result := SerializeUrl(Url, True);
end;

function DateField(constref Fields: THttpHeaderFieldArray; const Name: string; out Time: Int64): Boolean;
begin
  Result := FieldsHave(Fields, Name) and ParseHttpDate(FieldsValue(Fields, Name), Time);
end;

function FreshnessLifetime(constref Fields: THttpHeaderFieldArray; Status: Integer): Int64;
var
  Directives: TCacheDirectives;
  Expires, Date, Modified: Int64;
begin
  Directives := CacheDirectivesOf(Fields);
  if Directives.MaxAge >= 0 then
    Exit(Directives.MaxAge);
  if FieldsHave(Fields, 'expires') then
  begin
    if not DateField(Fields, 'expires', Expires) then
      Exit(0);
    if not DateField(Fields, 'date', Date) then
      Exit(0);
    Result := Expires - Date;
    if Result < 0 then
      Result := 0;
    Exit;
  end;
  if StatusIsHeuristicallyCacheable(Status) and DateField(Fields, 'last-modified', Modified) and
     DateField(Fields, 'date', Date) and (Date > Modified) then
  begin
    Result := (Date - Modified) div 10;
    if Result > HeuristicLifetimeCeiling then
      Result := HeuristicLifetimeCeiling;
    Exit;
  end;
  Result := 0;
end;

function CurrentAge(constref Fields: THttpHeaderFieldArray; RequestTime, ResponseTime, Now: Int64): Int64;
var
  Date, AgeValue, ApparentAge, ResponseDelay, CorrectedAgeValue, CorrectedInitialAge: Int64;
begin
  if not DateField(Fields, 'date', Date) then
    Date := ResponseTime;
  if not ParseDecimalNumber(FieldsValue(Fields, 'age'), AgeValue) then
    AgeValue := 0;
  ApparentAge := ResponseTime - Date;
  if ApparentAge < 0 then
    ApparentAge := 0;
  ResponseDelay := ResponseTime - RequestTime;
  CorrectedAgeValue := AgeValue + ResponseDelay;
  CorrectedInitialAge := ApparentAge;
  if CorrectedAgeValue > CorrectedInitialAge then
    CorrectedInitialAge := CorrectedAgeValue;
  Result := CorrectedInitialAge + (Now - ResponseTime);
end;

function HasValidator(constref Fields: THttpHeaderFieldArray): Boolean;
begin
  Result := FieldsHave(Fields, 'etag') or FieldsHave(Fields, 'last-modified');
end;

procedure AddValidators(Entry: THttpCacheEntry; RequestFields: THttpHeaders);
begin
  if FieldsHave(Entry.Fields, 'etag') then
    RequestFields.SetValue('if-none-match', FieldsValue(Entry.Fields, 'etag'));
  if FieldsHave(Entry.Fields, 'last-modified') then
    RequestFields.SetValue('if-modified-since', FieldsValue(Entry.Fields, 'last-modified'));
end;

{ "accept-encoding=gzip\n..." for the fields a Vary names; False for
  Vary: *. }
function MakeVaryKey(constref ResponseFields: THttpHeaderFieldArray; RequestFields: THttpHeaders;
  out Key: string): Boolean;
var
  Name: string;
  Field: THttpHeaderField;
begin
  Key := '';
  for Field in ResponseFields do
    if Field.Name = 'vary' then
      for Name in SplitFieldList(Field.Value) do
      begin
        if Name = '*' then
          Exit(False);
        Key := Key + LowerCase(Name) + '=';
        if RequestFields <> nil then
          Key := Key + RequestFields.Combined(Name);
        Key := Key + #10;
      end;
  Result := True;
end;

{ THttpCacheEntry }

function THttpCacheEntry.Clone: THttpCacheEntry;
begin
  Result := THttpCacheEntry.Create;
  Result.Key := Key;
  Result.Status := Status;
  Result.Reason := Reason;
  Result.Fields := Copy(Fields, 0, Length(Fields));
  Result.Body := Copy(Body, 0, Length(Body));
  Result.RequestTime := RequestTime;
  Result.ResponseTime := ResponseTime;
  Result.VaryKey := VaryKey;
end;

function THttpCacheEntry.Size: Int64;
var
  Field: THttpHeaderField;
begin
  Result := Length(Body) + Length(Key) + 128;
  for Field in Fields do
    Inc(Result, Length(Field.Name) + Length(Field.Value) + 32);
end;

{ THttpCache }

constructor THttpCache.Create(MemoryLimit: Int64; const Directory: string);
begin
  inherited Create;
  FMemoryLimit := MemoryLimit;
  FDirectory := Directory;
  InitCriticalSection(FLock);
  if FDirectory <> '' then
    ForceDirectories(FDirectory);
end;

destructor THttpCache.Destroy;
begin
  Clear;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THttpCache.IndexOfKey(const Key, VaryKey: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Key = Key) and (FEntries[Index].VaryKey = VaryKey) then
      Exit(Index);
  Result := -1;
end;

procedure THttpCache.RemoveAt(Index: Integer);
begin
  Dec(FMemoryUsed, FEntries[Index].Size);
  FEntries[Index].Free;
  Delete(FEntries, Index, 1);
end;

procedure THttpCache.MakeRoom(Needed: Int64);
var
  Index, Oldest: Integer;
begin
  while (Length(FEntries) > 0) and (FMemoryUsed + Needed > FMemoryLimit) do
  begin
    Oldest := 0;
    for Index := 1 to High(FEntries) do
      if FEntries[Index].LastUsed < FEntries[Oldest].LastUsed then
        Oldest := Index;
    RemoveAt(Oldest);
  end;
end;

procedure THttpCache.SetMemoryLimit(Limit: Int64);
begin
  if Limit < 0 then
    Limit := 0;
  EnterCriticalSection(FLock);
  try
    FMemoryLimit := Limit;
    MakeRoom(0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpCache.Insert(Entry: THttpCacheEntry);
var
  Existing: Integer;
begin
  Existing := IndexOfKey(Entry.Key, Entry.VaryKey);
  if Existing >= 0 then
    RemoveAt(Existing);
  MakeRoom(Entry.Size);
  Inc(FUseCounter);
  Entry.LastUsed := FUseCounter;
  SetLength(FEntries, Length(FEntries) + 1);
  FEntries[High(FEntries)] := Entry;
  Inc(FMemoryUsed, Entry.Size);
end;

function THttpCache.Lookup(constref Url: TUrlRecord; RequestFields: THttpHeaders; Now: Int64;
  out Entry: THttpCacheEntry): THttpCacheLookup;
var
  Key, VaryKey: string;
  Index: Integer;
  Found: THttpCacheEntry;
  Request: TCacheDirectives;
  Response: TCacheDirectives;
  Lifetime, Age: Int64;
begin
  Entry := nil;
  Result := CacheMiss;
  Key := CacheKeyOf(Url);
  Found := nil;
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(FEntries) do
      if (FEntries[Index].Key = Key) and MakeVaryKey(FEntries[Index].Fields, RequestFields, VaryKey) and
         (VaryKey = FEntries[Index].VaryKey) then
      begin
        Inc(FUseCounter);
        FEntries[Index].LastUsed := FUseCounter;
        Found := FEntries[Index].Clone;
        Break;
      end;
    if (Found = nil) and (FDirectory <> '') then
    begin
      Found := LoadCacheEntry(FDirectory, Key);
      if (Found <> nil) and (not MakeVaryKey(Found.Fields, RequestFields, VaryKey) or (VaryKey <> Found.VaryKey)) then
        FreeAndNil(Found);
      if Found <> nil then
        Insert(Found.Clone);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Found = nil then
    Exit;
  Entry := Found;
  Request := ParseCacheControl('');
  if RequestFields <> nil then
    Request := ParseCacheControl(RequestFields.Combined('cache-control'));
  Response := CacheDirectivesOf(Found.Fields);
  Lifetime := FreshnessLifetime(Found.Fields, Found.Status);
  Age := CurrentAge(Found.Fields, Found.RequestTime, Found.ResponseTime, Now);
  if Request.MaxAge >= 0 then
    if Request.MaxAge < Lifetime then
      Lifetime := Request.MaxAge;
  if Request.MinFresh > 0 then
    Inc(Age, Request.MinFresh);
  if Response.NoCache or Request.NoCache then
    Result := CacheStale
  else if Lifetime > Age then
    Result := CacheFresh
  else if not Response.MustRevalidate and (Request.MaxStale >= 0) and (Age - Lifetime <= Request.MaxStale) then
    Result := CacheFresh
  else
    Result := CacheStale;
end;

function THttpCache.IsStorable(const Method: string; Status: Integer; RequestFields: THttpHeaders;
  constref ResponseFields: THttpHeaderFieldArray): Boolean;
var
  Request, Response: TCacheDirectives;
  VaryKey: string;
begin
  Result := False;
  if (Method <> 'GET') or (Status < 200) or (Status = 206) or (Status = 304) then
    Exit;
  Request := ParseCacheControl('');
  if RequestFields <> nil then
    Request := ParseCacheControl(RequestFields.Combined('cache-control'));
  Response := CacheDirectivesOf(ResponseFields);
  if Request.NoStore or Response.NoStore then
    Exit;
  if not MakeVaryKey(ResponseFields, RequestFields, VaryKey) then
    Exit;
  Result := (Response.MaxAge >= 0) or FieldsHave(ResponseFields, 'expires') or Response.PublicResponse or
    Response.NoCache or HasValidator(ResponseFields) or StatusIsHeuristicallyCacheable(Status);
end;

procedure THttpCache.Store(constref Url: TUrlRecord; RequestFields: THttpHeaders; Status: Integer;
  const Reason: string; constref ResponseFields: THttpHeaderFieldArray; const Body: TBytes;
  RequestTime, ResponseTime: Int64);
var
  Entry: THttpCacheEntry;
  VaryKey: string;
begin
  if not MakeVaryKey(ResponseFields, RequestFields, VaryKey) then
    Exit;
  Entry := THttpCacheEntry.Create;
  Entry.Key := CacheKeyOf(Url);
  Entry.Status := Status;
  Entry.Reason := Reason;
  Entry.Fields := Copy(ResponseFields, 0, Length(ResponseFields));
  Entry.Body := Body;
  Entry.RequestTime := RequestTime;
  Entry.ResponseTime := ResponseTime;
  Entry.VaryKey := VaryKey;
  if Entry.Size > FMemoryLimit div 8 then
  begin
    Entry.Free;
    Exit;
  end;
  EnterCriticalSection(FLock);
  try
    if FDirectory <> '' then
      SaveCacheEntry(FDirectory, Entry);
    Insert(Entry);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ The stored fields with the 304's replacing those of the same names
  (but for the ones describing the content's framing). }
function MergeFields(constref Stored, Fresh: THttpHeaderFieldArray): THttpHeaderFieldArray;
var
  Field: THttpHeaderField;
  Index: Integer;
begin
  Result := nil;
  for Field in Stored do
    if not FieldsHave(Fresh, Field.Name) or (Field.Name = 'content-length') or (Field.Name = 'content-encoding') or
       (Field.Name = 'transfer-encoding') then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Field;
    end;
  for Field in Fresh do
    if (Field.Name <> 'content-length') and (Field.Name <> 'content-encoding') and
       (Field.Name <> 'transfer-encoding') then
    begin
      Index := Length(Result);
      SetLength(Result, Index + 1);
      Result[Index] := Field;
    end;
end;

function THttpCache.Freshen(constref Url: TUrlRecord; RequestFields: THttpHeaders;
  constref NotModifiedFields: THttpHeaderFieldArray; RequestTime, ResponseTime: Int64): THttpCacheEntry;
var
  Key, VaryKey: string;
  Index: Integer;
  Updated: THttpCacheEntry;
begin
  Result := nil;
  Key := CacheKeyOf(Url);
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(FEntries) do
      if (FEntries[Index].Key = Key) and MakeVaryKey(FEntries[Index].Fields, RequestFields, VaryKey) and
         (VaryKey = FEntries[Index].VaryKey) then
      begin
        Updated := FEntries[Index].Clone;
        Updated.Fields := MergeFields(FEntries[Index].Fields, NotModifiedFields);
        Updated.RequestTime := RequestTime;
        Updated.ResponseTime := ResponseTime;
        Insert(Updated);
        if FDirectory <> '' then
          SaveCacheEntry(FDirectory, Updated);
        Result := Updated.Clone;
        Exit;
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpCache.Invalidate(constref Url: TUrlRecord);
var
  Key: string;
  Index: Integer;
begin
  Key := CacheKeyOf(Url);
  EnterCriticalSection(FLock);
  try
    Index := High(FEntries);
    while Index >= 0 do
    begin
      if FEntries[Index].Key = Key then
        RemoveAt(Index);
      Dec(Index);
    end;
    if FDirectory <> '' then
      DeleteCacheEntry(FDirectory, Key);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpCache.Clear;
begin
  EnterCriticalSection(FLock);
  try
    while Length(FEntries) > 0 do
      RemoveAt(High(FEntries));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.

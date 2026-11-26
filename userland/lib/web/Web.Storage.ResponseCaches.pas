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
  The Cache API's storage (Service Workers, section 5.4): per origin an
  ordered map of cache names to caches, each an ordered list of request
  and response pairs with the response's body. The process keeps one
  store; every window and worker of an origin sees the same caches.
  Matching (URLs, Vary) is the script's (platform/67-caches.js); this is
  the storage: caches by name, entries by id, and batches of puts and
  deletes applied together.

  A cache has an id that stays valid after CacheStorage.delete took its
  name away (a Cache object goes on working with it). An origin's caches
  are loaded from OriginDataBackend when first used and saved after each
  change. Each origin may keep CacheQuota bytes.
}
unit Web.Storage.ResponseCaches;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  CacheQuota = 64 * 1024 * 1024;
  CachesKind = 'caches';

type
  TCachedField = record
    Name: string;
    Value: string;
  end;
  TCachedFields = array of TCachedField;

  TCacheEntry = class
  public
    Id: Integer;
    RequestMethod: string;
    RequestUrl: string;
    RequestHeaders: TCachedFields;
    ResponseType: string;
    ResponseUrl: string;
    Status: Integer;
    StatusText: string;
    ResponseHeaders: TCachedFields;
    Redirected: Boolean;
    Body: TBytes;
    function Size: Int64;
  end;

  TResponseCache = class
  private
    FEntries: TList;
    function GetEntry(Index: Integer): TCacheEntry;
  public
    Id: Integer;
    Name: string;
    Origin: string;
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    function IndexOfId(EntryId: Integer): Integer;
    function Size: Int64;
    property Entries[Index: Integer]: TCacheEntry read GetEntry; default;
  end;

  TCacheOperationKind = (CacheOperationDelete, CacheOperationPut);

  TCacheOperation = record
    Kind: TCacheOperationKind;
    EntryId: Integer;
    Entry: TCacheEntry;
  end;
  TCacheOperations = array of TCacheOperation;

  TCacheWriteResult = (CacheWriteDone, CacheWriteQuotaExceeded, CacheWriteNoCache);

{ The names of an origin's caches in creation order. }
function CacheNames(const Origin: string): TStringArray;
{ The cache of a name, nil if none. }
function FindCache(const Origin, Name: string): TResponseCache;
{ The cache of a name, made if there is none. }
function OpenCache(const Origin, Name: string): TResponseCache;
{ False when there was no such cache. }
function DeleteCache(const Origin, Name: string): Boolean;
{ A cache by id (also one deleted from its origin's names), nil if none
  or of another origin. }
function CacheById(const Origin: string; Id: Integer): TResponseCache;
{ Applies the operations in order, all or none; the puts' entries are
  taken (freed when not applied). }
function WriteCache(Cache: TResponseCache; const Operations: TCacheOperations): TCacheWriteResult;
{ The bytes an origin's caches hold. }
function OriginCacheUsage(const Origin: string): Int64;
{ Forgets every origin's caches in memory (tests, private browsing's
  end); nothing is saved. }
procedure ForgetAllCaches;

implementation

uses
  Web.Storage.OriginData;

type
  TOriginCaches = class
  public
    Origin: string;
    Named: TList;
    constructor Create;
    destructor Destroy; override;
  end;

var
  Origins: TList;
  { Every cache ever opened, named or not (deleted ones stay usable). }
  AllCaches: TList;
  NextCacheId: Integer = 0;
  NextEntryId: Integer = 0;

function TCacheEntry.Size: Int64;
var
  Index: Integer;
begin
  Result := Length(Body) + Length(RequestUrl) + Length(ResponseUrl) + Length(StatusText) + 64;
  for Index := 0 to High(RequestHeaders) do
    Inc(Result, Length(RequestHeaders[Index].Name) + Length(RequestHeaders[Index].Value));
  for Index := 0 to High(ResponseHeaders) do
    Inc(Result, Length(ResponseHeaders[Index].Name) + Length(ResponseHeaders[Index].Value));
end;

constructor TResponseCache.Create;
begin
  inherited Create;
  FEntries := TList.Create;
end;

destructor TResponseCache.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FEntries.Count - 1 do
    TCacheEntry(FEntries[Index]).Free;
  FEntries.Free;
  inherited Destroy;
end;

function TResponseCache.GetEntry(Index: Integer): TCacheEntry;
begin
  Result := TCacheEntry(FEntries[Index]);
end;

function TResponseCache.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TResponseCache.IndexOfId(EntryId: Integer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FEntries.Count - 1 do
    if TCacheEntry(FEntries[Index]).Id = EntryId then
      Exit(Index);
  Result := -1;
end;

function TResponseCache.Size: Int64;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FEntries.Count - 1 do
    Inc(Result, TCacheEntry(FEntries[Index]).Size);
end;

constructor TOriginCaches.Create;
begin
  inherited Create;
  Named := TList.Create;
end;

destructor TOriginCaches.Destroy;
begin
  Named.Free;
  inherited Destroy;
end;

{ ---- saving and loading ---- }

procedure WriteFields(Writer: TOriginDataWriter; const Fields: TCachedFields);
var
  Index: Integer;
begin
  Writer.WriteInteger(Length(Fields));
  for Index := 0 to High(Fields) do
  begin
    Writer.WriteText(Fields[Index].Name);
    Writer.WriteText(Fields[Index].Value);
  end;
end;

function ReadFields(Reader: TOriginDataReader): TCachedFields;
var
  Count, Index: Int64;
begin
  Result := nil;
  Count := Reader.ReadInteger;
  if (Count < 0) or (Count > 10000) then
    Exit;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
  begin
    Result[Index].Name := Reader.ReadText;
    Result[Index].Value := Reader.ReadText;
  end;
end;

procedure SaveOrigin(Caches: TOriginCaches);
var
  Writer: TOriginDataWriter;
  CacheIndex, EntryIndex: Integer;
  Cache: TResponseCache;
  Entry: TCacheEntry;
begin
  if OriginDataBackend = nil then
    Exit;
  if Caches.Named.Count = 0 then
  begin
    OriginDataBackend.Save(CachesKind, Caches.Origin, nil);
    Exit;
  end;
  Writer := TOriginDataWriter.Create;
  try
    Writer.WriteInteger(1);
    Writer.WriteInteger(Caches.Named.Count);
    for CacheIndex := 0 to Caches.Named.Count - 1 do
    begin
      Cache := TResponseCache(Caches.Named[CacheIndex]);
      Writer.WriteText(Cache.Name);
      Writer.WriteInteger(Cache.Count);
      for EntryIndex := 0 to Cache.Count - 1 do
      begin
        Entry := Cache[EntryIndex];
        Writer.WriteText(Entry.RequestMethod);
        Writer.WriteText(Entry.RequestUrl);
        WriteFields(Writer, Entry.RequestHeaders);
        Writer.WriteText(Entry.ResponseType);
        Writer.WriteText(Entry.ResponseUrl);
        Writer.WriteInteger(Entry.Status);
        Writer.WriteText(Entry.StatusText);
        WriteFields(Writer, Entry.ResponseHeaders);
        Writer.WriteInteger(Ord(Entry.Redirected));
        Writer.WriteBytes(Entry.Body);
      end;
    end;
    OriginDataBackend.Save(CachesKind, Caches.Origin, Writer.Data);
  finally
    Writer.Free;
  end;
end;

function NewCache(const Origin, Name: string): TResponseCache;
begin
  Result := TResponseCache.Create;
  Inc(NextCacheId);
  Result.Id := NextCacheId;
  Result.Origin := Origin;
  Result.Name := Name;
  AllCaches.Add(Result);
end;

procedure LoadOrigin(Caches: TOriginCaches);
var
  Reader: TOriginDataReader;
  CacheCount, EntryCount, CacheIndex, EntryIndex: Int64;
  Cache: TResponseCache;
  Entry: TCacheEntry;
begin
  if OriginDataBackend = nil then
    Exit;
  Reader := TOriginDataReader.Create(OriginDataBackend.Load(CachesKind, Caches.Origin));
  try
    if Reader.AtEnd or (Reader.ReadInteger <> 1) then
      Exit;
    CacheCount := Reader.ReadInteger;
    CacheIndex := 0;
    while (CacheIndex < CacheCount) and not Reader.Failed do
    begin
      Cache := NewCache(Caches.Origin, Reader.ReadText);
      Caches.Named.Add(Cache);
      EntryCount := Reader.ReadInteger;
      EntryIndex := 0;
      while (EntryIndex < EntryCount) and not Reader.Failed do
      begin
        Entry := TCacheEntry.Create;
        Inc(NextEntryId);
        Entry.Id := NextEntryId;
        Entry.RequestMethod := Reader.ReadText;
        Entry.RequestUrl := Reader.ReadText;
        Entry.RequestHeaders := ReadFields(Reader);
        Entry.ResponseType := Reader.ReadText;
        Entry.ResponseUrl := Reader.ReadText;
        Entry.Status := Reader.ReadInteger;
        Entry.StatusText := Reader.ReadText;
        Entry.ResponseHeaders := ReadFields(Reader);
        Entry.Redirected := Reader.ReadInteger <> 0;
        Entry.Body := Reader.ReadBytes;
        if Reader.Failed then
          Entry.Free
        else
          Cache.FEntries.Add(Entry);
        Inc(EntryIndex);
      end;
      Inc(CacheIndex);
    end;
  finally
    Reader.Free;
  end;
end;

function OriginOf(const Origin: string): TOriginCaches;
var
  Index: Integer;
begin
  for Index := 0 to Origins.Count - 1 do
    if TOriginCaches(Origins[Index]).Origin = Origin then
      Exit(TOriginCaches(Origins[Index]));
  Result := TOriginCaches.Create;
  Result.Origin := Origin;
  Origins.Add(Result);
  LoadOrigin(Result);
end;

{ ---- the store ---- }

function CacheNames(const Origin: string): TStringArray;
var
  Caches: TOriginCaches;
  Index: Integer;
begin
  Caches := OriginOf(Origin);
  Result := nil;
  SetLength(Result, Caches.Named.Count);
  for Index := 0 to Caches.Named.Count - 1 do
    Result[Index] := TResponseCache(Caches.Named[Index]).Name;
end;

function FindCache(const Origin, Name: string): TResponseCache;
var
  Caches: TOriginCaches;
  Index: Integer;
begin
  Caches := OriginOf(Origin);
  for Index := 0 to Caches.Named.Count - 1 do
    if TResponseCache(Caches.Named[Index]).Name = Name then
      Exit(TResponseCache(Caches.Named[Index]));
  Result := nil;
end;

function OpenCache(const Origin, Name: string): TResponseCache;
var
  Caches: TOriginCaches;
begin
  Result := FindCache(Origin, Name);
  if Result <> nil then
    Exit;
  Caches := OriginOf(Origin);
  Result := NewCache(Origin, Name);
  Caches.Named.Add(Result);
  SaveOrigin(Caches);
end;

function DeleteCache(const Origin, Name: string): Boolean;
var
  Cache: TResponseCache;
  Caches: TOriginCaches;
begin
  Cache := FindCache(Origin, Name);
  Result := Cache <> nil;
  if not Result then
    Exit;
  Caches := OriginOf(Origin);
  Caches.Named.Remove(Cache);
  SaveOrigin(Caches);
end;

function CacheById(const Origin: string; Id: Integer): TResponseCache;
var
  Index: Integer;
begin
  for Index := 0 to AllCaches.Count - 1 do
    if (TResponseCache(AllCaches[Index]).Id = Id) and (TResponseCache(AllCaches[Index]).Origin = Origin) then
      Exit(TResponseCache(AllCaches[Index]));
  Result := nil;
end;

function OriginCacheUsage(const Origin: string): Int64;
var
  Caches: TOriginCaches;
  Index: Integer;
begin
  Caches := OriginOf(Origin);
  Result := 0;
  for Index := 0 to Caches.Named.Count - 1 do
    Inc(Result, TResponseCache(Caches.Named[Index]).Size);
end;

procedure FreeOperationEntries(const Operations: TCacheOperations);
var
  Index: Integer;
begin
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = CacheOperationPut then
      Operations[Index].Entry.Free;
end;

function WriteCache(Cache: TResponseCache; const Operations: TCacheOperations): TCacheWriteResult;
var
  Usage: Int64;
  Index, Found: Integer;
  Caches: TOriginCaches;
begin
  if Cache = nil then
  begin
    FreeOperationEntries(Operations);
    Exit(CacheWriteNoCache);
  end;
  Usage := OriginCacheUsage(Cache.Origin);
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = CacheOperationPut then
      Inc(Usage, Operations[Index].Entry.Size)
    else
    begin
      Found := Cache.IndexOfId(Operations[Index].EntryId);
      if Found >= 0 then
        Dec(Usage, Cache[Found].Size);
    end;
  if Usage > CacheQuota then
  begin
    FreeOperationEntries(Operations);
    Exit(CacheWriteQuotaExceeded);
  end;
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = CacheOperationPut then
    begin
      Inc(NextEntryId);
      Operations[Index].Entry.Id := NextEntryId;
      Cache.FEntries.Add(Operations[Index].Entry);
    end
    else
    begin
      Found := Cache.IndexOfId(Operations[Index].EntryId);
      if Found >= 0 then
      begin
        Cache[Found].Free;
        Cache.FEntries.Delete(Found);
      end;
    end;
  Caches := OriginOf(Cache.Origin);
  if Caches.Named.IndexOf(Cache) >= 0 then
    SaveOrigin(Caches);
  Result := CacheWriteDone;
end;

procedure ForgetAllCaches;
var
  Index: Integer;
begin
  for Index := 0 to Origins.Count - 1 do
    TOriginCaches(Origins[Index]).Free;
  Origins.Clear;
  for Index := 0 to AllCaches.Count - 1 do
    TResponseCache(AllCaches[Index]).Free;
  AllCaches.Clear;
end;

initialization
  Origins := TList.Create;
  AllCaches := TList.Create;
finalization
  ForgetAllCaches;
  FreeAndNil(Origins);
  FreeAndNil(AllCaches);
end.

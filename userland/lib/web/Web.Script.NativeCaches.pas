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
  The natives of the Cache API (platform/67-caches.js) over the
  process's store (Web.Storage.ResponseCaches), for the calling
  context's origin (an opaque origin has no caches: SecurityError):

    natives.cacheNames()               the names in creation order
    natives.cacheHas(name)             whether the cache exists
    natives.cacheOpen(name)            its id (made if missing)
    natives.cacheDelete(name)          whether there was one
    natives.cacheEntries(id)           [entryId, method, url, request
                                       headers, type, response url,
                                       status, statusText, response
                                       headers, redirected] per entry,
                                       null if no such cache
    natives.cacheBody(id, entryId)     the body (Uint8Array), null if gone
    natives.cacheWrite(id, operations) ['delete', entryId] and ['put',
                                       method, url, request headers, type,
                                       response url, status, statusText,
                                       response headers, redirected, body]
                                       applied together: 'done', 'quota'
                                       or 'none' (no such cache)

  Headers are arrays of [name, value].
}
unit Web.Script.NativeCaches;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineCacheNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Web.Script.ContextTasks,
  Web.Storage.ResponseCaches;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

{ The calling context's origin; False (a SecurityError thrown) when it
  is opaque. }
function CacheOrigin(Context: TBindingContext; out Origin: string; out Thrown: TJsValue): Boolean;
begin
  Origin := ContextOriginText(Context);
  Result := Origin <> 'null';
  if not Result then
    Thrown := Context.ThrowDomException('SecurityError', 'The Cache API is not available to an opaque origin.');
end;

function LengthOf(Context: TBindingContext; Value: TJsValue): Integer;
begin
  if not JsIsObject(Value) then
    Exit(0);
  Result := Trunc(Context.Engine.ToNumber(Context.Engine.GetProperty(Value, 'length')));
end;

function Item(Context: TBindingContext; Value: TJsValue; Index: Integer): TJsValue;
begin
  Result := Context.Engine.GetProperty(Value, IntToStr(Index));
end;

function FieldsOf(Context: TBindingContext; Value: TJsValue): TCachedFields;
var
  Index: Integer;
  Pair: TJsValue;
begin
  Result := nil;
  SetLength(Result, LengthOf(Context, Value));
  for Index := 0 to High(Result) do
  begin
    Pair := Item(Context, Value, Index);
    Result[Index].Name := Context.Engine.ToText(Item(Context, Pair, 0));
    Result[Index].Value := Context.Engine.ToText(Item(Context, Pair, 1));
  end;
end;

function FieldsValue(Context: TBindingContext; const Fields: TCachedFields): TJsValue;
var
  Values: array of TJsValue;
  Index: Integer;
begin
  Values := nil;
  SetLength(Values, Length(Fields));
  for Index := 0 to High(Fields) do
    Values[Index] := Context.NewArray([Context.TextValue(Fields[Index].Name), Context.TextValue(Fields[Index].Value)]);
  Result := Context.NewArray(Values);
end;

function NativeCacheNames(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Result := Context.StringArray(CacheNames(Origin));
end;

function NativeCacheHas(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Result := JsBoolean(FindCache(Origin, Context.Engine.ToText(Arg(Args, ArgCount, 0))) <> nil);
end;

function NativeCacheOpen(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Result := JsInteger(OpenCache(Origin, Context.Engine.ToText(Arg(Args, ArgCount, 0))).Id);
end;

function NativeCacheDelete(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Result := JsBoolean(DeleteCache(Origin, Context.Engine.ToText(Arg(Args, ArgCount, 0))));
end;

function NativeCacheEntries(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
  Cache: TResponseCache;
  Values: array of TJsValue;
  Entry: TCacheEntry;
  Index: Integer;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Cache := CacheById(Origin, Trunc(Context.Engine.ToNumber(Arg(Args, ArgCount, 0))));
  if Cache = nil then
    Exit(JsNull);
  Values := nil;
  SetLength(Values, Cache.Count);
  for Index := 0 to Cache.Count - 1 do
  begin
    Entry := Cache[Index];
    Values[Index] := Context.NewArray([JsInteger(Entry.Id), Context.TextValue(Entry.RequestMethod),
      Context.TextValue(Entry.RequestUrl), FieldsValue(Context, Entry.RequestHeaders),
      Context.TextValue(Entry.ResponseType), Context.TextValue(Entry.ResponseUrl), JsInteger(Entry.Status),
      Context.TextValue(Entry.StatusText), FieldsValue(Context, Entry.ResponseHeaders), JsBoolean(Entry.Redirected)]);
  end;
  Result := Context.NewArray(Values);
end;

function NativeCacheBody(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
  Cache: TResponseCache;
  Found: Integer;
  Body: TBytes;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Result := JsNull;
  Cache := CacheById(Origin, Trunc(Context.Engine.ToNumber(Arg(Args, ArgCount, 0))));
  if Cache = nil then
    Exit;
  Found := Cache.IndexOfId(Trunc(Context.Engine.ToNumber(Arg(Args, ArgCount, 1))));
  if Found < 0 then
    Exit;
  Body := Cache[Found].Body;
  if Length(Body) = 0 then
    Result := Context.Engine.NewUint8Array(nil, 0)
  else
    Result := Context.Engine.NewUint8Array(@Body[0], Length(Body));
end;

function EntryOf(Context: TBindingContext; Operation: TJsValue): TCacheEntry;
var
  Data: PByte;
  Count: SizeInt;
begin
  Result := TCacheEntry.Create;
  Result.RequestMethod := Context.Engine.ToText(Item(Context, Operation, 1));
  Result.RequestUrl := Context.Engine.ToText(Item(Context, Operation, 2));
  Result.RequestHeaders := FieldsOf(Context, Item(Context, Operation, 3));
  Result.ResponseType := Context.Engine.ToText(Item(Context, Operation, 4));
  Result.ResponseUrl := Context.Engine.ToText(Item(Context, Operation, 5));
  Result.Status := Trunc(Context.Engine.ToNumber(Item(Context, Operation, 6)));
  Result.StatusText := Context.Engine.ToText(Item(Context, Operation, 7));
  Result.ResponseHeaders := FieldsOf(Context, Item(Context, Operation, 8));
  Result.Redirected := Context.Engine.ToNumber(Item(Context, Operation, 9)) <> 0;
  if Context.Engine.BufferSourceData(Item(Context, Operation, 10), Data, Count) and (Count > 0) then
  begin
    SetLength(Result.Body, Count);
    Move(Data^, Result.Body[0], Count);
  end;
end;

function NativeCacheWrite(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Origin: string;
  Cache: TResponseCache;
  List, Operation: TJsValue;
  Operations: TCacheOperations;
  Index: Integer;
begin
  Context := ContextOfRealm(R);
  if not CacheOrigin(Context, Origin, Result) then
    Exit;
  Cache := CacheById(Origin, Trunc(Context.Engine.ToNumber(Arg(Args, ArgCount, 0))));
  List := Arg(Args, ArgCount, 1);
  Operations := nil;
  SetLength(Operations, LengthOf(Context, List));
  for Index := 0 to High(Operations) do
  begin
    Operation := Item(Context, List, Index);
    if Context.Engine.ToText(Item(Context, Operation, 0)) = 'put' then
    begin
      Operations[Index].Kind := CacheOperationPut;
      Operations[Index].Entry := EntryOf(Context, Operation);
    end
    else
    begin
      Operations[Index].Kind := CacheOperationDelete;
      Operations[Index].EntryId := Trunc(Context.Engine.ToNumber(Item(Context, Operation, 1)));
    end;
  end;
  case WriteCache(Cache, Operations) of
    CacheWriteDone: Result := Context.TextValue('done');
    CacheWriteQuotaExceeded: Result := Context.TextValue('quota');
  else
    Result := Context.TextValue('none');
  end;
end;

procedure DefineCacheNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'cacheNames', @NativeCacheNames, 0);
  Context.Engine.DefineFunction(Natives, 'cacheHas', @NativeCacheHas, 1);
  Context.Engine.DefineFunction(Natives, 'cacheOpen', @NativeCacheOpen, 1);
  Context.Engine.DefineFunction(Natives, 'cacheDelete', @NativeCacheDelete, 1);
  Context.Engine.DefineFunction(Natives, 'cacheEntries', @NativeCacheEntries, 1);
  Context.Engine.DefineFunction(Natives, 'cacheBody', @NativeCacheBody, 2);
  Context.Engine.DefineFunction(Natives, 'cacheWrite', @NativeCacheWrite, 2);
end;

end.

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
  The natives of the platform scripts' fetch (platform/50-fetch.js):

    natives.fetchStart(descriptor)  starts a fetch through the
                                    environment, returns its id (-1: the
                                    environment cannot fetch)
    natives.fetchAbort(id)          cancels it

  and what comes back as natives.onFetchEvent(id, kind, ...):
  ('response', status, statusText, headers, url, {type, redirected}),
  ('data', Uint8Array), ('end') or ('error', message). A context's
  fetches are cancelled when it goes.
}
unit Web.Script.NativeFetch;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

procedure DefineFetchNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Classes,
  Js.Functions,
  Js.Engine,
  Web.ScriptEnvironment;

type
  TNativeFetchSink = class(TScriptFetchSink)
  public
    Context: TBindingContext;
    Id: Integer;
    Handle: TObject;
    procedure ResponseArrived(Status: Integer; const StatusText, Url, ResponseType: string; Redirected: Boolean;
      const Headers: TScriptFetchHeaders); override;
    procedure DataArrived(Data: Pointer; Count: PtrUInt); override;
    procedure Finished(Success: Boolean; const ErrorText: string); override;
  end;

var
  ActiveSinks: TList;
  NextFetchId: Integer;

function FindSink(Context: TBindingContext; Id: Integer): TNativeFetchSink;
var
  Index: Integer;
begin
  for Index := 0 to ActiveSinks.Count - 1 do
    if (TNativeFetchSink(ActiveSinks[Index]).Context = Context) and (TNativeFetchSink(ActiveSinks[Index]).Id = Id) then
      Exit(TNativeFetchSink(ActiveSinks[Index]));
  Result := nil;
end;

procedure Forget(Sink: TNativeFetchSink);
begin
  ActiveSinks.Remove(Sink);
  Sink.Free;
end;

function Usable(Sink: TNativeFetchSink): Boolean;
begin
  Result := (ActiveSinks.IndexOf(Sink) >= 0) and not Sink.Context.Closed and not Sink.Context.Destroying;
end;

procedure TNativeFetchSink.ResponseArrived(Status: Integer; const StatusText, Url, ResponseType: string;
  Redirected: Boolean; const Headers: TScriptFetchHeaders);
var
  Engine: TJsEngine;
  Pairs: array of TJsValue;
  Details: TJsValue;
  Index: Integer;
begin
  if not Usable(Self) then
    Exit;
  Engine := Context.Engine;
  Pairs := nil;
  SetLength(Pairs, Length(Headers));
  for Index := 0 to High(Headers) do
    Pairs[Index] := Context.NewArray([Context.TextValue(Headers[Index].Name), Context.TextValue(Headers[Index].Value)]);
  Details := JsObjectValue(Engine.NewObject);
  Engine.SetProperty(Details, 'type', Context.TextValue(ResponseType));
  Engine.SetProperty(Details, 'redirected', JsBoolean(Redirected));
  Context.CallPlatform('onFetchEvent', [JsInteger(Id), Context.TextValue('response'), JsInteger(Status),
    Context.TextValue(StatusText), Context.NewArray(Pairs), Context.TextValue(Url), Details]);
end;

procedure TNativeFetchSink.DataArrived(Data: Pointer; Count: PtrUInt);
begin
  if not Usable(Self) or (Count = 0) then
    Exit;
  Context.CallPlatform('onFetchEvent', [JsInteger(Id), Context.TextValue('data'),
    Context.Engine.NewUint8Array(Data, Count)]);
end;

procedure TNativeFetchSink.Finished(Success: Boolean; const ErrorText: string);
begin
  if not Usable(Self) then
    Exit;
  if Success then
    Context.CallPlatform('onFetchEvent', [JsInteger(Id), Context.TextValue('end')])
  else
    Context.CallPlatform('onFetchEvent', [JsInteger(Id), Context.TextValue('error'), Context.TextValue(ErrorText)]);
  if ActiveSinks.IndexOf(Self) >= 0 then
    Forget(Self);
end;

function TextProperty(Context: TBindingContext; Target: TJsValue; const Name: string): string;
var
  Value: TJsValue;
begin
  Value := Context.Engine.GetProperty(Target, Name);
  if (Value = JsUndefined) or (Value = JsNull) then
    Exit('');
  Result := ValueToText(Context.Engine.Realm, Value);
end;

function ReadRequest(Context: TBindingContext; Descriptor: TJsValue): TScriptFetchRequest;
var
  Engine: TJsEngine;
  Headers, Pair, Body: TJsValue;
  Count, Index: Integer;
  Data: PByte;
  Length_: SizeInt;
begin
  Engine := Context.Engine;
  Result := Default(TScriptFetchRequest);
  Result.Method := TextProperty(Context, Descriptor, 'method');
  Result.Url := TextProperty(Context, Descriptor, 'url');
  Result.Mode := TextProperty(Context, Descriptor, 'mode');
  Result.Credentials := TextProperty(Context, Descriptor, 'credentials');
  Result.Cache := TextProperty(Context, Descriptor, 'cache');
  Result.Redirect := TextProperty(Context, Descriptor, 'redirect');
  Result.Referrer := TextProperty(Context, Descriptor, 'referrer');
  Result.ReferrerPolicy := TextProperty(Context, Descriptor, 'referrerPolicy');
  Result.Priority := TextProperty(Context, Descriptor, 'priority');
  Result.Destination := TextProperty(Context, Descriptor, 'destination');
  Result.Integrity := TextProperty(Context, Descriptor, 'integrity');
  Result.Keepalive := Engine.GetProperty(Descriptor, 'keepalive') = JsTrue;
  Headers := Engine.GetProperty(Descriptor, 'headers');
  if JsIsObject(Headers) then
  begin
    Count := Trunc(Engine.ToNumber(Engine.GetProperty(Headers, 'length')));
    SetLength(Result.Headers, Count);
    for Index := 0 to Count - 1 do
    begin
      Pair := Engine.GetProperty(Headers, IntToStr(Index));
      Result.Headers[Index].Name := ValueToText(Engine.Realm, Engine.GetProperty(Pair, '0'));
      Result.Headers[Index].Value := ValueToText(Engine.Realm, Engine.GetProperty(Pair, '1'));
    end;
  end;
  Body := Engine.GetProperty(Descriptor, 'body');
  if Engine.BufferSourceData(Body, Data, Length_) then
  begin
    Result.HasBody := True;
    SetLength(Result.Body, Length_);
    if Length_ > 0 then
      Move(Data^, Result.Body[0], Length_);
  end;
end;

function NativeFetchStart(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Request: TScriptFetchRequest;
  Sink: TNativeFetchSink;
begin
  Context := ContextOfRealm(R);
  try
    if ArgCount < 1 then
      Exit(JsInteger(-1));
    Request := ReadRequest(Context, Args^[0]);
    Sink := TNativeFetchSink.Create;
    Sink.Context := Context;
    Inc(NextFetchId);
    Sink.Id := NextFetchId;
    ActiveSinks.Add(Sink);
    Sink.Handle := Context.Environment.StartFetch(Context, Request, Sink);
    if Sink.Handle = nil then
    begin
      Forget(Sink);
      Exit(JsInteger(-1));
    end;
    Result := JsInteger(Sink.Id);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeFetchAbort(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Sink: TNativeFetchSink;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  if ArgCount < 1 then
    Exit;
  Sink := FindSink(Context, Trunc(Context.Engine.ToNumber(Args^[0])));
  if Sink = nil then
    Exit;
  Context.Environment.CancelFetch(Context, Sink.Handle);
  Forget(Sink);
end;

{ A context going cancels its fetches. }
procedure ContextGoing(Context: TBindingContext);
var
  Index: Integer;
  Sink: TNativeFetchSink;
begin
  for Index := ActiveSinks.Count - 1 downto 0 do
  begin
    Sink := TNativeFetchSink(ActiveSinks[Index]);
    if Sink.Context = Context then
    begin
      Context.Environment.CancelFetch(Context, Sink.Handle);
      ActiveSinks.Delete(Index);
      Sink.Free;
    end;
  end;
end;

procedure DefineFetchNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'fetchStart', @NativeFetchStart, 1);
  Context.Engine.DefineFunction(Natives, 'fetchAbort', @NativeFetchAbort, 1);
end;

initialization
  ActiveSinks := TList.Create;
  AddContextGoingHook(@ContextGoing);
finalization
  FreeAndNil(ActiveSinks);
end.

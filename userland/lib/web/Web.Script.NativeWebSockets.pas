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
  The natives of the platform scripts' WebSocket (platform/63-websocket.js):

    natives.webSocketSupported()           whether the environment has them
    natives.webSocketOpen(url, protocols)  opens one, returns its id (-1:
                                           it fails at once)
    natives.webSocketSend(id, isText, data) the payload's bytes (a text
                                           message's UTF-8), or a string
    natives.webSocketClose(id, code, reason) code -1: none
    natives.webSocketForget(id)            no more events

  and what comes back as natives.onWebSocketEvent(id, kind, ...):
  ('open', protocol, extensions), ('message', isText, string or
  Uint8Array), ('sent', count), ('closing') and ('close', wasClean,
  code, reason, failed), the last once. A context's sockets go with it.
}
unit Web.Script.NativeWebSockets;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

procedure DefineWebSocketNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Classes,
  Js.Functions,
  Js.Engine,
  Web.ScriptEnvironment;

type
  TNativeSocketSink = class(TScriptWebSocketSink)
  public
    Context: TBindingContext;
    Id: Integer;
    Handle: TObject;
    procedure Opened(const Protocol, Extensions: string); override;
    procedure MessageArrived(IsText: Boolean; const Data: TBytes); override;
    procedure BytesSent(Count: QWord); override;
    procedure CloseReceived; override;
    procedure Closed(WasClean: Boolean; Code: Word; const Reason: string; Failed: Boolean); override;
  end;

var
  ActiveSockets: TList;
  NextSocketId: Integer;

function FindSocket(Context: TBindingContext; Id: Integer): TNativeSocketSink;
var
  Index: Integer;
begin
  for Index := 0 to ActiveSockets.Count - 1 do
    if (TNativeSocketSink(ActiveSockets[Index]).Context = Context) and
       (TNativeSocketSink(ActiveSockets[Index]).Id = Id) then
      Exit(TNativeSocketSink(ActiveSockets[Index]));
  Result := nil;
end;

function Usable(Sink: TNativeSocketSink): Boolean;
begin
  Result := (ActiveSockets.IndexOf(Sink) >= 0) and not Sink.Context.Closed and not Sink.Context.Destroying;
end;

procedure TNativeSocketSink.Opened(const Protocol, Extensions: string);
begin
  if Usable(Self) then
    Context.CallPlatform('onWebSocketEvent', [JsInteger(Id), Context.TextValue('open'), Context.TextValue(Protocol),
      Context.TextValue(Extensions)]);
end;

procedure TNativeSocketSink.MessageArrived(IsText: Boolean; const Data: TBytes);
var
  Text: string;
  Payload: TJsValue;
begin
  if not Usable(Self) then
    Exit;
  if IsText then
  begin
    SetString(Text, PChar(PByte(Data)), Length(Data));
    Payload := Context.TextValue(Text);
  end
  else
    Payload := Context.Engine.NewUint8Array(PByte(Data), Length(Data));
  Context.CallPlatform('onWebSocketEvent', [JsInteger(Id), Context.TextValue('message'), JsBoolean(IsText), Payload]);
end;

procedure TNativeSocketSink.BytesSent(Count: QWord);
begin
  if Usable(Self) then
    Context.CallPlatform('onWebSocketEvent', [JsInteger(Id), Context.TextValue('sent'), JsNumber(Count)]);
end;

procedure TNativeSocketSink.CloseReceived;
begin
  if Usable(Self) then
    Context.CallPlatform('onWebSocketEvent', [JsInteger(Id), Context.TextValue('closing')]);
end;

procedure TNativeSocketSink.Closed(WasClean: Boolean; Code: Word; const Reason: string; Failed: Boolean);
var
  Live: Boolean;
begin
  Live := Usable(Self);
  if Live then
    Context.CallPlatform('onWebSocketEvent', [JsInteger(Id), Context.TextValue('close'), JsBoolean(WasClean),
      JsInteger(Code), Context.TextValue(Reason), JsBoolean(Failed)]);
  { The connection is over: the environment and this sink let go. }
  if ActiveSockets.IndexOf(Self) >= 0 then
  begin
    ActiveSockets.Remove(Self);
    Context.Environment.ForgetWebSocket(Context, Handle);
    Free;
  end;
end;

function ArgumentOf(Args: PJsValueArray; ArgCount, Index: Integer): TJsValue;
begin
  if Index < ArgCount then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function NativeSupported(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  Result := JsBoolean((Context <> nil) and (Context.Environment <> nil) and Context.Environment.SupportsWebSockets);
end;

function NativeOpen(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Engine: TJsEngine;
  Url: string;
  Protocols: TStringArray;
  List: TJsValue;
  Count, Index: Integer;
  Sink: TNativeSocketSink;
begin
  Context := ContextOfRealm(R);
  try
    Engine := Context.Engine;
    Url := ValueToText(R, ArgumentOf(Args, ArgCount, 0));
    Protocols := nil;
    List := ArgumentOf(Args, ArgCount, 1);
    if JsIsObject(List) then
    begin
      Count := Trunc(Engine.ToNumber(Engine.GetProperty(List, 'length')));
      SetLength(Protocols, Count);
      for Index := 0 to Count - 1 do
        Protocols[Index] := ValueToText(R, Engine.GetProperty(List, IntToStr(Index)));
    end;
    Sink := TNativeSocketSink.Create;
    Sink.Context := Context;
    Inc(NextSocketId);
    Sink.Id := NextSocketId;
    ActiveSockets.Add(Sink);
    Sink.Handle := Context.Environment.OpenWebSocket(Context, Url, Protocols, Sink);
    if Sink.Handle = nil then
    begin
      ActiveSockets.Remove(Sink);
      Sink.Free;
      Exit(JsInteger(-1));
    end;
    Result := JsInteger(Sink.Id);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeSend(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Sink: TNativeSocketSink;
  IsText: Boolean;
  Payload: TJsValue;
  Text: string;
  Bytes: TBytes;
  Data: PByte;
  Length_: SizeInt;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  try
    Sink := FindSocket(Context, Trunc(Context.Engine.ToNumber(ArgumentOf(Args, ArgCount, 0))));
    if Sink = nil then
      Exit;
    IsText := ArgumentOf(Args, ArgCount, 1) = JsTrue;
    Payload := ArgumentOf(Args, ArgCount, 2);
    Bytes := nil;
    if Context.Engine.BufferSourceData(Payload, Data, Length_) then
    begin
      SetLength(Bytes, Length_);
      if Length_ > 0 then
        Move(Data^, Bytes[0], Length_);
    end
    else if IsText then
    begin
      Text := ValueToText(R, Payload);
      SetLength(Bytes, Length(Text));
      if Text <> '' then
        Move(Text[1], Bytes[0], Length(Text));
    end;
    Context.Environment.SendWebSocket(Context, Sink.Handle, IsText, Bytes);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeClose(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Sink: TNativeSocketSink;
  Code: Integer;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  try
    Sink := FindSocket(Context, Trunc(Context.Engine.ToNumber(ArgumentOf(Args, ArgCount, 0))));
    if Sink = nil then
      Exit;
    Code := Trunc(Context.Engine.ToNumber(ArgumentOf(Args, ArgCount, 1)));
    if (Code < 0) or (Code > 65535) then
      Code := 0;
    Context.Environment.CloseWebSocket(Context, Sink.Handle, Code, ValueToText(R, ArgumentOf(Args, ArgCount, 2)));
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeForget(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Sink: TNativeSocketSink;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  Sink := FindSocket(Context, Trunc(Context.Engine.ToNumber(ArgumentOf(Args, ArgCount, 0))));
  if Sink = nil then
    Exit;
  ActiveSockets.Remove(Sink);
  Context.Environment.ForgetWebSocket(Context, Sink.Handle);
  Sink.Free;
end;

{ A context going drops its sockets. }
procedure ContextGoing(Context: TBindingContext);
var
  Index: Integer;
  Sink: TNativeSocketSink;
begin
  for Index := ActiveSockets.Count - 1 downto 0 do
  begin
    Sink := TNativeSocketSink(ActiveSockets[Index]);
    if Sink.Context = Context then
    begin
      ActiveSockets.Delete(Index);
      if Context.Environment <> nil then
        Context.Environment.ForgetWebSocket(Context, Sink.Handle);
      Sink.Free;
    end;
  end;
end;

procedure DefineWebSocketNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'webSocketSupported', @NativeSupported, 0);
  Context.Engine.DefineFunction(Natives, 'webSocketOpen', @NativeOpen, 2);
  Context.Engine.DefineFunction(Natives, 'webSocketSend', @NativeSend, 3);
  Context.Engine.DefineFunction(Natives, 'webSocketClose', @NativeClose, 3);
  Context.Engine.DefineFunction(Natives, 'webSocketForget', @NativeForget, 1);
end;

initialization
  ActiveSockets := TList.Create;
  AddContextGoingHook(@ContextGoing);
finalization
  FreeAndNil(ActiveSockets);
end.

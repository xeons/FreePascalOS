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
  Message links: the two entangled ends a MessagePort pair is made of
  when its ports live in realms of different heaps (a page and a shared
  or service worker, two pages of one process). A message is the
  serialized text of its value (platform/55-serialization.js) and the
  ids of the link ends it transfers; it reaches the context holding the
  other end in a task of that context's loop, in order. Messages sent
  before an end is attached wait for it.

    natives.linkOpen()               [a, b]: a new link's two ends
    natives.linkAttach(id)           this context takes end id (and what
                                     waits there)
    natives.linkPost(id, text, ids)  to the other end of id's link
    natives.linkClose(id)            closes the link (both ends)

  and back: natives.onLinkMessage(id, text, ids), natives.onLinkClosed(id).
  An end whose context goes closes its link.
}
unit Web.Script.MessageLinks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Js.Objects,
  Web.Bindings.Context;

type
  TLinkIds = array of Double;

procedure DefineLinkNatives(Context: TBindingContext; Natives: TJsObject);

{ For the worker units: a new link (its ends' ids), an end given to a
  context, a message sent from native code, a link closed. }
procedure OpenMessageLink(out First, Second: Double);
procedure AttachLinkEnd(Id: Double; Context: TBindingContext);
procedure PostThroughLink(Id: Double; const Text: string; const Ids: TLinkIds);
procedure CloseMessageLink(Id: Double);
{ The context holding an end (nil if none or closed). }
function LinkEndContext(Id: Double): TBindingContext;

implementation

uses
  Js.Values,
  Js.Functions,
  Js.Engine,
  Web.Script.ContextTasks;

type
  TLinkMessage = class
  public
    Text: string;
    Ids: TLinkIds;
  end;

  TLinkEnd = class
  public
    Id: Double;
    PeerId: Double;
    Context: TBindingContext;
    Queue: TList;
    Closed: Boolean;
    CloseTold: Boolean;
    Scheduled: Boolean;
    constructor Create(AId, APeerId: Double);
    destructor Destroy; override;
  end;

  TLinkDelivery = class
  public
    Id: Double;
  end;

var
  Ends: TList;
  NextLinkId: Double = 0;

constructor TLinkEnd.Create(AId, APeerId: Double);
begin
  inherited Create;
  Id := AId;
  PeerId := APeerId;
  Queue := TList.Create;
end;

destructor TLinkEnd.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to Queue.Count - 1 do
    TLinkMessage(Queue[Index]).Free;
  Queue.Free;
  inherited Destroy;
end;

function FindEnd(Id: Double): TLinkEnd;
var
  Index: Integer;
begin
  for Index := 0 to Ends.Count - 1 do
    if TLinkEnd(Ends[Index]).Id = Id then
      Exit(TLinkEnd(Ends[Index]));
  Result := nil;
end;

procedure ForgetEnd(LinkEnd: TLinkEnd);
begin
  Ends.Remove(LinkEnd);
  LinkEnd.Free;
end;

procedure ScheduleDelivery(LinkEnd: TLinkEnd); forward;

procedure DeliverTask(Context: TBindingContext; Data: TObject);
var
  LinkEnd: TLinkEnd;
  Message: TLinkMessage;
  Values: array of TJsValue;
  Index: Integer;
begin
  LinkEnd := FindEnd(TLinkDelivery(Data).Id);
  if (LinkEnd = nil) or (LinkEnd.Context <> Context) then
    Exit;
  LinkEnd.Scheduled := False;
  while (LinkEnd.Queue.Count > 0) and (LinkEnd.Context = Context) do
  begin
    Message := TLinkMessage(LinkEnd.Queue[0]);
    LinkEnd.Queue.Delete(0);
    try
      Values := nil;
      SetLength(Values, Length(Message.Ids));
      for Index := 0 to High(Message.Ids) do
        Values[Index] := JsNumber(Message.Ids[Index]);
      Context.CallPlatform('onLinkMessage', [JsNumber(LinkEnd.Id), Context.TextValue(Message.Text),
        Context.NewArray(Values)]);
    finally
      Message.Free;
    end;
    { The call may have closed or forgotten it. }
    LinkEnd := FindEnd(TLinkDelivery(Data).Id);
    if LinkEnd = nil then
      Exit;
  end;
  if LinkEnd.Closed and not LinkEnd.CloseTold and (LinkEnd.Context = Context) then
  begin
    LinkEnd.CloseTold := True;
    Context.CallPlatform('onLinkClosed', [JsNumber(LinkEnd.Id)]);
    LinkEnd := FindEnd(TLinkDelivery(Data).Id);
    if LinkEnd <> nil then
      ForgetEnd(LinkEnd);
  end;
end;

procedure ScheduleDelivery(LinkEnd: TLinkEnd);
var
  Delivery: TLinkDelivery;
begin
  if LinkEnd.Scheduled or (LinkEnd.Context = nil) then
    Exit;
  Delivery := TLinkDelivery.Create;
  Delivery.Id := LinkEnd.Id;
  LinkEnd.Scheduled := PostToContext(LinkEnd.Context, @DeliverTask, Delivery);
  if not LinkEnd.Scheduled then
    LinkEnd.Context := nil;
end;

procedure OpenMessageLink(out First, Second: Double);
begin
  NextLinkId := NextLinkId + 1;
  First := NextLinkId;
  NextLinkId := NextLinkId + 1;
  Second := NextLinkId;
  Ends.Add(TLinkEnd.Create(First, Second));
  Ends.Add(TLinkEnd.Create(Second, First));
end;

procedure AttachLinkEnd(Id: Double; Context: TBindingContext);
var
  LinkEnd: TLinkEnd;
begin
  LinkEnd := FindEnd(Id);
  if (LinkEnd = nil) or (LinkEnd.Context = Context) then
    Exit;
  KnowContext(Context);
  LinkEnd.Context := Context;
  LinkEnd.Scheduled := False;
  if (LinkEnd.Queue.Count > 0) or LinkEnd.Closed then
    ScheduleDelivery(LinkEnd);
end;

procedure PostThroughLink(Id: Double; const Text: string; const Ids: TLinkIds);
var
  LinkEnd, Peer: TLinkEnd;
  Message: TLinkMessage;
  Index: Integer;
begin
  LinkEnd := FindEnd(Id);
  if (LinkEnd = nil) or LinkEnd.Closed then
  begin
    { Ends sent with a message that cannot go are closed. }
    for Index := 0 to High(Ids) do
      CloseMessageLink(Ids[Index]);
    Exit;
  end;
  Peer := FindEnd(LinkEnd.PeerId);
  if (Peer = nil) or Peer.Closed then
    Exit;
  Message := TLinkMessage.Create;
  Message.Text := Text;
  Message.Ids := Copy(Ids);
  Peer.Queue.Add(Message);
  ScheduleDelivery(Peer);
end;

procedure CloseEnd(LinkEnd: TLinkEnd);
begin
  if LinkEnd.Closed then
    Exit;
  LinkEnd.Closed := True;
  if LinkEnd.Context <> nil then
    ScheduleDelivery(LinkEnd)
  else if LinkEnd.Queue.Count = 0 then
    ForgetEnd(LinkEnd);
end;

procedure CloseMessageLink(Id: Double);
var
  LinkEnd, Peer: TLinkEnd;
begin
  LinkEnd := FindEnd(Id);
  if LinkEnd = nil then
    Exit;
  Peer := FindEnd(LinkEnd.PeerId);
  { The end that closed is not told: its port did it. }
  LinkEnd.CloseTold := True;
  CloseEnd(LinkEnd);
  if Peer <> nil then
    CloseEnd(Peer);
end;

function LinkEndContext(Id: Double): TBindingContext;
var
  LinkEnd: TLinkEnd;
begin
  LinkEnd := FindEnd(Id);
  if (LinkEnd = nil) or LinkEnd.Closed then
    Exit(nil);
  Result := LinkEnd.Context;
end;

procedure ContextEnded(Context: TBindingContext);
var
  Index: Integer;
  Closing: array of Double;
begin
  Closing := nil;
  for Index := 0 to Ends.Count - 1 do
    if TLinkEnd(Ends[Index]).Context = Context then
    begin
      TLinkEnd(Ends[Index]).Context := nil;
      SetLength(Closing, Length(Closing) + 1);
      Closing[High(Closing)] := TLinkEnd(Ends[Index]).Id;
    end;
  for Index := 0 to High(Closing) do
    CloseMessageLink(Closing[Index]);
end;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function NumberArg(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  Result := Context.Engine.ToNumber(Arg(Args, Count, Index));
end;

function NativeLinkOpen(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  First, Second: Double;
begin
  Context := ContextOfRealm(R);
  OpenMessageLink(First, Second);
  Result := Context.NewArray([JsNumber(First), JsNumber(Second)]);
end;

function NativeLinkAttach(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  AttachLinkEnd(NumberArg(Context, Args, ArgCount, 0), Context);
  Result := JsUndefined;
end;

function NativeLinkPost(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  List: TJsValue;
  Ids: TLinkIds;
  Count, Index: Integer;
begin
  Context := ContextOfRealm(R);
  Ids := nil;
  List := Arg(Args, ArgCount, 2);
  if JsIsObject(List) then
  begin
    Count := Trunc(Context.Engine.ToNumber(Context.Engine.GetProperty(List, 'length')));
    SetLength(Ids, Count);
    for Index := 0 to Count - 1 do
      Ids[Index] := Context.Engine.ToNumber(Context.Engine.GetProperty(List, IntToStr(Index)));
  end;
  PostThroughLink(NumberArg(Context, Args, ArgCount, 0), Context.Engine.ToText(Arg(Args, ArgCount, 1)), Ids);
  Result := JsUndefined;
end;

function NativeLinkClose(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  CloseMessageLink(NumberArg(Context, Args, ArgCount, 0));
  Result := JsUndefined;
end;

procedure DefineLinkNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'linkOpen', @NativeLinkOpen, 0);
  Context.Engine.DefineFunction(Natives, 'linkAttach', @NativeLinkAttach, 1);
  Context.Engine.DefineFunction(Natives, 'linkPost', @NativeLinkPost, 3);
  Context.Engine.DefineFunction(Natives, 'linkClose', @NativeLinkClose, 1);
end;

initialization
  Ends := TList.Create;
  AddContextEndHook(@ContextEnded);
finalization
  while Ends.Count > 0 do
    ForgetEnd(TLinkEnd(Ends[0]));
  FreeAndNil(Ends);
end.

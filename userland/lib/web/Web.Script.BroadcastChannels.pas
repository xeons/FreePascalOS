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
  The process's BroadcastChannel hub (HTML Standard 9.6): channels by
  origin and name across every window and worker of the process (a
  worker's channels are its host window's, whose origin it shares). A
  message is its serialized text; each other channel of the name and
  origin gets it in a task of its own context's loop, in the order the
  channels joined (as the standard sorts them by creation).

    natives.broadcastJoin(name)         a new channel's id
    natives.broadcastPost(id, text)     to the others of its name
    natives.broadcastLeave(id)          close()

  and back: natives.onBroadcast(id, text, origin). A context's channels
  leave when it goes.
}
unit Web.Script.BroadcastChannels;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineBroadcastNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Web.Script.ContextTasks;

type
  TBroadcastMember = class
  public
    Id: Double;
    Context: TBindingContext;
    Origin: string;
    Name: string;
  end;

  TBroadcastDelivery = class
  public
    Id: Double;
    Text: string;
    Origin: string;
  end;

var
  Members: TList;
  NextMemberId: Double = 0;

function FindMember(Id: Double): TBroadcastMember;
var
  Index: Integer;
begin
  for Index := 0 to Members.Count - 1 do
    if TBroadcastMember(Members[Index]).Id = Id then
      Exit(TBroadcastMember(Members[Index]));
  Result := nil;
end;

procedure DeliverTask(Context: TBindingContext; Data: TObject);
var
  Delivery: TBroadcastDelivery;
begin
  Delivery := TBroadcastDelivery(Data);
  if FindMember(Delivery.Id) = nil then
    Exit;
  Context.CallPlatform('onBroadcast', [JsNumber(Delivery.Id), Context.TextValue(Delivery.Text),
    Context.TextValue(Delivery.Origin)]);
end;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function NativeBroadcastJoin(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Member: TBroadcastMember;
begin
  Context := ContextOfRealm(R);
  Member := TBroadcastMember.Create;
  NextMemberId := NextMemberId + 1;
  Member.Id := NextMemberId;
  Member.Context := Context;
  Member.Origin := ContextOriginText(Context);
  Member.Name := Context.Engine.ToText(Arg(Args, ArgCount, 0));
  Members.Add(Member);
  Result := JsNumber(Member.Id);
end;

function NativeBroadcastPost(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Sender, Receiver: TBroadcastMember;
  Delivery: TBroadcastDelivery;
  Text: string;
  Index: Integer;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  Sender := FindMember(Context.Engine.ToNumber(Arg(Args, ArgCount, 0)));
  if (Sender = nil) or (Sender.Context <> Context) then
    Exit;
  Text := Context.Engine.ToText(Arg(Args, ArgCount, 1));
  for Index := 0 to Members.Count - 1 do
  begin
    Receiver := TBroadcastMember(Members[Index]);
    { An opaque origin is only ever its own (its channels hear nothing
      of others). }
    if (Receiver = Sender) or (Receiver.Name <> Sender.Name) or (Receiver.Origin <> Sender.Origin) or
       (Sender.Origin = 'null') and (Receiver.Context <> Sender.Context) then
      Continue;
    Delivery := TBroadcastDelivery.Create;
    Delivery.Id := Receiver.Id;
    Delivery.Text := Text;
    Delivery.Origin := Sender.Origin;
    PostToContext(Receiver.Context, @DeliverTask, Delivery);
  end;
end;

procedure RemoveMember(Member: TBroadcastMember);
begin
  Members.Remove(Member);
  Member.Free;
end;

function NativeBroadcastLeave(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Member: TBroadcastMember;
begin
  Context := ContextOfRealm(R);
  Member := FindMember(Context.Engine.ToNumber(Arg(Args, ArgCount, 0)));
  if (Member <> nil) and (Member.Context = Context) then
    RemoveMember(Member);
  Result := JsUndefined;
end;

procedure ContextEnded(Context: TBindingContext);
var
  Index: Integer;
begin
  for Index := Members.Count - 1 downto 0 do
    if TBroadcastMember(Members[Index]).Context = Context then
      RemoveMember(TBroadcastMember(Members[Index]));
end;

procedure DefineBroadcastNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'broadcastJoin', @NativeBroadcastJoin, 1);
  Context.Engine.DefineFunction(Natives, 'broadcastPost', @NativeBroadcastPost, 2);
  Context.Engine.DefineFunction(Natives, 'broadcastLeave', @NativeBroadcastLeave, 1);
end;

initialization
  Members := TList.Create;
  AddContextEndHook(@ContextEnded);
finalization
  while Members.Count > 0 do
    RemoveMember(TBroadcastMember(Members[0]));
  FreeAndNil(Members);
end.

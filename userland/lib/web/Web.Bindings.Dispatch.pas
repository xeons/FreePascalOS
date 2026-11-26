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
  The native functions every binding goes through. Each function object
  made for a member carries the member (HostData) and the interface
  that declares it (Magic): the entry checks this (the brand: a wrapper
  of that interface or a descendant, or the global object for the
  window), picks the overload, converts the arguments, calls the
  implementation routine and turns a Pascal exception into a JavaScript
  one. Attributes add [SameObject] caching, [PutForwards], [Replaceable],
  reflection and event handlers.
}
unit Web.Bindings.Dispatch;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Web.Dom.Events,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Context,
  Web.Bindings.Tables,
  Web.Bindings.Conversions;

function OperationEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
function GetterEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
function SetterEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
function ConstructorEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
function StringifierEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
{ entries, keys, values, forEach of pair iterable interfaces (Magic is
  the interface, HostData the kind 0..3). }
function PairIterationEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;

{ Calls a special operation's routine (exotic objects): the member with
  Arguments already set. }
function CallSpecial(Context: TBindingContext; Handler: TBindingHandler; Wrapper: TBindingWrapper;
  InterfaceId: Integer; const Arguments: TBindingValueArray; out Value: TJsValue): Boolean;

implementation

uses
  Web.Bindings.Reflection,
  Web.Bindings.EventHandlers,
  Web.Bindings.CustomElementRegistry;

procedure StartCall(out Call: TBindingCall; Context: TBindingContext; R: TJsRealm; const This: TJsValue;
  Args: PJsValueArray; ArgCount: Integer; Member: PBindingMember; InterfaceId: Integer);
begin
  Call.Realm := R;
  Call.Context := Context;
  Call.This := This;
  Call.Wrapper := Context.WrapperOf(This);
  Call.Target := nil;
  Call.Member := Member;
  Call.InterfaceId := InterfaceId;
  Call.Overload := -1;
  Call.PassedCount := ArgCount;
  Call.RawArguments := Args;
  Call.Arguments := nil;
  Call.NewTarget := JsUndefined;
end;

function CheckThis(Context: TBindingContext; var Call: TBindingCall): Boolean;
begin
  Call.Target := Context.Unwrap(Call.This, Call.InterfaceId);
  Result := Call.Target <> nil;
end;

function MemberName(Member: PBindingMember; InterfaceId: Integer): string;
begin
  Result := string(BindingInterfaces[InterfaceId].Name) + '.' + string(Member^.Name);
end;

function IllegalInvocation(R: TJsRealm): TJsValue;
begin
  Result := R.ThrowTypeError('Illegal invocation');
end;

function OperationEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Member: PBindingMember;
  Call: TBindingCall;
  Reactions: Boolean;
begin
  Context := ContextOfRealm(R);
  Member := PBindingMember(Callee.HostData);
  StartCall(Call, Context, R, This, Args, ArgCount, Member, Callee.Magic);
  if ((Member^.Flags and MemberStatic) = 0) and not CheckThis(Context, Call) then
    Exit(IllegalInvocation(R));
  { [CEReactions]: custom element reactions run as the method returns
    (define() itself makes the first definition). }
  Reactions := CustomElementHost <> nil;
  if Reactions then
    EnterReactionsScope;
  try
    try
      ConvertArguments(Context, Call, Member^.FirstOverload, Member^.OverloadCount, MemberName(Member, Callee.Magic));
      Result := Member^.Getter(Call);
    except
      on Error: Exception do
        Result := Context.ThrowFromException(Error);
    end;
  finally
    if Reactions then
      LeaveReactionsScope(Context);
  end;
end;

function GetAttribute(Context: TBindingContext; var Call: TBindingCall): TJsValue;
var
  Member: PBindingMember;
  Wrapper: TBindingWrapper;
  Range: TBindingRange;
begin
  Member := Call.Member;
  Wrapper := TBindingWrapper(Call.Wrapper);
  if (Member^.CacheSlot >= 0) and (Wrapper <> nil) then
  begin
    Result := Wrapper.CachedValue(Member^.CacheSlot);
    if Result <> JsUndefined then
      Exit;
  end;
  case Member^.Kind of
    mkReflected:
      if Member^.ReflectKind = rkEnum then
      begin
        Range := BindingReflectEnums[Member^.EnumIndex];
        Result := GetReflected(Context, TElement(Call.Target), Member, @BindingReflectEnumKeywords[Range.First],
          Range.Count);
      end
      else
        Result := GetReflected(Context, TElement(Call.Target), Member, nil, 0);
    mkEventHandler:
      Result := GetEventHandler(Context, TEventTarget(Call.Target), Copy(string(Member^.Name), 3, MaxInt));
  else
    Result := Member^.Getter(Call);
  end;
  if (Member^.CacheSlot >= 0) and (Wrapper <> nil) and (Result <> JsException) then
    Wrapper.SetCachedValue(Member^.CacheSlot, Result);
end;

function GetterEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Call: TBindingCall;
begin
  Context := ContextOfRealm(R);
  StartCall(Call, Context, R, This, nil, 0, PBindingMember(Callee.HostData), Callee.Magic);
  if ((Call.Member^.Flags and MemberStatic) = 0) and not CheckThis(Context, Call) then
    Exit(IllegalInvocation(R));
  try
    Result := GetAttribute(Context, Call);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

{ Whether Value converts to one of the enumeration's values (False for
  a symbol, which conversion would reject anyway). }
function EnumValueValid(Context: TBindingContext; Value: TJsValue; TypeIndex: Integer): Boolean;
var
  Text: string;
  Range: TBindingRange;
  Index: Integer;
begin
  if JsIsSymbol(Value) then
    Exit(True);
  Text := ValueToText(Context.Engine.Realm, Value);
  if Context.Engine.Realm.HasException then
    raise EBindingPendingException.Create('');
  Range := BindingEnums[BindingTypes[TypeIndex].Reference];
  for Index := 0 to Range.Count - 1 do
    if BindingEnumValues[Range.First + Index] = Text then
      Exit(True);
  Result := False;
end;

{ An attribute setter's work (PutForwards, event handlers, reflection,
  the routine). }
function AssignAttribute(Context: TBindingContext; var Call: TBindingCall; Member: PBindingMember;
  Value: TJsValue; InterfaceId: Integer): TJsValue;
var
  R: TJsRealm;
  Forward: TJsValue;
begin
  R := Call.Realm;
  try
    if (Member^.Flags and MemberPutForwards) <> 0 then
    begin
      Forward := GetAttribute(Context, Call);
      if Forward = JsException then
        Exit(JsException);
      if not JsIsObject(Forward) then
        Exit(R.ThrowTypeError('cannot forward the assignment'));
      if not SetProperty(R, Forward, R.Intern(string(Member^.Text)), Value, True) then
        Exit(JsException);
      Exit(JsUndefined);
    end;
    if Member^.Kind = mkEventHandler then
    begin
      SetEventHandler(Context, TEventTarget(Call.Target), Copy(string(Member^.Name), 3, MaxInt), Value);
      Exit(JsUndefined);
    end;
    SetLength(Call.Arguments, 1);
    { WebIDL 3.7.6: an attribute of an enumeration type ignores a string
      that is not one of its values. }
    if (BindingTypes[Member^.TypeIndex].Kind = tkEnum) and not EnumValueValid(Context, Value, Member^.TypeIndex) then
      Exit(JsUndefined);
    ConvertValue(Context, Value, Member^.TypeIndex, Call.Arguments[0], MemberName(Member, InterfaceId));
    if Member^.Kind = mkReflected then
    begin
      SetReflected(Context, TElement(Call.Target), Member, Call.Arguments[0]);
      Exit(JsUndefined);
    end;
    Member^.Setter(Call);
    Result := JsUndefined;
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function SetterEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Call: TBindingCall;
  Member: PBindingMember;
  Value: TJsValue;
  Reactions: Boolean;
begin
  Context := ContextOfRealm(R);
  Member := PBindingMember(Callee.HostData);
  StartCall(Call, Context, R, This, Args, ArgCount, Member, Callee.Magic);
  Value := Arg(Args, ArgCount, 0);
  if (Member^.Flags and MemberReplaceable) <> 0 then
  begin
    if not JsIsObject(This) then
      Exit(IllegalInvocation(R));
    if not JsAsObject(This).CreateDataProperty(R, R.Intern(string(Member^.Name)), Value) and R.HasException then
      Exit(JsException);
    Exit(JsUndefined);
  end;
  if ((Member^.Flags and MemberStatic) = 0) and not CheckThis(Context, Call) then
    Exit(IllegalInvocation(R));
  Reactions := CustomElementHost <> nil;
  if Reactions then
    EnterReactionsScope;
  try
    Result := AssignAttribute(Context, Call, Member, Value, Callee.Magic);
  finally
    if Reactions then
      LeaveReactionsScope(Context);
  end;
end;

function ConstructorEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Call: TBindingCall;
  Info: PBindingInterface;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor requires ''new'''));
  Context := ContextOfRealm(R);
  Info := @BindingInterfaces[Callee.Magic];
  StartCall(Call, Context, R, This, Args, ArgCount, nil, Callee.Magic);
  Call.NewTarget := NewTarget;
  try
    ConvertArguments(Context, Call, Info^.FirstConstructorOverload, Info^.ConstructorOverloadCount,
      string(Info^.Name) + ' constructor');
    Result := Info^.Construct(Call);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function StringifierEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Call: TBindingCall;
begin
  Context := ContextOfRealm(R);
  StartCall(Call, Context, R, This, nil, 0, PBindingMember(Callee.HostData), Callee.Magic);
  if not CheckThis(Context, Call) then
    Exit(IllegalInvocation(R));
  try
    Result := Call.Member^.Getter(Call);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function CallSpecial(Context: TBindingContext; Handler: TBindingHandler; Wrapper: TBindingWrapper;
  InterfaceId: Integer; const Arguments: TBindingValueArray; out Value: TJsValue): Boolean;
var
  Call: TBindingCall;
begin
  StartCall(Call, Context, Context.Engine.Realm, JsObjectValue(Wrapper), nil, 0, nil, InterfaceId);
  Call.Target := TObject(Wrapper.NativeData);
  Call.Arguments := Arguments;
  Call.PassedCount := Length(Arguments);
  try
    Value := Handler(Call);
    Result := Value <> JsException;
  except
    on Error: Exception do
    begin
      Value := Context.ThrowFromException(Error);
      Result := False;
    end;
  end;
end;

const
  PairEntries = 0;
  PairKeys = 1;
  PairValues = 2;
  PairForEach = 3;

{ The pair at Index of the object Target (an array [name, value]), or
  not an object past the end; False when the getter threw. }
function PairOf(Context: TBindingContext; Target: TJsValue; InterfaceId, Index: Integer; out Pair: TJsValue): Boolean;
var
  Arguments: TBindingValueArray;
begin
  SetLength(Arguments, 1);
  Arguments[0].Kind := bvNumber;
  Arguments[0].Number := Index;
  Result := CallSpecial(Context, BindingInterfaces[InterfaceId].PairAt, Context.WrapperOf(Target), InterfaceId,
    Arguments, Pair);
end;

{ next() of a pair iterator: the pairs are read live, one index at a time
  (a pair deleted during the walk moves the rest up, as the iterable
  declaration's value pairs do). Callee.Data is [target, next index],
  the target undefined once done; Callee.HostData the kind. }
function PairIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  State: TJsObject;
  Target, Pair, Value: TJsValue;
  Index, Mark: Integer;
begin
  Context := ContextOfRealm(R);
  State := JsAsObject(Callee.Data);
  Target := State.GetValue(R, JsInteger(0));
  if not JsIsObject(Target) then
    Exit(CreateIterResult(R, JsUndefined, True));
  Index := Round(Context.Engine.ToNumber(State.GetValue(R, JsInteger(1))));
  if not PairOf(Context, Target, Callee.Magic, Index, Pair) then
    Exit(JsException);
  if not JsIsObject(Pair) then
  begin
    State.Put(R, JsInteger(0), JsUndefined);
    Exit(CreateIterResult(R, JsUndefined, True));
  end;
  Mark := Context.Engine.Runtime.PushRoot(Pair);
  try
    State.Put(R, JsInteger(1), JsInteger(Index + 1));
    case PtrInt(Callee.HostData) of
      PairKeys: Value := JsAsObject(Pair).GetValue(R, JsInteger(0));
      PairValues: Value := JsAsObject(Pair).GetValue(R, JsInteger(1));
    else
      Value := Pair;
    end;
    Result := CreateIterResult(R, Value, False);
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

function PairIterationEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Index, Mark: Integer;
  Pair, Key, Item, Callback, Ignored: TJsValue;
  Iterator: TJsObject;
  Next: TJsNativeFunction;
  CallArgs: array[0..2] of TJsValue;
  Kind: PtrInt;
begin
  Context := ContextOfRealm(R);
  if Context.Unwrap(This, Callee.Magic) = nil then
    Exit(IllegalInvocation(R));
  Kind := PtrInt(Callee.HostData);
  if Kind <> PairForEach then
  begin
    Iterator := R.NewObject(R.Intrinsics[inIteratorPrototype]);
    Mark := Context.Engine.Runtime.PushRoot(JsObjectValue(Iterator));
    try
      Next := Context.Engine.DefineFunction(Iterator, 'next', @PairIteratorNext, 0, Callee.Magic);
      Next.HostData := Pointer(Kind);
      Next.Data := Context.Engine.NewArray([This, JsInteger(0)]);
      Result := JsObjectValue(Iterator);
    finally
      Context.Engine.Runtime.PopRoots(Mark);
    end;
    Exit;
  end;
  Callback := Arg(Args, ArgCount, 0);
  if not JsIsCallable(Callback) then
    Exit(R.ThrowTypeError('forEach needs a function'));
  Mark := Context.Engine.Runtime.PushRoot(JsUndefined);
  try
    Index := 0;
    while True do
    begin
      if not PairOf(Context, This, Callee.Magic, Index, Pair) then
        Exit(JsException);
      if not JsIsObject(Pair) then
        Break;
      Context.Engine.Runtime.PushRoot(Pair);
      Key := JsAsObject(Pair).GetValue(R, JsInteger(0));
      Item := JsAsObject(Pair).GetValue(R, JsInteger(1));
      CallArgs[0] := Item;
      CallArgs[1] := Key;
      CallArgs[2] := This;
      Ignored := R.Call(Callback, Arg(Args, ArgCount, 1), @CallArgs[0], 3);
      if Ignored = JsException then
        Exit(JsException);
      Inc(Index);
    end;
    Result := JsUndefined;
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

end.

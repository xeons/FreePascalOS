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
  Reflect, and Proxy objects.

  A proxy forwards each internal method to its handler's trap, or to
  its target when the handler has none. The invariants the
  specification checks on trap results are checked for the
  non-configurable and non-extensible cases of get, set, has,
  getOwnPropertyDescriptor and deleteProperty; ownKeys results are
  taken as they are.
}
unit Js.Builtins.Reflect;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter,
  Js.Builtins.Objects;

type
  TJsProxy = class(TJsObject)
  private
    function Trap(R: TJsRealm; const Name: string; out Method: TJsValue): Boolean;
    function Revoked(R: TJsRealm): Boolean;
  public
    Target: TJsObject;
    Handler: TJsObject;
    procedure Trace(Tracer: TJsTracer); override;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
    function GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean; override;
    function SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer; override;
    function PreventExtensions(R: TJsRealm): Integer; override;
    function IsExtensible(R: TJsRealm): Integer; override;
    function CallAsFunction(R: TJsRealm; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue; override;
    function ConstructAsFunction(R: TJsRealm; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue; override;
  end;

procedure InstallReflect(R: TJsInterpreterRealm);

implementation

function KeyValue(R: TJsRealm; Key: TJsValue): TJsValue;
begin
  Result := KeyToStringValue(R, Key);
end;

procedure TJsProxy.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Target);
  Tracer.MarkCell(Handler);
end;

function TJsProxy.Revoked(R: TJsRealm): Boolean;
begin
  Result := Handler = nil;
  if Result then
    R.ThrowTypeError('Cannot perform operation on a revoked proxy');
end;

function TJsProxy.Trap(R: TJsRealm; const Name: string; out Method: TJsValue): Boolean;
begin
  Method := JsUndefined;
  if Revoked(R) then
    Exit(False);
  Method := GetMethod(R, JsObjectValue(Handler), R.Intern(Name));
  Result := Method <> JsException;
end;

function TJsProxy.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..1] of TJsValue;
  TargetDesc: TJsPropertyDescriptor;
  Found: Integer;
begin
  if not Trap(R, 'getOwnPropertyDescriptor', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.GetOwnProperty(R, Key, Desc));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 2);
  if Outcome = JsException then
    Exit(-1);
  Found := Target.GetOwnProperty(R, Key, TargetDesc);
  if Found < 0 then
    Exit(-1);
  if Outcome = JsUndefined then
  begin
    if (Found > 0) and ((TargetDesc.Flags and PropertyConfigurable) = 0) then
    begin
      R.ThrowTypeError('getOwnPropertyDescriptor trap returned undefined for a non-configurable property');
      Exit(-1);
    end;
    Exit(0);
  end;
  if not JsIsObject(Outcome) then
  begin
    R.ThrowTypeError('getOwnPropertyDescriptor trap returned neither object nor undefined');
    Exit(-1);
  end;
  if not ToPropertyDescriptor(R, Outcome, Desc) then
    Exit(-1);
  if (Desc.Present and HasEnumerable) = 0 then
    Desc.Flags := Desc.Flags and not PropertyEnumerable;
  Result := 1;
end;

function TJsProxy.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..2] of TJsValue;
begin
  if not Trap(R, 'defineProperty', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.DefineOwnProperty(R, Key, Desc, ThrowOnFailure));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Args[2] := FromPropertyDescriptor(R, Desc);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 3);
  if Outcome = JsException then
    Exit(-1);
  if ToBoolean(Outcome) then
    Exit(1);
  if ThrowOnFailure then
  begin
    R.ThrowTypeError('defineProperty trap returned falsish for property ''' + KeyToPascal(R, Key) + '''');
    Exit(-1);
  end;
  Result := 0;
end;

function TJsProxy.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..1] of TJsValue;
  TargetDesc: TJsPropertyDescriptor;
begin
  if not Trap(R, 'has', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.HasProperty(R, Key));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 2);
  if Outcome = JsException then
    Exit(-1);
  if ToBoolean(Outcome) then
    Exit(1);
  if (Target.GetOwnProperty(R, Key, TargetDesc) > 0) and ((TargetDesc.Flags and PropertyConfigurable) = 0) then
  begin
    R.ThrowTypeError('has trap returned falsish for a non-configurable property ''' + KeyToPascal(R, Key) + '''');
    Exit(-1);
  end;
  Result := 0;
end;

function TJsProxy.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Method: TJsValue;
  Args: array[0..2] of TJsValue;
  TargetDesc: TJsPropertyDescriptor;
begin
  if not Trap(R, 'get', Method) then
    Exit(JsException);
  if Method = JsUndefined then
    Exit(Target.Get(R, Key, Receiver));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Args[2] := Receiver;
  Result := R.Call(Method, JsObjectValue(Handler), @Args[0], 3);
  if Result = JsException then
    Exit;
  if (Target.GetOwnProperty(R, Key, TargetDesc) > 0) and ((TargetDesc.Flags and PropertyConfigurable) = 0) and
    not DescriptorIsAccessor(TargetDesc) and ((TargetDesc.Flags and PropertyWritable) = 0) and
    not SameValue(Result, TargetDesc.Value, R.Heap) then
    Exit(R.ThrowTypeError('get trap result differs from the non-writable, non-configurable property ''' +
      KeyToPascal(R, Key) + ''''));
end;

function TJsProxy.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..3] of TJsValue;
begin
  if not Trap(R, 'set', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.SetValue(R, Key, Value, Receiver));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Args[2] := Value;
  Args[3] := Receiver;
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 4);
  if Outcome = JsException then
    Exit(-1);
  Result := Ord(ToBoolean(Outcome));
end;

function TJsProxy.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..1] of TJsValue;
  TargetDesc: TJsPropertyDescriptor;
begin
  if not Trap(R, 'deleteProperty', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.DeleteProperty(R, Key));
  Args[0] := JsObjectValue(Target);
  Args[1] := KeyValue(R, Key);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 2);
  if Outcome = JsException then
    Exit(-1);
  if not ToBoolean(Outcome) then
    Exit(0);
  if (Target.GetOwnProperty(R, Key, TargetDesc) > 0) and ((TargetDesc.Flags and PropertyConfigurable) = 0) then
  begin
    R.ThrowTypeError('deleteProperty trap returned truish for a non-configurable property ''' +
      KeyToPascal(R, Key) + '''');
    Exit(-1);
  end;
  Result := 1;
end;

function TJsProxy.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Method, Outcome, Key: TJsValue;
  Argument: TJsValue;
  List: TJsValueList;
  Index, Count: Integer;
begin
  Keys := nil;
  if not Trap(R, 'ownKeys', Method) then
    Exit(False);
  if Method = JsUndefined then
    Exit(Target.OwnPropertyKeys(R, Filter, Keys));
  Argument := JsObjectValue(Target);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Argument, 1);
  if Outcome = JsException then
    Exit(False);
  if not CreateListFromArrayLike(R, Outcome, List) then
    Exit(False);
  SetLength(Keys, Length(List));
  Count := 0;
  for Index := 0 to High(List) do
  begin
    if not JsIsString(List[Index]) and not JsIsSymbol(List[Index]) then
    begin
      R.ThrowTypeError(ValueToPascal(R, List[Index]) + ' is not a valid property name');
      Exit(False);
    end;
    Key := ToPropertyKey(R, List[Index]);
    if JsIsSymbol(Key) and ((Filter and KeysSymbols) = 0) then
      Continue;
    if not JsIsSymbol(Key) and ((Filter and KeysStrings) = 0) then
      Continue;
    Keys[Count] := Key;
    Inc(Count);
  end;
  SetLength(Keys, Count);
  Result := True;
end;

function TJsProxy.GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean;
var
  Method, Outcome, Argument: TJsValue;
begin
  Prototype := nil;
  if not Trap(R, 'getPrototypeOf', Method) then
    Exit(False);
  if Method = JsUndefined then
    Exit(Target.GetPrototype(R, Prototype));
  Argument := JsObjectValue(Target);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Argument, 1);
  if Outcome = JsException then
    Exit(False);
  if Outcome = JsNull then
    Exit(True);
  if not JsIsObject(Outcome) then
  begin
    R.ThrowTypeError('getPrototypeOf trap returned neither object nor null');
    Exit(False);
  end;
  Prototype := JsAsObject(Outcome);
  Result := True;
end;

function TJsProxy.SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer;
var
  Method, Outcome: TJsValue;
  Args: array[0..1] of TJsValue;
begin
  if not Trap(R, 'setPrototypeOf', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.SetPrototype(R, Prototype));
  Args[0] := JsObjectValue(Target);
  if Prototype = nil then
    Args[1] := JsNull
  else
    Args[1] := JsObjectValue(Prototype);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Args[0], 2);
  if Outcome = JsException then
    Exit(-1);
  Result := Ord(ToBoolean(Outcome));
end;

function TJsProxy.PreventExtensions(R: TJsRealm): Integer;
var
  Method, Outcome, Argument: TJsValue;
begin
  if not Trap(R, 'preventExtensions', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.PreventExtensions(R));
  Argument := JsObjectValue(Target);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Argument, 1);
  if Outcome = JsException then
    Exit(-1);
  Result := Ord(ToBoolean(Outcome));
end;

function TJsProxy.IsExtensible(R: TJsRealm): Integer;
var
  Method, Outcome, Argument: TJsValue;
begin
  if not Trap(R, 'isExtensible', Method) then
    Exit(-1);
  if Method = JsUndefined then
    Exit(Target.IsExtensible(R));
  Argument := JsObjectValue(Target);
  Outcome := R.Call(Method, JsObjectValue(Handler), @Argument, 1);
  if Outcome = JsException then
    Exit(-1);
  Result := Ord(ToBoolean(Outcome));
end;

function TJsProxy.CallAsFunction(R: TJsRealm; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
var
  Method: TJsValue;
  Triple: array[0..2] of TJsValue;
begin
  if not Trap(R, 'apply', Method) then
    Exit(JsException);
  if Method = JsUndefined then
    Exit(R.Call(JsObjectValue(Target), This, Args, Count));
  Triple[0] := JsObjectValue(Target);
  Triple[1] := This;
  Triple[2] := JsObjectValue(R.NewArrayFrom(Args, Count));
  Result := R.Call(Method, JsObjectValue(Handler), @Triple[0], 3);
end;

function TJsProxy.ConstructAsFunction(R: TJsRealm; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue;
var
  Method: TJsValue;
  Triple: array[0..2] of TJsValue;
begin
  if not Trap(R, 'construct', Method) then
    Exit(JsException);
  if Method = JsUndefined then
    Exit(R.Construct(JsObjectValue(Target), Args, Count, NewTarget));
  Triple[0] := JsObjectValue(Target);
  Triple[1] := JsObjectValue(R.NewArrayFrom(Args, Count));
  Triple[2] := NewTarget;
  Result := R.Call(Method, JsObjectValue(Handler), @Triple[0], 3);
  if (Result <> JsException) and not JsIsObject(Result) then
    Result := R.ThrowTypeError('proxy [[Construct]] must return an object');
end;

function MakeProxy(R: TJsRealm; Target, Handler: TJsValue): TJsValue;
var
  Proxy: TJsProxy;
begin
  if not JsIsObject(Target) or not JsIsObject(Handler) then
    Exit(R.ThrowTypeError('Cannot create proxy with a non-object as target or handler'));
  Proxy := TJsProxy(R.NewObjectOfClass(TJsProxy, nil, ocProxy));
  Proxy.Target := JsAsObject(Target);
  Proxy.Handler := JsAsObject(Handler);
  Proxy.ObjectFlags := ObjectExtensible or ObjectExotic or
    (JsAsObject(Target).ObjectFlags and (ObjectCallable or ObjectConstructor));
  Result := JsObjectValue(Proxy);
end;

function ProxyConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor Proxy requires ''new'''));
  Result := MakeProxy(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
end;

function ProxyRevoke(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if JsIsObject(Callee.Data) then
  begin
    TJsProxy(JsAsObject(Callee.Data)).Handler := nil;
    TJsProxy(JsAsObject(Callee.Data)).Target := nil;
    Callee.Data := JsUndefined;
  end;
  Result := JsUndefined;
end;

function ProxyRevocable(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Proxy: TJsValue;
  Outcome: TJsObject;
  Revoke: TJsNativeFunction;
begin
  Proxy := MakeProxy(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
  if Proxy = JsException then
    Exit(JsException);
  Revoke := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @ProxyRevoke, 0);
  Revoke.Data := Proxy;
  Outcome := R.NewPlainObject;
  Outcome.CreateDataProperty(R, R.Intern('proxy'), Proxy);
  Outcome.CreateDataProperty(R, R.Intern('revoke'), JsObjectValue(Revoke));
  Result := JsObjectValue(Outcome);
end;

{ Reflect }

function RequireTarget(R: TJsRealm; Value: TJsValue; out Target: TJsObject): Boolean;
begin
  Target := nil;
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError('Reflect method called on non-object');
    Exit(False);
  end;
  Target := JsAsObject(Value);
  Result := True;
end;

const
  ReflectApply = 0; ReflectConstruct = 1; ReflectDefineProperty = 2; ReflectDeleteProperty = 3;
  ReflectGet = 4; ReflectGetOwnPropertyDescriptor = 5; ReflectGetPrototypeOf = 6; ReflectHas = 7;
  ReflectIsExtensible = 8; ReflectOwnKeys = 9; ReflectPreventExtensions = 10; ReflectSet = 11;
  ReflectSetPrototypeOf = 12;

function ReflectMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Key, Receiver, NewTargetValue: TJsValue;
  List, Keys: TJsValueList;
  Desc: TJsPropertyDescriptor;
  Found, Index: Integer;
  Prototype: TJsObject;
  Created: TJsArray;
begin
  case Callee.Magic of
    ReflectApply:
      begin
        if not JsIsCallable(Arg(Args, ArgCount, 0)) then
          Exit(R.ThrowTypeError('Reflect.apply target is not callable'));
        if not CreateListFromArrayLike(R, Arg(Args, ArgCount, 2), List) then
          Exit(JsException);
        Exit(R.Call(Args^[0], Arg(Args, ArgCount, 1), @List[0], Length(List)));
      end;
    ReflectConstruct:
      begin
        if not JsIsConstructor(Arg(Args, ArgCount, 0)) then
          Exit(R.ThrowTypeError('Reflect.construct target is not a constructor'));
        NewTargetValue := Args^[0];
        if ArgCount > 2 then
        begin
          NewTargetValue := Args^[2];
          if not JsIsConstructor(NewTargetValue) then
            Exit(R.ThrowTypeError('Reflect.construct newTarget is not a constructor'));
        end;
        if not CreateListFromArrayLike(R, Arg(Args, ArgCount, 1), List) then
          Exit(JsException);
        Exit(R.Construct(Args^[0], @List[0], Length(List), NewTargetValue));
      end;
  end;
  if not RequireTarget(R, Arg(Args, ArgCount, 0), Target) then
    Exit(JsException);
  case Callee.Magic of
    ReflectDefineProperty:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        if not ToPropertyDescriptor(R, Arg(Args, ArgCount, 2), Desc) then
          Exit(JsException);
        Found := Target.DefineOwnProperty(R, Key, Desc, False);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
    ReflectDeleteProperty:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        Found := Target.DeleteProperty(R, Key);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
    ReflectGet:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        Receiver := Args^[0];
        if ArgCount > 2 then
          Receiver := Args^[2];
        Result := Target.Get(R, Key, Receiver);
      end;
    ReflectGetOwnPropertyDescriptor:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        Found := Target.GetOwnProperty(R, Key, Desc);
        if Found < 0 then
          Exit(JsException);
        if Found = 0 then
          Exit(JsUndefined);
        Result := FromPropertyDescriptor(R, Desc);
      end;
    ReflectGetPrototypeOf:
      begin
        if not Target.GetPrototype(R, Prototype) then
          Exit(JsException);
        if Prototype = nil then
          Exit(JsNull);
        Result := JsObjectValue(Prototype);
      end;
    ReflectHas:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        Found := Target.HasProperty(R, Key);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
    ReflectIsExtensible:
      begin
        Found := Target.IsExtensible(R);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
    ReflectOwnKeys:
      begin
        if not Target.OwnPropertyKeys(R, KeysAll, Keys) then
          Exit(JsException);
        Created := R.NewArray(0);
        for Index := 0 to High(Keys) do
          Created.CreateDataProperty(R, JsInteger(Index), KeyToStringValue(R, Keys[Index]));
        Result := JsObjectValue(Created);
      end;
    ReflectPreventExtensions:
      begin
        Found := Target.PreventExtensions(R);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
    ReflectSet:
      begin
        Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
        if Key = JsException then
          Exit(JsException);
        Receiver := Args^[0];
        if ArgCount > 3 then
          Receiver := Args^[3];
        Found := Target.SetValue(R, Key, Arg(Args, ArgCount, 2), Receiver);
        if Found < 0 then
          Exit(JsException);
        Result := JsBoolean(Found > 0);
      end;
  else
    if not JsIsObject(Arg(Args, ArgCount, 1)) and (Arg(Args, ArgCount, 1) <> JsNull) then
      Exit(R.ThrowTypeError('Object prototype may only be an Object or null'));
    if Arg(Args, ArgCount, 1) = JsNull then
      Found := Target.SetPrototype(R, nil)
    else
      Found := Target.SetPrototype(R, JsAsObject(Args^[1]));
    if Found < 0 then
      Exit(JsException);
    Result := JsBoolean(Found > 0);
  end;
end;

procedure InstallReflect(R: TJsInterpreterRealm);
var
  Reflect: TJsObject;
  Constructor_: TJsNativeFunction;
begin
  Reflect := R.NewPlainObject;
  DefineValue(R, R.GlobalObject, 'Reflect', JsObjectValue(Reflect));
  Reflect.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Reflect'), PropertyConfigurable);
  DefineMethod(R, Reflect, 'apply', @ReflectMethod, 3, ReflectApply);
  DefineMethod(R, Reflect, 'construct', @ReflectMethod, 2, ReflectConstruct);
  DefineMethod(R, Reflect, 'defineProperty', @ReflectMethod, 3, ReflectDefineProperty);
  DefineMethod(R, Reflect, 'deleteProperty', @ReflectMethod, 2, ReflectDeleteProperty);
  DefineMethod(R, Reflect, 'get', @ReflectMethod, 2, ReflectGet);
  DefineMethod(R, Reflect, 'getOwnPropertyDescriptor', @ReflectMethod, 2, ReflectGetOwnPropertyDescriptor);
  DefineMethod(R, Reflect, 'getPrototypeOf', @ReflectMethod, 1, ReflectGetPrototypeOf);
  DefineMethod(R, Reflect, 'has', @ReflectMethod, 2, ReflectHas);
  DefineMethod(R, Reflect, 'isExtensible', @ReflectMethod, 1, ReflectIsExtensible);
  DefineMethod(R, Reflect, 'ownKeys', @ReflectMethod, 1, ReflectOwnKeys);
  DefineMethod(R, Reflect, 'preventExtensions', @ReflectMethod, 1, ReflectPreventExtensions);
  DefineMethod(R, Reflect, 'set', @ReflectMethod, 3, ReflectSet);
  DefineMethod(R, Reflect, 'setPrototypeOf', @ReflectMethod, 2, ReflectSetPrototypeOf);
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Proxy', @ProxyConstructor, 2, nil);
  R.Intrinsics[inProxy] := Constructor_;
  DefineMethod(R, Constructor_, 'revocable', @ProxyRevocable, 2);
end;

end.

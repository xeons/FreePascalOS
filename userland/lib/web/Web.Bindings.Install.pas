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
  Makes the interface objects of a context from the tables (WebIDL 3.7):
  per interface a host class (constructor on the global object, its
  prototype chained to the parent's), constants on both, attributes as
  accessor pairs and operations as methods on the prototype (static ones
  on the constructor), stringifiers, iterable declarations. The window's
  own members ([Global]) go on the global object, whose prototype becomes
  Window.prototype; its [LegacyUnforgeable] ones are not configurable.

  Interfaces are made when first needed (a wrapper of one, or a script
  reading its name on the global object, which holds an accessor until
  then): a page uses a few dozen of the hundred or so, and each costs
  its prototype, accessor pairs and functions.
}
unit Web.Bindings.Install;

{$mode objfpc}
{$H+}

interface

uses
  Web.Bindings.Context;

procedure InstallBindings(Context: TBindingContext);

implementation

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Symbols,
  Js.Shapes,
  Js.Objects,
  Js.Functions,
  Js.Operations,
  Js.Engine,
  Web.Atoms,
  Web.Bindings.Types,
  Web.Bindings.Tables,
  Web.Bindings.Dispatch,
  Web.Bindings.Exotic;

function NewFunction(Context: TBindingContext; const Name: string; Callback: TJsNativeCallback; Length: Integer;
  InterfaceId: Integer; Data: Pointer): TJsNativeFunction;
begin
  Result := NewNativeFunction(Context.Engine.Realm, Name, Callback, Length, InterfaceId);
  Result.HostData := Data;
end;

procedure InstallMember(Context: TBindingContext; Info: PBindingInterface; InterfaceId: Integer;
  Member: PBindingMember; Prototype, Constructor_: TJsObject; IsGlobal: Boolean);
var
  R: TJsRealm;
  Index: Integer;
  Key, Getter, Setter: TJsValue;
  Target: TJsObject;
  Flags: Byte;
  Length: Integer;
  Name: string;
begin
  R := Context.Engine.Realm;
  Name := string(Member^.Name);
  if (Member^.Flags and MemberHidden) <> 0 then
    Exit;
  if (Member^.Flags and MemberStatic) <> 0 then
    Target := Constructor_
  else
    Target := Prototype;
  case Member^.Kind of
    mkConstant:
      begin
        Key := R.Intern(Name);
        Prototype.DefineData(R, Key, JsNumber(Member^.Value), PropertyEnumerable);
        if Constructor_ <> Prototype then
          Constructor_.DefineData(R, Key, JsNumber(Member^.Value), PropertyEnumerable);
      end;
    mkEventHandler:
      begin
        { One pair of functions per handler name serves every interface
          (they work on any event target). }
        if Context.EventHandlerAccessors = nil then
        begin
          Context.EventHandlerAccessors := TStringList.Create;
          Context.EventHandlerAccessors.Sorted := True;
        end;
        Index := Context.EventHandlerAccessors.IndexOf(Name);
        if Index < 0 then
        begin
          Getter := JsObjectValue(NewFunction(Context, 'get ' + Name, @GetterEntry, 0, InterfaceEventTarget, Member));
          Setter := JsObjectValue(NewFunction(Context, 'set ' + Name, @SetterEntry, 1, InterfaceEventTarget, Member));
          Index := Context.EventHandlerAccessors.AddObject(Name, TObject(JsAsObject(Getter)));
          Context.EventHandlerAccessors.Objects[Index] := TObject(JsAsObject(Getter));
          Context.EventHandlerAccessors.AddObject(Name + '=', TObject(JsAsObject(Setter)));
        end
        else
        begin
          Getter := JsObjectValue(TJsObject(Context.EventHandlerAccessors.Objects[Index]));
          Setter := JsObjectValue(TJsObject(Context.EventHandlerAccessors.Objects[
            Context.EventHandlerAccessors.IndexOf(Name + '=')]));
        end;
        Flags := PropertyEnumerable or PropertyConfigurable;
        Target.DefineAccessor(R, R.Intern(Name), Getter, Setter, Flags);
      end;
    mkAttribute, mkReflected:
      begin
        Key := R.Intern(Name);
        Getter := JsObjectValue(NewFunction(Context, 'get ' + Name, @GetterEntry, 0, InterfaceId, Member));
        if ((Member^.Flags and MemberReadonly) = 0) or
          ((Member^.Flags and (MemberPutForwards or MemberReplaceable)) <> 0) then
          Setter := JsObjectValue(NewFunction(Context, 'set ' + Name, @SetterEntry, 1, InterfaceId, Member))
        else
          Setter := JsUndefined;
        Flags := PropertyEnumerable or PropertyConfigurable;
        if IsGlobal and ((Member^.Flags and MemberUnforgeable) <> 0) then
          Flags := PropertyEnumerable;
        Target.DefineAccessor(R, Key, Getter, Setter, Flags);
        if (Member^.Flags and MemberStringifier) <> 0 then
          Prototype.DefineData(R, R.Intern('toString'),
            JsObjectValue(NewFunction(Context, 'toString', @GetterEntry, 0, InterfaceId, Member)),
            PropertyDefault);
      end;
    mkOperation:
      begin
        Length := BindingOverloads[Member^.FirstOverload].RequiredCount;
        Target.DefineData(R, R.Intern(Name),
          JsObjectValue(NewFunction(Context, Name, @OperationEntry, Length, InterfaceId, Member)), PropertyDefault);
      end;
    mkStringifier:
      Prototype.DefineData(R, R.Intern('toString'),
        JsObjectValue(NewFunction(Context, 'toString', @StringifierEntry, 0, InterfaceId, Member)), PropertyDefault);
  end;
end;

procedure InstallIterable(Context: TBindingContext; Info: PBindingInterface; InterfaceId: Integer;
  Prototype: TJsObject);
const
  PairNames: array[0..3] of string = ('entries', 'keys', 'values', 'forEach');
var
  R: TJsRealm;
  ArrayPrototype: TJsObject;
  Index: Integer;
  Method: TJsNativeFunction;
begin
  R := Context.Engine.Realm;
  if (Info^.Flags and InterfaceValueIterable) <> 0 then
  begin
    ArrayPrototype := R.Intrinsics[inArrayPrototype];
    for Index := 0 to 3 do
      Prototype.DefineData(R, R.Intern(PairNames[Index]), ArrayPrototype.GetValue(R, R.Intern(PairNames[Index])),
        PropertyDefault);
    Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), JsObjectValue(R.Intrinsics[inArrayValues]),
      PropertyHidden);
  end
  else if (Info^.Flags and InterfacePairIterable) <> 0 then
  begin
    for Index := 0 to 3 do
    begin
      if Index = 3 then
        Method := NewFunction(Context, PairNames[Index], @PairIterationEntry, 1, InterfaceId, Pointer(PtrInt(Index)))
      else
        Method := NewFunction(Context, PairNames[Index], @PairIterationEntry, 0, InterfaceId, Pointer(PtrInt(Index)));
      Prototype.DefineData(R, R.Intern(PairNames[Index]), JsObjectValue(Method), PropertyDefault);
      if Index = 0 then
        Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), JsObjectValue(Method), PropertyHidden);
    end;
  end;
end;

procedure InstallInterface(Context: TBindingContext; InterfaceId: Integer); forward;

{ The global property of an interface not made yet: reading it makes the
  interface (its constructor replaces the accessor); writing replaces it
  with the value. }
function LazyInterfaceGetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  Context.EnsureInterface(Callee.Magic);
  Result := Context.Engine.GlobalObject.GetValue(R, Callee.Data);
end;

function LazyInterfaceSetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Global: TJsObject;
begin
  Global := ContextOfRealm(R).Engine.GlobalObject;
  Global.DeleteProperty(R, Callee.Data);
  Global.CreateDataProperty(R, Callee.Data, Arg(Args, ArgCount, 0));
  Result := JsUndefined;
end;

procedure DefineLazyName(Context: TBindingContext; const Name: string; InterfaceId: Integer);
var
  R: TJsRealm;
  Key: TJsValue;
  Getter, Setter: TJsNativeFunction;
begin
  R := Context.Engine.Realm;
  Key := R.Intern(Name);
  Getter := NewFunction(Context, 'get ' + Name, @LazyInterfaceGetter, 0, InterfaceId, nil);
  Getter.Data := Key;
  Setter := NewFunction(Context, 'set ' + Name, @LazyInterfaceSetter, 1, InterfaceId, nil);
  Setter.Data := Key;
  Context.Engine.GlobalObject.DefineAccessor(R, Key, JsObjectValue(Getter), JsObjectValue(Setter),
    PropertyConfigurable);
end;

{ Makes the interface objects of InterfaceId (and its parents first). }
procedure InstallInterface(Context: TBindingContext; InterfaceId: Integer);
var
  R: TJsRealm;
  Index: Integer;
  Info: PBindingInterface;
  Binding: TBindingClass;
  Parent: TJsHostClass;
  Callback: TJsNativeCallback;
  Prototype, Global: TJsObject;
  IsGlobal: Boolean;
begin
  R := Context.Engine.Realm;
  Global := Context.Engine.GlobalObject;
  Info := @BindingInterfaces[InterfaceId];
  Binding := Context.InterfaceClasses[InterfaceId];
  if Binding.HostClass <> nil then
    Exit;
  if Info^.Parent >= 0 then
    Parent := Context.EnsureInterface(Info^.Parent).HostClass
  else
    Parent := nil;
  if (Info^.Flags and InterfaceHasConstructor) <> 0 then
    Callback := @ConstructorEntry
  else
    Callback := nil;
  Global.DeleteProperty(R, R.Intern(string(Info^.Name)));
  if Info^.Alias <> nil then
    Global.DeleteProperty(R, R.Intern(string(Info^.Alias)));
  Binding.HostClass := Context.Engine.DefineClass(string(Info^.Name), Callback, Info^.ConstructorLength, Parent);
  Binding.HostClass.Tracer := @Binding.TraceNative;
  Binding.HostClass.Constructor_.Magic := InterfaceId;
  Prototype := Binding.HostClass.Prototype;
  if (Info^.Flags and InterfaceExceptionLike) <> 0 then
    Prototype.Proto := R.Intrinsics[inErrorPrototype];
  IsGlobal := (Info^.Flags and InterfaceGlobal) <> 0;
  for Index := Info^.FirstMember to Info^.FirstMember + Info^.MemberCount - 1 do
    if IsGlobal and (BindingMembers[Index].Kind <> mkConstant) then
      InstallMember(Context, Info, InterfaceId, @BindingMembers[Index], Global, Binding.HostClass.Constructor_,
        True)
    else
      InstallMember(Context, Info, InterfaceId, @BindingMembers[Index], Prototype, Binding.HostClass.Constructor_,
        False);
  InstallIterable(Context, Info, InterfaceId, Prototype);
  if Info^.Alias <> nil then
    Global.DefineData(R, R.Intern(string(Info^.Alias)), JsObjectValue(Binding.HostClass.Constructor_),
      PropertyHidden);
  if IsGlobal then
  begin
    Global.Proto := Prototype;
    R.Runtime.PrototypeEpoch := R.Runtime.PrototypeEpoch + 1;
  end;
end;

procedure InstallBindings(Context: TBindingContext);
var
  InterfaceId, Index: Integer;
  Info: PBindingInterface;
  Binding: TBindingClass;
  Atom: TAtom;
begin
  SetLength(Context.InterfaceClasses, InterfaceCount);
  SetLength(Context.InterfaceParents, InterfaceCount);
  Context.IndexedWrapperClass := TIndexedWrapper;
  Context.InterfaceInstaller := @InstallInterface;
  for InterfaceId := 0 to InterfaceCount - 1 do
  begin
    Info := @BindingInterfaces[InterfaceId];
    Context.InterfaceParents[InterfaceId] := Info^.Parent;
    Binding := TBindingClass.Create;
    Binding.Context := Context;
    Binding.InterfaceId := InterfaceId;
    Binding.Flags := Info^.Flags;
    Binding.CacheSlotCount := Info^.CacheSlotCount;
    Context.InterfaceClasses[InterfaceId] := Binding;
    DefineLazyName(Context, string(Info^.Name), InterfaceId);
    if Info^.Alias <> nil then
      DefineLazyName(Context, string(Info^.Alias), InterfaceId);
  end;
  { The window's members are the global object's own. }
  Context.EnsureInterface(InterfaceWindow);
  for Index := Low(BindingElementInterfaces) to High(BindingElementInterfaces) do
  begin
    Atom := Atomize(string(BindingElementInterfaces[Index].LocalName));
    if Atom >= LongWord(Length(Context.ElementInterfaces)) then
    begin
      InterfaceId := Length(Context.ElementInterfaces);
      SetLength(Context.ElementInterfaces, Atom + 64);
      while InterfaceId < Length(Context.ElementInterfaces) do
      begin
        Context.ElementInterfaces[InterfaceId] := -1;
        Inc(InterfaceId);
      end;
    end;
    Context.ElementInterfaces[Atom] := BindingElementInterfaces[Index].InterfaceId;
  end;
end;

end.

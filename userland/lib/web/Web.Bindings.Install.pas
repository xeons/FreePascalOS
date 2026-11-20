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
    mkAttribute, mkReflected, mkEventHandler:
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

procedure InstallBindings(Context: TBindingContext);
var
  R: TJsRealm;
  InterfaceId, Index: Integer;
  Info: PBindingInterface;
  Binding: TBindingClass;
  Parent: TJsHostClass;
  Callback: TJsNativeCallback;
  Prototype, Global: TJsObject;
  IsGlobal: Boolean;
  Atom: TAtom;
begin
  R := Context.Engine.Realm;
  Global := Context.Engine.GlobalObject;
  SetLength(Context.InterfaceClasses, InterfaceCount);
  SetLength(Context.InterfaceParents, InterfaceCount);
  Context.IndexedWrapperClass := TIndexedWrapper;
  for InterfaceId := 0 to InterfaceCount - 1 do
  begin
    Info := @BindingInterfaces[InterfaceId];
    Context.InterfaceParents[InterfaceId] := Info^.Parent;
    if Info^.Parent >= 0 then
      Parent := Context.InterfaceClasses[Info^.Parent].HostClass
    else
      Parent := nil;
    if (Info^.Flags and InterfaceHasConstructor) <> 0 then
      Callback := @ConstructorEntry
    else
      Callback := nil;
    Binding := TBindingClass.Create;
    Binding.Context := Context;
    Binding.InterfaceId := InterfaceId;
    Binding.Flags := Info^.Flags;
    Binding.CacheSlotCount := Info^.CacheSlotCount;
    Binding.HostClass := Context.Engine.DefineClass(string(Info^.Name), Callback, Info^.ConstructorLength, Parent);
    Binding.HostClass.Tracer := @Binding.TraceNative;
    Binding.HostClass.Constructor_.Magic := InterfaceId;
    Context.InterfaceClasses[InterfaceId] := Binding;
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

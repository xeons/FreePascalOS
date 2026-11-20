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
  Symbol: the function (not a constructor), the registry (Symbol.for,
  Symbol.keyFor), the well-known symbols and Symbol.prototype.
}
unit Js.Builtins.Symbol;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter;

procedure InstallSymbol(R: TJsInterpreterRealm);

implementation

var
  { The registry of Symbol.for, per realm: an object keyed by the
    strings. Kept on the Symbol function as a hidden slot. }
  RegistryKey: string = '%registry';

function ThisSymbol(R: TJsRealm; Value: TJsValue; out Symbol: TJsValue): Boolean;
begin
  Symbol := JsUndefined;
  if JsIsSymbol(Value) then
    Symbol := Value
  else if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocSymbol) then
    Symbol := TJsPrimitiveObject(JsAsObject(Value)).PrimitiveValue
  else
  begin
    R.ThrowTypeError('Symbol.prototype method called on incompatible receiver');
    Exit(False);
  end;
  Result := True;
end;

function SymbolFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Description: TJsString;
begin
  if NewTarget <> JsUndefined then
    Exit(R.ThrowTypeError('Symbol is not a constructor'));
  Description := nil;
  if Arg(Args, ArgCount, 0) <> JsUndefined then
  begin
    Description := ToJsString(R, Args^[0]);
    if Description = nil then
      Exit(JsException);
  end;
  Result := JsSymbolValue(NewSymbol(R.Heap, Description));
end;

function Registry(R: TJsRealm; Callee: TJsNativeFunction): TJsObject;
begin
  Result := JsAsObject(Callee.Data);
end;

function SymbolFor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Key: TJsString;
  Atom: TJsValue;
  Table: TJsObject;
  Symbol: TJsSymbol;
begin
  Key := ToJsString(R, Arg(Args, ArgCount, 0));
  if Key = nil then
    Exit(JsException);
  Atom := JsStringValue(R.Runtime.Atoms.Intern(Key));
  Table := Registry(R, Callee);
  Result := Table.GetValue(R, Atom);
  if JsIsSymbol(Result) then
    Exit;
  Symbol := NewSymbol(R.Heap, JsAsString(Atom));
  Symbol.IsRegistered := True;
  Result := JsSymbolValue(Symbol);
  Table.DefineData(R, Atom, Result);
end;

function SymbolKeyFor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  Value := Arg(Args, ArgCount, 0);
  if not JsIsSymbol(Value) then
    Exit(R.ThrowTypeError(ValueToPascal(R, Value) + ' is not a symbol'));
  if not JsAsSymbol(Value).IsRegistered then
    Exit(JsUndefined);
  Result := JsStringValue(JsAsSymbol(Value).Description);
end;

function SymbolPrototypeToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Symbol: TJsValue;
begin
  if not ThisSymbol(R, This, Symbol) then
    Exit(JsException);
  Result := R.NewString(KeyToPascal(R, Symbol));
end;

function SymbolPrototypeValueOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if not ThisSymbol(R, This, Result) then
    Exit(JsException);
end;

function SymbolPrototypeDescription(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Symbol: TJsValue;
begin
  if not ThisSymbol(R, This, Symbol) then
    Exit(JsException);
  if JsAsSymbol(Symbol).Description = nil then
    Exit(JsUndefined);
  Result := JsStringValue(JsAsSymbol(Symbol).Description);
end;

procedure InstallSymbol(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
  Symbol: TJsWellKnownSymbol;
  Registry_: TJsObject;
begin
  Prototype := R.Intrinsics[inSymbolPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Symbol', @SymbolFunction, 0, Prototype);
  for Symbol := Low(TJsWellKnownSymbol) to High(TJsWellKnownSymbol) do
    DefineValue(R, Constructor_, WellKnownSymbolNames[Symbol], R.Runtime.SymbolValue(Symbol), 0);
  Registry_ := R.NewObject(nil);
  DefineMethod(R, Constructor_, 'for', @SymbolFor, 1);
  TJsNativeFunction(JsAsObject(Constructor_.GetValue(R, R.Intern('for')))).Data := JsObjectValue(Registry_);
  DefineMethod(R, Constructor_, 'keyFor', @SymbolKeyFor, 1);
  DefineMethod(R, Prototype, 'toString', @SymbolPrototypeToString, 0);
  DefineMethod(R, Prototype, 'valueOf', @SymbolPrototypeValueOf, 0);
  DefineGetter(R, Prototype, 'description', @SymbolPrototypeDescription);
  DefineSymbolMethod(R, Prototype, wsToPrimitive, '[Symbol.toPrimitive]', @SymbolPrototypeValueOf, 1,
    PropertyConfigurable);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Symbol'), PropertyConfigurable);
  if RegistryKey = '' then;
end;

end.

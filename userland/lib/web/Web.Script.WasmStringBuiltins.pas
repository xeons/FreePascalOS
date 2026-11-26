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
  JS String Builtins (JS API "Builtins", set js-string): the functions a
  module compiled with the option builtins: ["js-string"] imports from
  "wasm:js-string" - cast, test, fromCharCodeArray, intoCharCodeArray,
  fromCharCode, fromCodePoint, charCodeAt, codePointAt, length, concat,
  substring, equals, compare - as host functions working on the
  JavaScript strings externrefs hold, and the compile-time checks of
  builtin and string constant imports.

    wasmValidateBuiltins(module, jsString, stringModule)
                                     whether every wasm:js-string import
                                     naming a builtin (when jsString) is a
                                     function whose type the builtin's
                                     matches, and every import of
                                     stringModule (a string or null) a
                                     global const of a supertype of
                                     (ref extern)
    wasmStringBuiltins()             an object (null prototype) of the
                                     builtins as Exported Functions, one
                                     per agent

  The builtins' types are each a rec group of its own (the array of
  i16 too), registered in the store from a small module of just those
  types. A string that is not one, an index out of range and the like
  trap (a RuntimeError), as the JS API has it.
}
unit Web.Script.WasmStringBuiltins;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

function NativeValidateBuiltins(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
function NativeStringBuiltins(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;

implementation

uses
  SysUtils,
  Js.Strings,
  Js.Conversions,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmValues,
  Web.Script.WasmHostValues,
  Web.Script.WasmNativeArguments;

type
  TStringBuiltin = (sbCast, sbTest, sbFromCharCodeArray, sbIntoCharCodeArray, sbFromCharCode, sbFromCodePoint,
    sbCharCodeAt, sbCodePointAt, sbLength, sbConcat, sbSubstring, sbEquals, sbCompare);

  TStringBuiltinCalls = class
  public
    procedure Call(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
  end;

const
  BuiltinNames: array[TStringBuiltin] of string = ('cast', 'test', 'fromCharCodeArray', 'intoCharCodeArray',
    'fromCharCode', 'fromCodePoint', 'charCodeAt', 'codePointAt', 'length', 'concat', 'substring', 'equals',
    'compare');
  { Each builtin's type: its index in the types module below. }
  BuiltinTypes: array[TStringBuiltin] of Integer = (1, 2, 3, 4, 5, 5, 6, 6, 2, 7, 8, 9, 9);
  { The types module's type section: 0 (array (mut i16)), then the
    builtins' function types (0x63 0x00: (ref null 0); 0x64 0x6F:
    (ref extern)). }
  TypeEntries: array[0..9] of string = (
    #$5E#$77#$01,
    #$60#$01#$6F#$01#$64#$6F,
    #$60#$01#$6F#$01#$7F,
    #$60#$03#$63#$00#$7F#$7F#$01#$64#$6F,
    #$60#$03#$6F#$63#$00#$7F#$01#$7F,
    #$60#$01#$7F#$01#$64#$6F,
    #$60#$02#$6F#$7F#$01#$7F,
    #$60#$02#$6F#$6F#$01#$64#$6F,
    #$60#$03#$6F#$7F#$7F#$01#$64#$6F,
    #$60#$02#$6F#$6F#$01#$7F);
  StringModuleName = 'wasm:js-string';

var
  BuiltinCalls: TStringBuiltinCalls;
  TypesModule: TWasmModule;

function TypesModuleBytes: TBytes;
var
  Body: string;
  Index: Integer;
  Text: string;
begin
  Body := Chr(Length(TypeEntries));
  for Index := 0 to High(TypeEntries) do
    Body := Body + TypeEntries[Index];
  Text := #$00'asm'#$01#$00#$00#$00#$01 + Chr(Length(Body)) + Body;
  Result := nil;
  SetLength(Result, Length(Text));
  Move(Text[1], Result[0], Length(Text));
end;

{ The store type ids of the builtins' types. }
function BuiltinTypeIds(Agent: TWasmAgent): TWasmIdArray;
begin
  if TypesModule = nil then
    TypesModule := WasmCompile(TypesModuleBytes);
  Result := WasmModuleTypeIds(Agent, TypesModule);
end;

function FindBuiltin(const Name: string; out Builtin: TStringBuiltin): Boolean;
var
  Candidate: TStringBuiltin;
begin
  Builtin := sbCast;
  for Candidate := Low(Candidate) to High(Candidate) do
    if BuiltinNames[Candidate] = Name then
    begin
      Builtin := Candidate;
      Exit(True);
    end;
  Result := False;
end;

function ImportValid(Agent: TWasmAgent; Module: TWasmModule; Index: Integer; JsString: Boolean;
  const StringModule: string; HasStringModule: Boolean; const TypeIds, BuiltinIds: TWasmIdArray): Boolean;
var
  Builtin: TStringBuiltin;
begin
  Result := True;
  with Module.Imports[Index] do
    if HasStringModule and (ModuleName = StringModule) then
      Result := (Kind = ekGlobal) and not GlobalType.Mutable and (GlobalType.ValueType.Kind = vkReference) and
        (GlobalType.ValueType.HeapType = HeapTypeExtern)
    else if JsString and (ModuleName = StringModuleName) and FindBuiltin(FieldName, Builtin) then
      Result := (Kind = ekFunction) and Agent.Registry.IsSubtype(BuiltinIds[BuiltinTypes[Builtin]],
        TypeIds[TypeIndex]);
end;

function NativeValidateBuiltins(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Agent: TWasmAgent;
  JsString, HasStringModule: Boolean;
  StringModule: string;
  TypeIds, BuiltinIds: TWasmIdArray;
  Index: Integer;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Agent := AgentOf(Context);
  JsString := ToBoolean(Arg(Args, ArgCount, 1));
  HasStringModule := not JsIsNullish(Arg(Args, ArgCount, 2));
  StringModule := '';
  if HasStringModule then
    StringModule := ValueToText(R, Arg(Args, ArgCount, 2));
  TypeIds := WasmModuleTypeIds(Agent, Module);
  BuiltinIds := BuiltinTypeIds(Agent);
  for Index := 0 to High(Module.Imports) do
    if not ImportValid(Agent, Module, Index, JsString, StringModule, HasStringModule, TypeIds, BuiltinIds) then
      Exit(JsFalse);
  Result := JsTrue;
end;

function NativeStringBuiltins(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
var
  Agent: TWasmAgent;
  Made: TJsObject;
  Ids: TWasmIdArray;
  Builtin: TStringBuiltin;
  Func: TWasmFunction;
  Mark: Integer;
begin
  Agent := AgentOf(Context);
  if Agent.StringBuiltins <> nil then
    Exit(JsObjectValue(Agent.StringBuiltins));
  Ids := BuiltinTypeIds(Agent);
  Made := R.NewObject(nil);
  Mark := R.Runtime.PushRoot(JsObjectValue(Made));
  try
    for Builtin := Low(Builtin) to High(Builtin) do
    begin
      { The data is the builtin's number plus one: below every JavaScript
        value that the agent's marking of host data would follow. }
      Func := WasmNewHostFunctionOfType(Agent, Ids[BuiltinTypes[Builtin]], @BuiltinCalls.Call,
        Pointer(PtrUInt(Ord(Builtin) + 1)));
      Made.CreateDataProperty(R, R.Intern(BuiltinNames[Builtin]), ExportedFunctionValue(R, Func));
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Agent.StringBuiltins := Made;
  Result := JsObjectValue(Made);
end;

{ The calls }

procedure Trap(const Message: string);
begin
  raise EWasmTrap.CreateTrap(tkHostError, Message);
end;

{ The string an externref holds, or nil. }
function StringOf(Agent: TWasmAgent; Reference: Pointer): TJsString;
var
  Value: TJsValue;
begin
  Result := nil;
  if (Reference = nil) or (PtrUInt(Reference) and 1 <> 0) or Agent.Heap.IsObject(Reference) then
    Exit;
  Value := HostValueOf(Reference);
  if JsIsString(Value) then
    Result := TJsString(JsAsCell(Value));
end;

function UnwrapString(Agent: TWasmAgent; Reference: Pointer): TJsString;
begin
  Result := StringOf(Agent, Reference);
  if Result = nil then
    Trap('wasm:js-string: the value is not a string');
end;

function StringReference(Text: TJsString): Pointer; inline;
begin
  Result := Pointer(PtrUInt(JsCellValue(JsStringBase, Text)));
end;

function UnitsString(R: TJsRealm; const Units: UnicodeString): TJsString;
begin
  if Length(Units) = 0 then
    Result := NewUtf16String(R.Heap, nil, 0)
  else
    Result := NewUtf16String(R.Heap, PWord(@Units[1]), Length(Units));
end;

function CodePointString(R: TJsRealm; CodePoint: DWord): TJsString;
var
  Units: UnicodeString;
begin
  if CodePoint >= $10000 then
    Units := WideChar($D800 + ((CodePoint - $10000) shr 10)) + WideChar($DC00 + ((CodePoint - $10000) and $3FF))
  else
    Units := WideChar(CodePoint);
  Result := UnitsString(R, Units);
end;

function FromCharCodeArray(R: TJsRealm; Agent: TWasmAgent; ArrayReference: Pointer; Start, Finish: DWord): TJsString;
var
  Units: UnicodeString;
  Index: DWord;
begin
  if ArrayReference = nil then
    Trap('wasm:js-string fromCharCodeArray: null array');
  if (Start > Finish) or (Finish > WasmArrayLength(ArrayReference)) then
    Trap('wasm:js-string fromCharCodeArray: range out of bounds');
  SetLength(Units, Finish - Start);
  Index := Start;
  while Index < Finish do
  begin
    Units[Index - Start + 1] := WideChar(Word(WasmArrayGetElement(Agent, ArrayReference, Index).I32));
    Inc(Index);
  end;
  Result := UnitsString(R, Units);
end;

function IntoCharCodeArray(R: TJsRealm; Agent: TWasmAgent; Reference, ArrayReference: Pointer; Start: DWord): Int32;
var
  Text: TJsString;
  Index: Integer;
begin
  if ArrayReference = nil then
    Trap('wasm:js-string intoCharCodeArray: null array');
  Text := UnwrapString(Agent, Reference);
  if QWord(Start) + QWord(Text.Length) > WasmArrayLength(ArrayReference) then
    Trap('wasm:js-string intoCharCodeArray: range out of bounds');
  Text.Flatten(R.Heap);
  for Index := 0 to Text.Length - 1 do
    WasmArraySetElement(Agent, ArrayReference, Start + DWord(Index), WasmI32(Text.CharAt(Index)));
  Result := Text.Length;
end;

function CodePointAt(R: TJsRealm; Text: TJsString; Index: DWord): Int32;
var
  First, Second: Word;
begin
  if Index >= DWord(Text.Length) then
    Trap('wasm:js-string codePointAt: index out of bounds');
  Text.Flatten(R.Heap);
  First := Text.CharAt(Index);
  Result := First;
  if (First >= $D800) and (First <= $DBFF) and (Index + 1 < DWord(Text.Length)) then
  begin
    Second := Text.CharAt(Index + 1);
    if (Second >= $DC00) and (Second <= $DFFF) then
      Result := $10000 + ((First - $D800) shl 10) + (Second - $DC00);
  end;
end;

function Clamp(Value: Int32; Limit: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > Limit then
    Result := Limit
  else
    Result := Value;
end;

{ String.prototype.substring with the JS API's guard first. }
function GuardedSubstring(R: TJsRealm; Text: TJsString; Start, Finish: Int32): TJsString;
var
  First, Last: Integer;
begin
  if (DWord(Start) > DWord(Finish)) or (DWord(Start) > DWord(Text.Length)) then
    Exit(NewLatin1String(R.Heap, nil, 0));
  First := Clamp(Start, Text.Length);
  Last := Clamp(Finish, Text.Length);
  if First > Last then
  begin
    Result := SubString(R.Heap, Text, Last, First - Last);
    Exit;
  end;
  Result := SubString(R.Heap, Text, First, Last - First);
end;

function StringsEqualOrNull(R: TJsRealm; Agent: TWasmAgent; First, Second: Pointer): Int32;
var
  FirstText, SecondText: TJsString;
begin
  FirstText := StringOf(Agent, First);
  SecondText := StringOf(Agent, Second);
  if ((First <> nil) and (FirstText = nil)) or ((Second <> nil) and (SecondText = nil)) then
    Trap('wasm:js-string equals: the value is not a string');
  if (FirstText = nil) or (SecondText = nil) then
    Exit(Ord((FirstText = nil) and (SecondText = nil)));
  Result := Ord(StringsEqual(R.Heap, FirstText, SecondText));
end;

function Compare(R: TJsRealm; Agent: TWasmAgent; First, Second: Pointer): Int32;
var
  Order: Integer;
begin
  Order := CompareStrings(R.Heap, UnwrapString(Agent, First), UnwrapString(Agent, Second));
  if Order < 0 then
    Result := -1
  else if Order > 0 then
    Result := 1
  else
    Result := 0;
end;

function Concat(R: TJsRealm; Agent: TWasmAgent; First, Second: Pointer): TJsString;
begin
  Result := ConcatStrings(R.Heap, UnwrapString(Agent, First), UnwrapString(Agent, Second));
  if Result = nil then
    Trap('wasm:js-string concat: the string would be too long');
end;

procedure TStringBuiltinCalls.Call(Func: TWasmFunction; const Arguments: TWasmValueArray;
  var Results: TWasmValueArray);
var
  Agent: TWasmAgent;
  R: TJsRealm;
  Text: TJsString;
begin
  Agent := AgentOfStore(Func.Store);
  R := Agent.Context.Engine.Realm;
  Text := nil;
  case TStringBuiltin(PtrUInt(Func.HostData) - 1) of
    sbCast: Results[0].Reference := StringReference(UnwrapString(Agent, Arguments[0].Reference));
    sbTest: Results[0].I32 := Ord(StringOf(Agent, Arguments[0].Reference) <> nil);
    sbFromCharCodeArray:
      Text := FromCharCodeArray(R, Agent, Arguments[0].Reference, DWord(Arguments[1].I32), DWord(Arguments[2].I32));
    sbIntoCharCodeArray:
      Results[0].I32 := IntoCharCodeArray(R, Agent, Arguments[0].Reference, Arguments[1].Reference,
        DWord(Arguments[2].I32));
    sbFromCharCode: Text := CodePointString(R, Word(Arguments[0].I32));
    sbFromCodePoint:
      begin
        if DWord(Arguments[0].I32) > $10FFFF then
          Trap('wasm:js-string fromCodePoint: not a code point');
        Text := CodePointString(R, DWord(Arguments[0].I32));
      end;
    sbCharCodeAt:
      begin
        Text := UnwrapString(Agent, Arguments[0].Reference);
        if DWord(Arguments[1].I32) >= DWord(Text.Length) then
          Trap('wasm:js-string charCodeAt: index out of bounds');
        Text.Flatten(R.Heap);
        Results[0].I32 := Text.CharAt(Arguments[1].I32);
        Text := nil;
      end;
    sbCodePointAt: Results[0].I32 := CodePointAt(R, UnwrapString(Agent, Arguments[0].Reference),
      DWord(Arguments[1].I32));
    sbLength: Results[0].I32 := UnwrapString(Agent, Arguments[0].Reference).Length;
    sbConcat: Text := Concat(R, Agent, Arguments[0].Reference, Arguments[1].Reference);
    sbSubstring: Text := GuardedSubstring(R, UnwrapString(Agent, Arguments[0].Reference), Arguments[1].I32,
      Arguments[2].I32);
    sbEquals: Results[0].I32 := StringsEqualOrNull(R, Agent, Arguments[0].Reference, Arguments[1].Reference);
    sbCompare: Results[0].I32 := Compare(R, Agent, Arguments[0].Reference, Arguments[1].Reference);
  end;
  { A string result: WebAssembly holds it from here on. }
  if Text <> nil then
    Results[0].Reference := StringReference(Text);
end;

initialization
  BuiltinCalls := TStringBuiltinCalls.Create;
finalization
  if TypesModule <> nil then
    TypesModule.Release;
end.

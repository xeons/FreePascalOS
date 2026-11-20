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
  Values as readable text: what console.log and the shell print.

  Close to Node's util.inspect, always on one line: strings quoted
  inside structures, arrays as [ 1, 2 ], objects as (a: 1) in braces, with the
  constructor's name in front for instances of classes, functions as
  [Function: name], errors as their stack, Map and Set with their
  entries, nesting shown to a depth of two levels ([Object] beyond),
  cycles as [Circular]. Getters are not called ([Getter]).
}
unit Js.Inspect;

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
  Js.BigIntegers,
  Js.Conversions,
  Js.Promises;

type
  { The entries of a Map (pairs) or Set (single values), for printing. }
  TJsCollectionEntries = function(R: TJsRealm; Target: TJsObject; out Values: TJsValueList): Boolean;
  { Extra text for objects other units know (Date, RegExp). }
  TJsInspectExtra = function(R: TJsRealm; Target: TJsObject; out Text: string): Boolean;

var
  JsCollectionEntries: TJsCollectionEntries = nil;

{ Adds a printer for objects another unit knows (once). }
procedure RegisterInspectExtra(Hook: TJsInspectExtra);

{ The text console.log prints for one value (strings as they are). }
function InspectValue(R: TJsRealm; Value: TJsValue): string;
{ The text of a value inside a structure (strings quoted). }
function InspectNested(R: TJsRealm; Value: TJsValue): string;
function QuoteString(const Text: string): string;

implementation

var
  InspectExtras: array of TJsInspectExtra;

procedure RegisterInspectExtra(Hook: TJsInspectExtra);
var
  Index: Integer;
begin
  for Index := 0 to High(InspectExtras) do
    if InspectExtras[Index] = Hook then
      Exit;
  SetLength(InspectExtras, Length(InspectExtras) + 1);
  InspectExtras[High(InspectExtras)] := Hook;
end;

function InspectExtra(R: TJsRealm; Target: TJsObject; out Text: string): Boolean;
var
  Index: Integer;
begin
  Text := '';
  for Index := 0 to High(InspectExtras) do
    if InspectExtras[Index](R, Target, Text) then
      Exit(True);
  Result := False;
end;

type
  TInspector = class
  private
    FRealm: TJsRealm;
    FSeen: array of TJsObject;
    function Seen(Target: TJsObject): Boolean;
    function KeyText(Key: TJsValue): string;
    function FunctionText(Target: TJsObject): string;
    function ConstructorName(Target: TJsObject): string;
    function ObjectText(Target: TJsObject; Depth: Integer): string;
    function PropertiesText(Target: TJsObject; Depth: Integer; SkipIndices: Boolean; out Count: Integer): string;
  public
    constructor Create(R: TJsRealm);
    function Format(Value: TJsValue; Depth: Integer; Nested: Boolean): string;
  end;

function QuoteString(const Text: string): string;
var
  Index: Integer;
  Quote: Char;
begin
  Quote := '''';
  if (Pos('''', Text) > 0) and (Pos('"', Text) = 0) then
    Quote := '"';
  Result := Quote;
  for Index := 1 to Length(Text) do
    case Text[Index] of
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #8: Result := Result + '\b';
      '\': Result := Result + '\\';
    else
      if Text[Index] = Quote then
        Result := Result + '\' + Quote
      else
        Result := Result + Text[Index];
    end;
  Result := Result + Quote;
end;

function IsIdentifierText(const Text: string): Boolean;
var
  Index: Integer;
begin
  if Text = '' then
    Exit(False);
  if not (Text[1] in ['a'..'z', 'A'..'Z', '_', '$']) then
    Exit(False);
  for Index := 2 to Length(Text) do
    if not (Text[Index] in ['a'..'z', 'A'..'Z', '_', '$', '0'..'9']) then
      Exit(False);
  Result := True;
end;

constructor TInspector.Create(R: TJsRealm);
begin
  inherited Create;
  FRealm := R;
end;

function TInspector.Seen(Target: TJsObject): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FSeen) do
    if FSeen[Index] = Target then
      Exit(True);
  Result := False;
end;

function TInspector.KeyText(Key: TJsValue): string;
begin
  if JsIsSymbol(Key) then
    Exit('[' + KeyToPascal(FRealm, Key) + ']');
  Result := KeyToPascal(FRealm, Key);
  if not IsIdentifierText(Result) then
    Result := QuoteString(Result);
end;

function OwnDataValue(R: TJsRealm; Target: TJsObject; Key: TJsValue; out Value: TJsValue): Boolean;
var
  Desc: TJsPropertyDescriptor;
begin
  Value := JsUndefined;
  if Target.GetOwnProperty(R, Key, Desc) <= 0 then
  begin
    if R.HasException then
      R.Runtime.TakeException;
    Exit(False);
  end;
  if DescriptorIsAccessor(Desc) then
    Exit(False);
  Value := Desc.Value;
  Result := True;
end;

function TInspector.FunctionText(Target: TJsObject): string;
var
  Name: TJsValue;
  NameText: string;
begin
  NameText := '';
  if OwnDataValue(FRealm, Target, FRealm.Atom(anName), Name) and JsIsString(Name) then
    NameText := StringToUtf8(FRealm.Heap, JsAsString(Name));
  if (Target is TJsClosure) and ((TJsClosure(Target).Code.Flags and CodeClassConstructor) <> 0) then
  begin
    if NameText = '' then
      Exit('[class (anonymous)]');
    Exit('[class ' + NameText + ']');
  end;
  if (Target is TJsClosure) and ((TJsClosure(Target).Code.Flags and CodeGenerator) <> 0) then
    Result := '[GeneratorFunction'
  else if (Target is TJsClosure) and ((TJsClosure(Target).Code.Flags and CodeAsync) <> 0) then
    Result := '[AsyncFunction'
  else
    Result := '[Function';
  if NameText = '' then
    Result := Result + ' (anonymous)]'
  else
    Result := Result + ': ' + NameText + ']';
end;

function TInspector.ConstructorName(Target: TJsObject): string;
var
  Walk: TJsObject;
  Constructor_, Name: TJsValue;
begin
  Result := '';
  Walk := Target.Proto;
  if Walk = nil then
    Exit('[Object: null prototype]');
  if not OwnDataValue(FRealm, Walk, FRealm.ConstructorKey, Constructor_) or not JsIsObject(Constructor_) then
    Exit;
  if not OwnDataValue(FRealm, JsAsObject(Constructor_), FRealm.Atom(anName), Name) or not JsIsString(Name) then
    Exit;
  Result := StringToUtf8(FRealm.Heap, JsAsString(Name));
end;

function TInspector.PropertiesText(Target: TJsObject; Depth: Integer; SkipIndices: Boolean;
  out Count: Integer): string;
var
  Keys: TJsValueList;
  Index: Integer;
  Desc: TJsPropertyDescriptor;
  Item: string;
begin
  Result := '';
  Count := 0;
  if not Target.OwnPropertyKeys(FRealm, KeysAll, Keys) then
  begin
    FRealm.Runtime.TakeException;
    Exit;
  end;
  for Index := 0 to High(Keys) do
  begin
    if SkipIndices and JsIsInteger(Keys[Index]) then
      Continue;
    if (Target.ObjectClass = ocArray) and (Keys[Index] = FRealm.LengthKey) then
      Continue;
    if Target.GetOwnProperty(FRealm, Keys[Index], Desc) <= 0 then
      Continue;
    if (Desc.Flags and PropertyEnumerable) = 0 then
      Continue;
    if DescriptorIsAccessor(Desc) then
    begin
      if (Desc.Getter <> JsUndefined) and (Desc.Setter <> JsUndefined) then
        Item := '[Getter/Setter]'
      else if Desc.Getter <> JsUndefined then
        Item := '[Getter]'
      else
        Item := '[Setter]';
    end
    else
      Item := Format(Desc.Value, Depth + 1, True);
    if Count > 0 then
      Result := Result + ', ';
    Result := Result + KeyText(Keys[Index]) + ': ' + Item;
    Inc(Count);
    if Count > 100 then
    begin
      Result := Result + ', ...';
      Break;
    end;
  end;
end;

function TInspector.ObjectText(Target: TJsObject; Depth: Integer): string;
var
  Items: string;
  Count, Index, Holes, PropertyCount: Integer;
  Length_: Int64;
  Element, Value: TJsValue;
  Name, Extra, Properties: string;
  Entries: TJsValueList;
  Promise: TJsPromise;
begin
  if Target.IsCallable then
  begin
    Result := FunctionText(Target);
    Properties := PropertiesText(Target, Depth, False, PropertyCount);
    if PropertyCount > 0 then
      Result := Result + ' { ' + Properties + ' }';
    Exit;
  end;
  if Target.ObjectClass = ocError then
  begin
    if OwnDataValue(FRealm, Target, FRealm.Atom(anStack), Value) and JsIsString(Value) then
      Exit(StringToUtf8(FRealm.Heap, JsAsString(Value)));
    Value := ToStringValue(FRealm, JsObjectValue(Target));
    if Value = JsException then
    begin
      FRealm.Runtime.TakeException;
      Exit('[Error]');
    end;
    Exit(StringToUtf8(FRealm.Heap, JsAsString(Value)));
  end;
  if InspectExtra(FRealm, Target, Extra) then
    Exit(Extra);
  if Seen(Target) then
    Exit('[Circular]');
  if Depth > 2 then
  begin
    if Target.ObjectClass = ocArray then
      Exit('[Array]');
    Name := ConstructorName(Target);
    if (Name = '') or (Name = 'Object') then
      Exit('[Object]');
    Exit('[' + Name + ']');
  end;
  SetLength(FSeen, Length(FSeen) + 1);
  FSeen[High(FSeen)] := Target;
  try
    case Target.ObjectClass of
      ocArray:
        begin
          Length_ := TJsArray(Target).ArrayLength;
          Items := '';
          Count := 0;
          Holes := 0;
          Index := 0;
          while Index < Length_ do
          begin
            if (Index < Target.ElementCount) and (Target.Elements^[Index] <> JsHole) then
              Element := Target.Elements^[Index]
            else if not OwnDataValue(FRealm, Target, JsInteger(Index), Element) then
            begin
              Inc(Holes);
              Inc(Index);
              if (Index < Length_) then
                Continue;
              Element := JsHole;
            end;
            if Holes > 0 then
            begin
              if Count > 0 then
                Items := Items + ', ';
              if Holes = 1 then
                Items := Items + '<1 empty item>'
              else
                Items := Items + '<' + IntToStr(Holes) + ' empty items>';
              Inc(Count);
              Holes := 0;
            end;
            if Element <> JsHole then
            begin
              if Count > 0 then
                Items := Items + ', ';
              Items := Items + Format(Element, Depth + 1, True);
              Inc(Count);
            end;
            Inc(Index);
            if Count >= 100 then
            begin
              Items := Items + ', ... ' + IntToStr(Length_ - Index) + ' more items';
              Break;
            end;
          end;
          Properties := PropertiesText(Target, Depth, True, PropertyCount);
          if PropertyCount > 0 then
          begin
            if Count > 0 then
              Items := Items + ', ';
            Items := Items + Properties;
            Inc(Count);
          end;
          if Count = 0 then
            Exit('[]');
          Exit('[ ' + Items + ' ]');
        end;
      ocMap, ocSet:
        begin
          Entries := nil;
          if Assigned(JsCollectionEntries) then
            JsCollectionEntries(FRealm, Target, Entries);
          Items := '';
          if Target.ObjectClass = ocMap then
          begin
            Index := 0;
            while Index + 1 < Length(Entries) do
            begin
              if Index > 0 then
                Items := Items + ', ';
              Items := Items + Format(Entries[Index], Depth + 1, True) + ' => ' +
                Format(Entries[Index + 1], Depth + 1, True);
              Inc(Index, 2);
            end;
            Count := Length(Entries) div 2;
            Result := 'Map(' + IntToStr(Count) + ') ';
          end
          else
          begin
            for Index := 0 to High(Entries) do
            begin
              if Index > 0 then
                Items := Items + ', ';
              Items := Items + Format(Entries[Index], Depth + 1, True);
            end;
            Count := Length(Entries);
            Result := 'Set(' + IntToStr(Count) + ') ';
          end;
          if Count = 0 then
            Exit(Result + '{}');
          Exit(Result + '{ ' + Items + ' }');
        end;
      ocPromise:
        begin
          Promise := TJsPromise(Target);
          case Promise.State of
            psPending: Exit('Promise { <pending> }');
            psFulfilled: Exit('Promise { ' + Format(Promise.Value, Depth + 1, True) + ' }');
          else
            Exit('Promise { <rejected> ' + Format(Promise.Value, Depth + 1, True) + ' }');
          end;
        end;
      ocNumber, ocString, ocBoolean, ocSymbol, ocBigInt:
        begin
          case Target.ObjectClass of
            ocNumber: Name := 'Number';
            ocString: Name := 'String';
            ocBoolean: Name := 'Boolean';
            ocSymbol: Name := 'Symbol';
          else
            Name := 'BigInt';
          end;
          Exit('[' + Name + ': ' + Format(TJsPrimitiveObject(Target).PrimitiveValue, Depth + 1, True) + ']');
        end;
      ocWeakMap: Exit('WeakMap { <items unknown> }');
      ocWeakSet: Exit('WeakSet { <items unknown> }');
      ocGenerator: Exit('Object [Generator] {}');
      ocAsyncGenerator: Exit('Object [AsyncGenerator] {}');
    end;
    Properties := PropertiesText(Target, Depth, False, PropertyCount);
    Name := ConstructorName(Target);
    if Target.ObjectClass = ocArguments then
      Name := '[Arguments]';
    if (Name = 'Object') then
      Name := '';
    if PropertyCount = 0 then
    begin
      if Name <> '' then
        Exit(Name + ' {}');
      Exit('{}');
    end;
    Result := '{ ' + Properties + ' }';
    if Name <> '' then
      Result := Name + ' ' + Result;
  finally
    SetLength(FSeen, Length(FSeen) - 1);
  end;
end;

function TInspector.Format(Value: TJsValue; Depth: Integer; Nested: Boolean): string;
begin
  if JsIsString(Value) then
  begin
    Result := StringToUtf8(FRealm.Heap, JsAsString(Value));
    if Nested then
      Result := QuoteString(Result);
    Exit;
  end;
  if JsIsDouble(Value) and (DoubleBits(JsAsDouble(Value)) = JsNegativeZeroBits) then
    Exit('-0');
  if JsIsObject(Value) then
    Exit(ObjectText(JsAsObject(Value), Depth));
  Result := ValueToPascal(FRealm, Value);
end;

function InspectValue(R: TJsRealm; Value: TJsValue): string;
var
  Inspector: TInspector;
begin
  Inspector := TInspector.Create(R);
  try
    Result := Inspector.Format(Value, 0, False);
  finally
    Inspector.Free;
  end;
end;

function InspectNested(R: TJsRealm; Value: TJsValue): string;
var
  Inspector: TInspector;
begin
  Inspector := TInspector.Create(R);
  try
    Result := Inspector.Format(Value, 0, True);
  finally
    Inspector.Free;
  end;
end;

end.

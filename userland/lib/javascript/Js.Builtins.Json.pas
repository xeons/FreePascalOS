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
  JSON: parse (with a reviver) and stringify (with a replacer function
  or property list, indentation, toJSON, cycle detection).
}
unit Js.Builtins.Json;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.BigIntegers,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter;

procedure InstallJson(R: TJsInterpreterRealm);
{ JSON.parse of a string value (a SyntaxError thrown when it is not
  JSON). }
function ParseJsonText(R: TJsRealm; Text: TJsValue): TJsValue;

implementation

type
  TUnits = record
    Data: array of Word;
    Count: Integer;
  end;

procedure Put(var Units: TUnits; Value: Word); inline;
begin
  if Units.Count >= Length(Units.Data) then
    SetLength(Units.Data, Length(Units.Data) * 2 + 64);
  Units.Data[Units.Count] := Value;
  Inc(Units.Count);
end;

procedure PutAscii(var Units: TUnits; const Text: string);
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
    Put(Units, Byte(Text[Index]));
end;

procedure PutString(var Units: TUnits; Text: TJsString);
var
  Index: Integer;
begin
  for Index := 0 to Text.Length - 1 do
    Put(Units, Text.CharAt(Index));
end;

{ Parsing }

type
  TJsonParser = record
    Realm: TJsRealm;
    Text: TJsString;
    Position: Integer;
    Depth: Integer;
  end;

function Fail(var Parser: TJsonParser; const Message: string): TJsValue;
var
  Shown: string;
begin
  if Parser.Position >= Parser.Text.Length then
    Shown := 'Unexpected end of JSON input'
  else
    Shown := 'Unexpected token ' + StringToUtf8(Parser.Realm.Heap, SubString(Parser.Realm.Heap, Parser.Text,
      Parser.Position, 1)) + ' in JSON at position ' + IntToStr(Parser.Position);
  if Message <> '' then
    Shown := Message + ' at position ' + IntToStr(Parser.Position);
  Result := Parser.Realm.ThrowError(ekSyntax, Shown);
end;

procedure SkipSpace(var Parser: TJsonParser);
var
  Code: Word;
begin
  while Parser.Position < Parser.Text.Length do
  begin
    Code := Parser.Text.CharAt(Parser.Position);
    if (Code = 32) or (Code = 9) or (Code = 10) or (Code = 13) then
      Inc(Parser.Position)
    else
      Break;
  end;
end;

function Current(var Parser: TJsonParser): Integer; inline;
begin
  if Parser.Position < Parser.Text.Length then
    Result := Parser.Text.CharAt(Parser.Position)
  else
    Result := -1;
end;

function ParseString(var Parser: TJsonParser): TJsValue;
var
  Units: TUnits;
  Code: Integer;
  Value, Index, Digit: Integer;
  Start: Integer;
  Plain: Boolean;
begin
  Inc(Parser.Position);
  Start := Parser.Position;
  Plain := True;
  Units.Data := nil;
  Units.Count := 0;
  while True do
  begin
    Code := Current(Parser);
    if Code < 0 then
      Exit(Fail(Parser, 'Unterminated string in JSON'));
    if Code = Ord('"') then
      Break;
    if Code < 32 then
      Exit(Fail(Parser, 'Bad control character in string literal in JSON'));
    if Code = Ord('\') then
    begin
      if Plain then
      begin
        for Index := Start to Parser.Position - 1 do
          Put(Units, Parser.Text.CharAt(Index));
        Plain := False;
      end;
      Inc(Parser.Position);
      Code := Current(Parser);
      case Code of
        Ord('"'): Put(Units, Ord('"'));
        Ord('\'): Put(Units, Ord('\'));
        Ord('/'): Put(Units, Ord('/'));
        Ord('b'): Put(Units, 8);
        Ord('f'): Put(Units, 12);
        Ord('n'): Put(Units, 10);
        Ord('r'): Put(Units, 13);
        Ord('t'): Put(Units, 9);
        Ord('u'):
          begin
            Value := 0;
            for Index := 1 to 4 do
            begin
              Inc(Parser.Position);
              Code := Current(Parser);
              case Code of
                Ord('0')..Ord('9'): Digit := Code - Ord('0');
                Ord('a')..Ord('f'): Digit := Code - Ord('a') + 10;
                Ord('A')..Ord('F'): Digit := Code - Ord('A') + 10;
              else
                Exit(Fail(Parser, 'Bad Unicode escape in JSON'));
              end;
              Value := Value * 16 + Digit;
            end;
            Put(Units, Value);
          end;
      else
        Exit(Fail(Parser, 'Bad escaped character in JSON'));
      end;
      Inc(Parser.Position);
      Continue;
    end;
    if not Plain then
      Put(Units, Code);
    Inc(Parser.Position);
  end;
  if Plain then
    Result := JsStringValue(SubString(Parser.Realm.Heap, Parser.Text, Start, Parser.Position - Start))
  else if Units.Count = 0 then
    Result := Parser.Realm.Atom(anEmpty)
  else
    Result := JsStringValue(NewUtf16String(Parser.Realm.Heap, @Units.Data[0], Units.Count));
  Inc(Parser.Position);
end;

function ParseNumber(var Parser: TJsonParser): TJsValue;
var
  Start: Integer;
  Text: string;
  Index: Integer;

  procedure Digits;
  begin
    while (Current(Parser) >= Ord('0')) and (Current(Parser) <= Ord('9')) do
      Inc(Parser.Position);
  end;

begin
  Start := Parser.Position;
  if Current(Parser) = Ord('-') then
    Inc(Parser.Position);
  if Current(Parser) = Ord('0') then
    Inc(Parser.Position)
  else if (Current(Parser) >= Ord('1')) and (Current(Parser) <= Ord('9')) then
    Digits
  else
    Exit(Fail(Parser, ''));
  if Current(Parser) = Ord('.') then
  begin
    Inc(Parser.Position);
    if not ((Current(Parser) >= Ord('0')) and (Current(Parser) <= Ord('9'))) then
      Exit(Fail(Parser, ''));
    Digits;
  end;
  if (Current(Parser) = Ord('e')) or (Current(Parser) = Ord('E')) then
  begin
    Inc(Parser.Position);
    if (Current(Parser) = Ord('+')) or (Current(Parser) = Ord('-')) then
      Inc(Parser.Position);
    if not ((Current(Parser) >= Ord('0')) and (Current(Parser) <= Ord('9'))) then
      Exit(Fail(Parser, ''));
    Digits;
  end;
  Text := '';
  SetLength(Text, Parser.Position - Start);
  for Index := Start to Parser.Position - 1 do
    Text[Index - Start + 1] := Char(Parser.Text.CharAt(Index));
  Result := JsNumber(TextToNumber(Text));
end;

function MatchWord(var Parser: TJsonParser; const Word: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Word) do
    if (Parser.Position + Index - 1 >= Parser.Text.Length) or
      (Parser.Text.CharAt(Parser.Position + Index - 1) <> Ord(Word[Index])) then
      Exit(False);
  Inc(Parser.Position, Length(Word));
  Result := True;
end;

function ParseValue(var Parser: TJsonParser): TJsValue;
var
  Target: TJsObject;
  Created: TJsArray;
  Key, Value: TJsValue;
  Mark: Integer;
begin
  SkipSpace(Parser);
  Inc(Parser.Depth);
  if Parser.Depth > 5000 then
    Exit(Parser.Realm.ThrowRangeError('JSON nesting too deep'));
  try
    case Current(Parser) of
      Ord('{'):
        begin
          Inc(Parser.Position);
          Target := Parser.Realm.NewPlainObject;
          Mark := Parser.Realm.Runtime.PushRoot(JsObjectValue(Target));
          try
            SkipSpace(Parser);
            if Current(Parser) = Ord('}') then
            begin
              Inc(Parser.Position);
              Exit(JsObjectValue(Target));
            end;
            while True do
            begin
              SkipSpace(Parser);
              if Current(Parser) <> Ord('"') then
                Exit(Fail(Parser, ''));
              Key := ParseString(Parser);
              if Key = JsException then
                Exit(JsException);
              SkipSpace(Parser);
              if Current(Parser) <> Ord(':') then
                Exit(Fail(Parser, ''));
              Inc(Parser.Position);
              Value := ParseValue(Parser);
              if Value = JsException then
                Exit(JsException);
              Key := ToPropertyKey(Parser.Realm, Key);
              Target.CreateDataProperty(Parser.Realm, Key, Value);
              SkipSpace(Parser);
              if Current(Parser) = Ord(',') then
              begin
                Inc(Parser.Position);
                Continue;
              end;
              if Current(Parser) = Ord('}') then
              begin
                Inc(Parser.Position);
                Break;
              end;
              Exit(Fail(Parser, ''));
            end;
            Result := JsObjectValue(Target);
          finally
            Parser.Realm.Runtime.PopRoots(Mark);
          end;
        end;
      Ord('['):
        begin
          Inc(Parser.Position);
          Created := Parser.Realm.NewArray(0);
          Mark := Parser.Realm.Runtime.PushRoot(JsObjectValue(Created));
          try
            SkipSpace(Parser);
            if Current(Parser) = Ord(']') then
            begin
              Inc(Parser.Position);
              Exit(JsObjectValue(Created));
            end;
            while True do
            begin
              Value := ParseValue(Parser);
              if Value = JsException then
                Exit(JsException);
              Created.CreateDataProperty(Parser.Realm, JsInteger(Created.ArrayLength), Value);
              SkipSpace(Parser);
              if Current(Parser) = Ord(',') then
              begin
                Inc(Parser.Position);
                Continue;
              end;
              if Current(Parser) = Ord(']') then
              begin
                Inc(Parser.Position);
                Break;
              end;
              Exit(Fail(Parser, ''));
            end;
            Result := JsObjectValue(Created);
          finally
            Parser.Realm.Runtime.PopRoots(Mark);
          end;
        end;
      Ord('"'):
        Result := ParseString(Parser);
      Ord('-'), Ord('0')..Ord('9'):
        Result := ParseNumber(Parser);
      Ord('t'):
        if MatchWord(Parser, 'true') then
          Result := JsTrue
        else
          Result := Fail(Parser, '');
      Ord('f'):
        if MatchWord(Parser, 'false') then
          Result := JsFalse
        else
          Result := Fail(Parser, '');
      Ord('n'):
        if MatchWord(Parser, 'null') then
          Result := JsNull
        else
          Result := Fail(Parser, '');
    else
      Result := Fail(Parser, '');
    end;
  finally
    Dec(Parser.Depth);
  end;
end;

function Internalize(R: TJsRealm; Holder: TJsObject; Key: TJsValue; Reviver: TJsValue): TJsValue;
var
  Value, Element, Revived: TJsValue;
  Target: TJsObject;
  Length, Index: Int64;
  Keys: TJsValueList;
  KeyIndex, Mark: Integer;
  Pair: array[0..1] of TJsValue;
  Desc: TJsPropertyDescriptor;
begin
  Value := Holder.GetValue(R, Key);
  if Value = JsException then
    Exit(JsException);
  if JsIsObject(Value) then
  begin
    Target := JsAsObject(Value);
    Mark := R.Runtime.PushRoot(Value);
    try
      if Target.ObjectClass = ocArray then
      begin
        if not LengthOfArrayLike(R, Target, Length) then
          Exit(JsException);
        for Index := 0 to Length - 1 do
        begin
          Element := Internalize(R, Target, IndexKey(R, Index), Reviver);
          if Element = JsException then
            Exit(JsException);
          if Element = JsUndefined then
            Target.DeleteProperty(R, IndexKey(R, Index))
          else
            Target.CreateDataProperty(R, IndexKey(R, Index), Element);
        end;
      end
      else
      begin
        if not Target.OwnPropertyKeys(R, KeysStrings, Keys) then
          Exit(JsException);
        for KeyIndex := 0 to High(Keys) do
        begin
          if Target.GetOwnProperty(R, Keys[KeyIndex], Desc) <= 0 then
            Continue;
          if (Desc.Flags and PropertyEnumerable) = 0 then
            Continue;
          Element := Internalize(R, Target, Keys[KeyIndex], Reviver);
          if Element = JsException then
            Exit(JsException);
          if Element = JsUndefined then
            Target.DeleteProperty(R, Keys[KeyIndex])
          else
            Target.CreateDataProperty(R, Keys[KeyIndex], Element);
        end;
      end;
    finally
      R.Runtime.PopRoots(Mark);
    end;
  end;
  Pair[0] := KeyToStringValue(R, Key);
  Pair[1] := Value;
  Revived := R.Call(Reviver, JsObjectValue(Holder), @Pair[0], 2);
  Result := Revived;
end;

function JsonParse(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Parser: TJsonParser;
  Text: TJsString;
  Root: TJsObject;
  Mark: Integer;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Parser.Realm := R;
  Parser.Text := Text;
  Parser.Position := 0;
  Parser.Depth := 0;
  Mark := R.Runtime.PushRoot(JsStringValue(Text));
  try
    Result := ParseValue(Parser);
    if Result = JsException then
      Exit;
    SkipSpace(Parser);
    if Parser.Position < Text.Length then
      Exit(Fail(Parser, ''));
    if JsIsCallable(Arg(Args, ArgCount, 1)) then
    begin
      Root := R.NewPlainObject;
      Root.CreateDataProperty(R, R.Atom(anEmpty), Result);
      R.Runtime.PushRoot(JsObjectValue(Root));
      Result := Internalize(R, Root, R.Atom(anEmpty), Args^[1]);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ParseJsonText(R: TJsRealm; Text: TJsValue): TJsValue;
begin
  Result := JsonParse(R, JsUndefined, PJsValueArray(@Text), 1, nil, JsUndefined);
end;

{ Stringifying }

type
  TJsonWriter = record
    Realm: TJsRealm;
    Output: TUnits;
    Replacer: TJsValue;
    PropertyList: TJsValueList;
    HasPropertyList: Boolean;
    Gap: string;
    Indent: string;
    Stack: array of TJsObject;
  end;

procedure QuoteJson(var Writer: TJsonWriter; Text: TJsString);
const
  Hex = '0123456789abcdef';
var
  Index: Integer;
  Code, Next: Word;
begin
  Text.Flatten(Writer.Realm.Heap);
  Put(Writer.Output, Ord('"'));
  Index := 0;
  while Index < Text.Length do
  begin
    Code := Text.CharAt(Index);
    case Code of
      Ord('"'): PutAscii(Writer.Output, '\"');
      Ord('\'): PutAscii(Writer.Output, '\\');
      8: PutAscii(Writer.Output, '\b');
      12: PutAscii(Writer.Output, '\f');
      10: PutAscii(Writer.Output, '\n');
      13: PutAscii(Writer.Output, '\r');
      9: PutAscii(Writer.Output, '\t');
    else
      if (Code < 32) then
        PutAscii(Writer.Output, '\u00' + Hex[(Code shr 4) + 1] + Hex[(Code and 15) + 1])
      else if (Code >= $D800) and (Code <= $DFFF) then
      begin
        Next := 0;
        if Index + 1 < Text.Length then
          Next := Text.CharAt(Index + 1);
        if (Code <= $DBFF) and (Next >= $DC00) and (Next <= $DFFF) then
        begin
          Put(Writer.Output, Code);
          Put(Writer.Output, Next);
          Inc(Index);
        end
        else
          PutAscii(Writer.Output, '\u' + Hex[(Code shr 12) + 1] + Hex[((Code shr 8) and 15) + 1] +
            Hex[((Code shr 4) and 15) + 1] + Hex[(Code and 15) + 1]);
      end
      else
        Put(Writer.Output, Code);
    end;
    Inc(Index);
  end;
  Put(Writer.Output, Ord('"'));
end;

{ Writes the value of Holder[Key]; Wrote False when nothing is written
  (undefined, functions, symbols). False when it threw. }
function SerializeProperty(var Writer: TJsonWriter; Holder: TJsObject; Key: TJsValue; Value: TJsValue;
  out Wrote: Boolean): Boolean; forward;

procedure NewLine(var Writer: TJsonWriter);
begin
  Put(Writer.Output, 10);
  PutAscii(Writer.Output, Writer.Indent);
end;

function SerializeObject(var Writer: TJsonWriter; Target: TJsObject): Boolean;
var
  Keys: TJsValueList;
  Index, Position, Mark: Integer;
  Stepback: string;
  Desc: TJsPropertyDescriptor;
  First, Wrote: Boolean;
  Value: TJsValue;
  KeyText: TJsValue;
  SavedCount: Integer;
begin
  for Index := 0 to High(Writer.Stack) do
    if Writer.Stack[Index] = Target then
    begin
      Writer.Realm.ThrowTypeError('Converting circular structure to JSON');
      Exit(False);
    end;
  SetLength(Writer.Stack, Length(Writer.Stack) + 1);
  Writer.Stack[High(Writer.Stack)] := Target;
  Stepback := Writer.Indent;
  Writer.Indent := Writer.Indent + Writer.Gap;
  Mark := Writer.Realm.Runtime.PushRoot(JsObjectValue(Target));
  try
    if Writer.HasPropertyList then
      Keys := Copy(Writer.PropertyList)
    else
    begin
      if not Target.OwnPropertyKeys(Writer.Realm, KeysStrings, Keys) then
        Exit(False);
      Position := 0;
      for Index := 0 to High(Keys) do
      begin
        if Target.GetOwnProperty(Writer.Realm, Keys[Index], Desc) <= 0 then
          Continue;
        if (Desc.Flags and PropertyEnumerable) = 0 then
          Continue;
        Keys[Position] := Keys[Index];
        Inc(Position);
      end;
      SetLength(Keys, Position);
    end;
    Put(Writer.Output, Ord('{'));
    First := True;
    for Index := 0 to High(Keys) do
    begin
      Value := Target.GetValue(Writer.Realm, Keys[Index]);
      if Value = JsException then
        Exit(False);
      SavedCount := Writer.Output.Count;
      if not First then
        Put(Writer.Output, Ord(','));
      if Writer.Gap <> '' then
        NewLine(Writer);
      KeyText := KeyToStringValue(Writer.Realm, Keys[Index]);
      QuoteJson(Writer, JsAsString(KeyText));
      Put(Writer.Output, Ord(':'));
      if Writer.Gap <> '' then
        Put(Writer.Output, Ord(' '));
      if not SerializeProperty(Writer, Target, Keys[Index], Value, Wrote) then
        Exit(False);
      if not Wrote then
        Writer.Output.Count := SavedCount
      else
        First := False;
    end;
    if (not First) and (Writer.Gap <> '') then
    begin
      Writer.Indent := Stepback;
      NewLine(Writer);
    end;
    Put(Writer.Output, Ord('}'));
    Result := True;
  finally
    Writer.Realm.Runtime.PopRoots(Mark);
    Writer.Indent := Stepback;
    SetLength(Writer.Stack, Length(Writer.Stack) - 1);
  end;
end;

function SerializeArray(var Writer: TJsonWriter; Target: TJsObject): Boolean;
var
  Index: Integer;
  Length: Int64;
  Stepback: string;
  Value: TJsValue;
  Wrote: Boolean;
  Position, Mark: Integer;
begin
  for Index := 0 to High(Writer.Stack) do
    if Writer.Stack[Index] = Target then
    begin
      Writer.Realm.ThrowTypeError('Converting circular structure to JSON');
      Exit(False);
    end;
  SetLength(Writer.Stack, System.Length(Writer.Stack) + 1);
  Writer.Stack[High(Writer.Stack)] := Target;
  Stepback := Writer.Indent;
  Writer.Indent := Writer.Indent + Writer.Gap;
  Mark := Writer.Realm.Runtime.PushRoot(JsObjectValue(Target));
  try
    if not LengthOfArrayLike(Writer.Realm, Target, Length) then
      Exit(False);
    Put(Writer.Output, Ord('['));
    for Position := 0 to Length - 1 do
    begin
      if Position > 0 then
        Put(Writer.Output, Ord(','));
      if Writer.Gap <> '' then
        NewLine(Writer);
      Value := Target.GetValue(Writer.Realm, IndexKey(Writer.Realm, Position));
      if Value = JsException then
        Exit(False);
      if not SerializeProperty(Writer, Target, IndexKey(Writer.Realm, Position), Value, Wrote) then
        Exit(False);
      if not Wrote then
        PutAscii(Writer.Output, 'null');
    end;
    if (Length > 0) and (Writer.Gap <> '') then
    begin
      Writer.Indent := Stepback;
      NewLine(Writer);
    end;
    Put(Writer.Output, Ord(']'));
    Result := True;
  finally
    Writer.Realm.Runtime.PopRoots(Mark);
    Writer.Indent := Stepback;
    SetLength(Writer.Stack, System.Length(Writer.Stack) - 1);
  end;
end;

function SerializeProperty(var Writer: TJsonWriter; Holder: TJsObject; Key: TJsValue; Value: TJsValue;
  out Wrote: Boolean): Boolean;
var
  R: TJsRealm;
  ToJson: TJsValue;
  Pair: array[0..1] of TJsValue;
  Target: TJsObject;
  Text: TJsString;
  Number: Double;
  Mark: Integer;
begin
  R := Writer.Realm;
  Wrote := False;
  Result := False;
  Mark := R.Runtime.PushRoot(Value);
  try
    if JsIsObject(Value) or JsIsBigInt(Value) then
    begin
      ToJson := GetPropertyByKey(R, Value, R.Atom(anToJSON));
      if ToJson = JsException then
        Exit;
      if JsIsCallable(ToJson) then
      begin
        Pair[0] := KeyToStringValue(R, Key);
        Value := R.Call(ToJson, Value, @Pair[0], 1);
        if Value = JsException then
          Exit;
        R.Runtime.SetRoot(Mark, Value);
      end;
    end;
    if Writer.Replacer <> JsUndefined then
    begin
      Pair[0] := KeyToStringValue(R, Key);
      Pair[1] := Value;
      Value := R.Call(Writer.Replacer, JsObjectValue(Holder), @Pair[0], 2);
      if Value = JsException then
        Exit;
      R.Runtime.SetRoot(Mark, Value);
    end;
    if JsIsObject(Value) then
    begin
      Target := JsAsObject(Value);
      case Target.ObjectClass of
        ocNumber:
          begin
            if not ToDouble(R, Value, Number) then
              Exit;
            Value := JsNumber(Number);
          end;
        ocString:
          begin
            Text := ToJsString(R, Value);
            if Text = nil then
              Exit;
            Value := JsStringValue(Text);
          end;
        ocBoolean, ocBigInt:
          Value := TJsPrimitiveObject(Target).PrimitiveValue;
      end;
    end;
    case Value of
      JsNull:
        begin
          PutAscii(Writer.Output, 'null');
          Wrote := True;
          Exit(True);
        end;
      JsTrue:
        begin
          PutAscii(Writer.Output, 'true');
          Wrote := True;
          Exit(True);
        end;
      JsFalse:
        begin
          PutAscii(Writer.Output, 'false');
          Wrote := True;
          Exit(True);
        end;
    end;
    if JsIsString(Value) then
    begin
      QuoteJson(Writer, JsAsString(Value));
      Wrote := True;
      Exit(True);
    end;
    if JsIsNumber(Value) then
    begin
      Number := JsNumberValue(Value);
      if IsFiniteDouble(Number) and not IsNaNDouble(Number) then
        PutAscii(Writer.Output, NumberToString(Number))
      else
        PutAscii(Writer.Output, 'null');
      Wrote := True;
      Exit(True);
    end;
    if JsIsBigInt(Value) then
    begin
      R.ThrowTypeError('Do not know how to serialize a BigInt');
      Exit;
    end;
    if JsIsObject(Value) and not JsIsCallable(Value) then
    begin
      Target := JsAsObject(Value);
      if Target.ObjectClass = ocArray then
        Result := SerializeArray(Writer, Target)
      else
        Result := SerializeObject(Writer, Target);
      Wrote := Result;
      Exit;
    end;
    Result := True;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function JsonStringify(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Writer: TJsonWriter;
  Replacer, Space, Item: TJsValue;
  Length, Index: Int64;
  Number: Double;
  Text: TJsString;
  Wrapper: TJsObject;
  Wrote, Duplicate: Boolean;
  Position, Mark: Integer;
begin
  Writer.Realm := R;
  Writer.Output.Data := nil;
  Writer.Output.Count := 0;
  Writer.Replacer := JsUndefined;
  Writer.PropertyList := nil;
  Writer.HasPropertyList := False;
  Writer.Gap := '';
  Writer.Indent := '';
  Writer.Stack := nil;
  Replacer := Arg(Args, ArgCount, 1);
  if JsIsCallable(Replacer) then
    Writer.Replacer := Replacer
  else if JsIsObject(Replacer) and (JsAsObject(Replacer).ObjectClass = ocArray) then
  begin
    Writer.HasPropertyList := True;
    if not LengthOfArrayLike(R, JsAsObject(Replacer), Length) then
      Exit(JsException);
    for Index := 0 to Length - 1 do
    begin
      Item := JsAsObject(Replacer).GetValue(R, IndexKey(R, Index));
      if Item = JsException then
        Exit(JsException);
      if JsIsString(Item) or JsIsNumber(Item) or (JsIsObject(Item) and
        (JsAsObject(Item).ObjectClass in [ocString, ocNumber])) then
      begin
        Item := ToPropertyKey(R, Item);
        if Item = JsException then
          Exit(JsException);
        Duplicate := False;
        for Position := 0 to High(Writer.PropertyList) do
          if Writer.PropertyList[Position] = Item then
            Duplicate := True;
        if not Duplicate then
        begin
          SetLength(Writer.PropertyList, System.Length(Writer.PropertyList) + 1);
          Writer.PropertyList[High(Writer.PropertyList)] := Item;
        end;
      end;
    end;
  end;
  Space := Arg(Args, ArgCount, 2);
  if JsIsObject(Space) then
  begin
    if JsAsObject(Space).ObjectClass = ocNumber then
    begin
      if not ToDouble(R, Space, Number) then
        Exit(JsException);
      Space := JsNumber(Number);
    end
    else if JsAsObject(Space).ObjectClass = ocString then
    begin
      Text := ToJsString(R, Space);
      if Text = nil then
        Exit(JsException);
      Space := JsStringValue(Text);
    end;
  end;
  if JsIsNumber(Space) then
  begin
    Number := Min(10, JsNumberValue(Space));
    if Number >= 1 then
      Writer.Gap := StringOfChar(' ', Trunc(Number));
  end
  else if JsIsString(Space) then
    Writer.Gap := Copy(StringToUtf8(R.Heap, JsAsString(Space)), 1, 10);
  Wrapper := R.NewPlainObject;
  Wrapper.CreateDataProperty(R, R.Atom(anEmpty), Arg(Args, ArgCount, 0));
  Mark := R.Runtime.PushRoot(JsObjectValue(Wrapper));
  try
    if not SerializeProperty(Writer, Wrapper, R.Atom(anEmpty), Arg(Args, ArgCount, 0), Wrote) then
      Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  if not Wrote then
    Exit(JsUndefined);
  if Writer.Output.Count = 0 then
    Exit(R.Atom(anEmpty));
  Result := JsStringValue(NewUtf16String(R.Heap, @Writer.Output.Data[0], Writer.Output.Count));
end;

procedure InstallJson(R: TJsInterpreterRealm);
var
  Json: TJsObject;
begin
  Json := R.NewPlainObject;
  DefineValue(R, R.GlobalObject, 'JSON', JsObjectValue(Json));
  DefineMethod(R, Json, 'parse', @JsonParse, 2);
  DefineMethod(R, Json, 'stringify', @JsonStringify, 3);
  Json.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('JSON'), PropertyConfigurable);
end;

end.

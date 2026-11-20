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
  String: the constructor, String.fromCharCode / fromCodePoint / raw,
  and String.prototype.

  match, matchAll, replace, replaceAll, search and split hand a pattern
  object to its Symbol.match... method (RegExp's); with a string
  pattern they work here. Case mapping uses the Unicode tables of the
  runtime library; normalize uses Js.Normalization.
}
unit Js.Builtins.Strings;

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
  Js.Conversions,
  Js.Operations,
  Js.Interpreter,
  Js.Builtins.Iterators;

procedure InstallString(R: TJsInterpreterRealm);
{ GetSubstitution: the replacement text with $ patterns expanded.
  Captures holds the groups (undefined for a group that did not take
  part); NamedGroups is undefined or an object. }
function GetSubstitution(R: TJsRealm; Matched, Text: TJsString; Position: Integer; const Captures: TJsValueList;
  NamedGroups: TJsValue; Replacement: TJsString): TJsString;

implementation

uses
  Character,
  Js.Normalization;

function ThisString(R: TJsRealm; This: TJsValue; const Name: string): TJsString;
begin
  if JsIsString(This) then
  begin
    Result := JsAsString(This);
    Result.Flatten(R.Heap);
    Exit;
  end;
  if JsIsNullish(This) then
  begin
    R.ThrowTypeError('String.prototype.' + Name + ' called on null or undefined');
    Exit(nil);
  end;
  Result := ToJsString(R, This);
  if Result <> nil then
    Result.Flatten(R.Heap);
end;

function ArgumentString(R: TJsRealm; Args: PJsValueArray; ArgCount, Index: Integer): TJsString;
begin
  Result := ToJsString(R, Arg(Args, ArgCount, Index));
  if Result <> nil then
    Result.Flatten(R.Heap);
end;

{ Builder for strings made unit by unit. }
type
  TUnitBuilder = record
    Units: array of Word;
    Count: Integer;
  end;

procedure AddUnit(var Builder: TUnitBuilder; Value: Word); inline;
begin
  if Builder.Count >= Length(Builder.Units) then
    SetLength(Builder.Units, Length(Builder.Units) * 2 + 16);
  Builder.Units[Builder.Count] := Value;
  Inc(Builder.Count);
end;

procedure AddString(var Builder: TUnitBuilder; Text: TJsString; Start, Count: Integer);
var
  Index: Integer;
begin
  if Builder.Count + Count > Length(Builder.Units) then
    SetLength(Builder.Units, (Builder.Count + Count) * 2 + 16);
  for Index := 0 to Count - 1 do
    Builder.Units[Builder.Count + Index] := Text.CharAt(Start + Index);
  Inc(Builder.Count, Count);
end;

function BuildString(R: TJsRealm; const Builder: TUnitBuilder): TJsString;
begin
  if Builder.Count = 0 then
    Exit(R.Runtime.EmptyString);
  Result := NewUtf16String(R.Heap, @Builder.Units[0], Builder.Count);
end;

{ The constructor and statics }

function StringConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Wrapper: TJsPrimitiveObject;
  Prototype: TJsObject;
begin
  if ArgCount = 0 then
    Text := R.Runtime.EmptyString
  else if (NewTarget = JsUndefined) and JsIsSymbol(Args^[0]) then
    Text := NewStringFromUtf8(R.Heap, KeyToPascal(R, Args^[0]))
  else
  begin
    Text := ToJsString(R, Args^[0]);
    if Text = nil then
      Exit(JsException);
  end;
  if NewTarget = JsUndefined then
    Exit(JsStringValue(Text));
  Prototype := PrototypeFromConstructor(R, NewTarget, inStringPrototype);
  if Prototype = nil then
    Exit(JsException);
  Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, Prototype, ocString));
  Wrapper.ObjectFlags := Wrapper.ObjectFlags or ObjectExotic;
  Wrapper.PrimitiveValue := JsStringValue(Text);
  Result := JsObjectValue(Wrapper);
end;

function StringFromCharCode(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Builder: TUnitBuilder;
  Index: Integer;
  Unsigned: LongWord;
begin
  if (ArgCount = 1) and JsIsInteger(Args^[0]) then
    Exit(JsStringValue(R.Runtime.CharacterString(Word(JsAsInteger(Args^[0])))));
  Builder.Units := nil;
  Builder.Count := 0;
  for Index := 0 to ArgCount - 1 do
  begin
    if not ToUint32(R, Args^[Index], Unsigned) then
      Exit(JsException);
    AddUnit(Builder, Word(Unsigned));
  end;
  Result := JsStringValue(BuildString(R, Builder));
end;

function StringFromCodePoint(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Builder: TUnitBuilder;
  Index: Integer;
  Number: Double;
  CodePoint: LongWord;
begin
  Builder.Units := nil;
  Builder.Count := 0;
  for Index := 0 to ArgCount - 1 do
  begin
    if not ToDouble(R, Args^[Index], Number) then
      Exit(JsException);
    if (Number < 0) or (Number > $10FFFF) or (Int(Number) <> Number) then
      Exit(R.ThrowRangeError('Invalid code point ' + NumberToString(Number)));
    CodePoint := Trunc(Number);
    if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      AddUnit(Builder, $D800 + (CodePoint shr 10));
      AddUnit(Builder, $DC00 + (CodePoint and $3FF));
    end
    else
      AddUnit(Builder, CodePoint);
  end;
  Result := JsStringValue(BuildString(R, Builder));
end;

function StringRaw(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Cooked, Raw, Piece: TJsValue;
  Length: Int64;
  Index: Int64;
  Outcome, Text: TJsString;
begin
  Cooked := ToObject(R, Arg(Args, ArgCount, 0));
  if Cooked = JsException then
    Exit(JsException);
  Raw := JsAsObject(Cooked).GetValue(R, R.Atom(anRaw));
  if Raw = JsException then
    Exit(JsException);
  Raw := ToObject(R, Raw);
  if Raw = JsException then
    Exit(JsException);
  if not LengthOfArrayLike(R, JsAsObject(Raw), Length) then
    Exit(JsException);
  Outcome := R.Runtime.EmptyString;
  Index := 0;
  while Index < Length do
  begin
    Piece := JsAsObject(Raw).GetValue(R, IndexKey(R, Index));
    if Piece = JsException then
      Exit(JsException);
    Text := ToJsString(R, Piece);
    if Text = nil then
      Exit(JsException);
    Outcome := ConcatStrings(R.Heap, Outcome, Text);
    if (Index + 1 < Length) and (Index + 1 < ArgCount) then
    begin
      Text := ToJsString(R, Args^[Index + 1]);
      if Text = nil then
        Exit(JsException);
      Outcome := ConcatStrings(R.Heap, Outcome, Text);
    end;
    Inc(Index);
  end;
  Result := JsStringValue(Outcome);
end;

{ Characters }

function StringCharAt(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Number: Double;
  Index: Int64;
  First, Second: Word;
begin
  Text := ThisString(R, This, 'charAt');
  if Text = nil then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if Callee.Magic = 3 then
  begin
    { at: relative }
    if Number < 0 then
      Number := Text.Length + Number;
    if (Number < 0) or (Number >= Text.Length) then
      Exit(JsUndefined);
  end
  else if (Number < 0) or (Number >= Text.Length) then
  begin
    case Callee.Magic of
      0: Exit(R.Atom(anEmpty));
    else
      if Callee.Magic = 1 then
        Exit(JsNaN);
      Exit(JsUndefined);
    end;
  end;
  Index := Trunc(Number);
  First := Text.CharAt(Index);
  case Callee.Magic of
    0, 3: Result := JsStringValue(R.Runtime.CharacterString(First));
    1: Result := JsInteger(First);
  else
    if (First >= $D800) and (First <= $DBFF) and (Index + 1 < Text.Length) then
    begin
      Second := Text.CharAt(Index + 1);
      if (Second >= $DC00) and (Second <= $DFFF) then
        Exit(JsInteger($10000 + ((First - $D800) shl 10) + (Second - $DC00)));
    end;
    Result := JsInteger(First);
  end;
end;

function StringConcat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Outcome, Text: TJsString;
  Index: Integer;
begin
  Outcome := ThisString(R, This, 'concat');
  if Outcome = nil then
    Exit(JsException);
  for Index := 0 to ArgCount - 1 do
  begin
    Text := ToJsString(R, Args^[Index]);
    if Text = nil then
      Exit(JsException);
    Outcome := ConcatStrings(R.Heap, Outcome, Text);
    if Outcome = nil then
      Exit(R.ThrowRangeError('Invalid string length'));
  end;
  Result := JsStringValue(Outcome);
end;

function IsRegExpValue(R: TJsRealm; Value: TJsValue; out Outcome: Boolean): Boolean;
var
  Matcher: TJsValue;
begin
  Outcome := False;
  if not JsIsObject(Value) then
    Exit(True);
  Matcher := JsAsObject(Value).GetValue(R, R.Runtime.SymbolValue(wsMatch));
  if Matcher = JsException then
    Exit(False);
  if Matcher <> JsUndefined then
    Outcome := ToBoolean(Matcher)
  else
    Outcome := JsAsObject(Value).ObjectClass = ocRegExp;
  Result := True;
end;

{ startsWith (0), endsWith (1), includes (2) }
function StringStartsWith(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Search: TJsString;
  IsPattern: Boolean;
  Number: Double;
  Position: Integer;
begin
  Text := ThisString(R, This, 'startsWith');
  if Text = nil then
    Exit(JsException);
  if not IsRegExpValue(R, Arg(Args, ArgCount, 0), IsPattern) then
    Exit(JsException);
  if IsPattern then
    Exit(R.ThrowTypeError('First argument must not be a regular expression'));
  Search := ArgumentString(R, Args, ArgCount, 0);
  if Search = nil then
    Exit(JsException);
  if Callee.Magic = 1 then
    Number := Text.Length
  else
    Number := 0;
  if Arg(Args, ArgCount, 1) <> JsUndefined then
    if not ToIntegerOrInfinity(R, Args^[1], Number) then
      Exit(JsException);
  Position := Trunc(Max(0, Min(Number, Text.Length)));
  case Callee.Magic of
    0: Result := JsBoolean(StringRegionEquals(Text, Position, Search));
    1: Result := JsBoolean(StringRegionEquals(Text, Position - Search.Length, Search));
  else
    Result := JsBoolean(StringIndexOf(Text, Search, Position) >= 0);
  end;
end;

{ indexOf (0), lastIndexOf (1) }
function StringIndexOfMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Search: TJsString;
  Number: Double;
  Position: Int64;
begin
  Text := ThisString(R, This, 'indexOf');
  if Text = nil then
    Exit(JsException);
  Search := ArgumentString(R, Args, ArgCount, 0);
  if Search = nil then
    Exit(JsException);
  if Callee.Magic = 0 then
  begin
    if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 1), Number) then
      Exit(JsException);
    Position := Trunc(Max(0, Min(Number, Text.Length)));
    Exit(JsInteger(StringIndexOf(Text, Search, Position)));
  end;
  if not ToDouble(R, Arg(Args, ArgCount, 1), Number) then
    Exit(JsException);
  if IsNaNDouble(Number) then
    Position := Text.Length
  else
    Position := Trunc(Max(0, Min(Int(Number), Text.Length)));
  Result := JsInteger(StringLastIndexOf(Text, Search, Position));
end;

{ slice (0), substring (1), substr (2) }
function StringSlice(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Start, Finish: Int64;
  A, B: Double;
  Swap: Int64;
begin
  Text := ThisString(R, This, 'slice');
  if Text = nil then
    Exit(JsException);
  case Callee.Magic of
    0:
      begin
        if not RelativeIndex(R, Arg(Args, ArgCount, 0), Text.Length, 0, Start) or
          not RelativeIndex(R, Arg(Args, ArgCount, 1), Text.Length, Text.Length, Finish) then
          Exit(JsException);
      end;
    1:
      begin
        if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), A) then
          Exit(JsException);
        B := Text.Length;
        if Arg(Args, ArgCount, 1) <> JsUndefined then
          if not ToIntegerOrInfinity(R, Args^[1], B) then
            Exit(JsException);
        Start := Trunc(Max(0, Min(A, Text.Length)));
        Finish := Trunc(Max(0, Min(B, Text.Length)));
        if Start > Finish then
        begin
          Swap := Start;
          Start := Finish;
          Finish := Swap;
        end;
      end;
  else
    if not RelativeIndex(R, Arg(Args, ArgCount, 0), Text.Length, 0, Start) then
      Exit(JsException);
    B := Text.Length - Start;
    if Arg(Args, ArgCount, 1) <> JsUndefined then
      if not ToIntegerOrInfinity(R, Args^[1], B) then
        Exit(JsException);
    Finish := Start + Trunc(Max(0, Min(B, Text.Length - Start)));
  end;
  if Finish <= Start then
    Exit(R.Atom(anEmpty));
  Result := JsStringValue(SubString(R.Heap, Text, Start, Finish - Start));
end;

{ toLowerCase (0), toUpperCase (1) }
function StringCase(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Outcome: TJsString;
  Index: Integer;
  Code: Word;
  Ascii, Changed: Boolean;
  Unicode: UnicodeString;
begin
  Text := ThisString(R, This, 'toLowerCase');
  if Text = nil then
    Exit(JsException);
  Ascii := True;
  Changed := False;
  for Index := 0 to Text.Length - 1 do
  begin
    Code := Text.CharAt(Index);
    if Code >= 128 then
    begin
      Ascii := False;
      Break;
    end;
    if ((Callee.Magic = 0) and (Code >= Ord('A')) and (Code <= Ord('Z'))) or
      ((Callee.Magic = 1) and (Code >= Ord('a')) and (Code <= Ord('z'))) then
      Changed := True;
  end;
  if Ascii then
  begin
    if not Changed then
      Exit(JsStringValue(Text));
    Outcome := NewBlankString(R.Heap, Text.Length, False);
    for Index := 0 to Text.Length - 1 do
    begin
      Code := Text.CharAt(Index);
      if (Callee.Magic = 0) and (Code >= Ord('A')) and (Code <= Ord('Z')) then
        Inc(Code, 32)
      else if (Callee.Magic = 1) and (Code >= Ord('a')) and (Code <= Ord('z')) then
        Dec(Code, 32);
      Outcome.Chars8[Index] := Code;
    end;
    Exit(JsStringValue(Outcome));
  end;
  Unicode := StringToUnicode(R.Heap, Text);
  if Callee.Magic = 0 then
    Unicode := TCharacter.ToLower(Unicode)
  else
  begin
    Unicode := TCharacter.ToUpper(Unicode);
    Unicode := UnicodeStringReplace(Unicode, #$DF, 'SS', [rfReplaceAll]);
  end;
  Result := JsStringValue(NewStringFromUnicode(R.Heap, Unicode));
end;

{ trim (0), trimStart (1), trimEnd (2) }
function StringTrim(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Start, Finish: Integer;
begin
  Text := ThisString(R, This, 'trim');
  if Text = nil then
    Exit(JsException);
  Start := 0;
  Finish := Text.Length;
  if Callee.Magic <> 2 then
    while (Start < Finish) and IsJsSpace(Text.CharAt(Start)) do
      Inc(Start);
  if Callee.Magic <> 1 then
    while (Finish > Start) and IsJsSpace(Text.CharAt(Finish - 1)) do
      Dec(Finish);
  Result := JsStringValue(SubString(R.Heap, Text, Start, Finish - Start));
end;

{ padStart (0), padEnd (1) }
function StringPad(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Filler: TJsString;
  MaximumLength: Int64;
  Builder: TUnitBuilder;
  FillCount, Index: Int64;
begin
  Text := ThisString(R, This, 'padStart');
  if Text = nil then
    Exit(JsException);
  if not ToLength(R, Arg(Args, ArgCount, 0), MaximumLength) then
    Exit(JsException);
  if MaximumLength <= Text.Length then
    Exit(JsStringValue(Text));
  if Arg(Args, ArgCount, 1) = JsUndefined then
    Filler := JsAsString(R.Intern(' '))
  else
  begin
    Filler := ArgumentString(R, Args, ArgCount, 1);
    if Filler = nil then
      Exit(JsException);
  end;
  if Filler.Length = 0 then
    Exit(JsStringValue(Text));
  if MaximumLength > JsMaximumStringLength then
    Exit(R.ThrowRangeError('Invalid string length'));
  Builder.Units := nil;
  Builder.Count := 0;
  FillCount := MaximumLength - Text.Length;
  if Callee.Magic = 1 then
    AddString(Builder, Text, 0, Text.Length);
  for Index := 0 to FillCount - 1 do
    AddUnit(Builder, Filler.CharAt(Index mod Filler.Length));
  if Callee.Magic = 0 then
    AddString(Builder, Text, 0, Text.Length);
  Result := JsStringValue(BuildString(R, Builder));
end;

function StringRepeat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Outcome: TJsString;
  Number: Double;
  Count, Index: Int64;
  Wide: Boolean;
  Unit_: Integer;
begin
  Text := ThisString(R, This, 'repeat');
  if Text = nil then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if (Number < 0) or not IsFiniteDouble(Number) then
    Exit(R.ThrowRangeError('Invalid count value: ' + NumberToString(Number)));
  Count := Trunc(Number);
  if (Count = 0) or (Text.Length = 0) then
    Exit(R.Atom(anEmpty));
  if Count * Text.Length > JsMaximumStringLength then
    Exit(R.ThrowRangeError('Invalid string length'));
  Wide := Text.IsWide;
  Outcome := NewBlankString(R.Heap, Count * Text.Length, Wide);
  for Index := 0 to Count - 1 do
    if Wide then
      for Unit_ := 0 to Text.Length - 1 do
        Outcome.Chars16[Index * Text.Length + Unit_] := Text.CharAt(Unit_)
    else
      Move(Text.Chars8^, Outcome.Chars8[Index * Text.Length], Text.Length);
  Result := JsStringValue(Outcome);
end;

function SplitByString(R: TJsRealm; Text, Separator: TJsString; Limit: LongWord): TJsValue;
var
  Created: TJsArray;
  Position, Found: Integer;
  Index: Integer;
begin
  Created := R.NewArray(0);
  Result := JsObjectValue(Created);
  if Limit = 0 then
    Exit;
  if Separator.Length = 0 then
  begin
    for Index := 0 to Text.Length - 1 do
    begin
      if Created.ArrayLength >= Limit then
        Break;
      Created.CreateDataProperty(R, JsInteger(Index), JsStringValue(R.Runtime.CharacterString(Text.CharAt(Index))));
    end;
    Exit;
  end;
  Position := 0;
  while True do
  begin
    Found := StringIndexOf(Text, Separator, Position);
    if Found < 0 then
      Break;
    Created.CreateDataProperty(R, JsInteger(Created.ArrayLength),
      JsStringValue(SubString(R.Heap, Text, Position, Found - Position)));
    if Created.ArrayLength >= Limit then
      Exit;
    Position := Found + Separator.Length;
  end;
  Created.CreateDataProperty(R, JsInteger(Created.ArrayLength),
    JsStringValue(SubString(R.Heap, Text, Position, Text.Length - Position)));
end;

{ Delegates to Pattern[Symbol] when the pattern has that method:
  True and Outcome set when it did. }
function Delegate(R: TJsRealm; Pattern: TJsValue; Symbol: TJsWellKnownSymbol; This: TJsValue;
  Args: PJsValue; Count: Integer; out Outcome: TJsValue): Boolean;
var
  Method: TJsValue;
  Values: array[0..2] of TJsValue;
  Index: Integer;
begin
  Outcome := JsUndefined;
  if JsIsNullish(Pattern) or not JsIsObject(Pattern) then
    Exit(False);
  Method := GetMethod(R, Pattern, R.Runtime.SymbolValue(Symbol));
  if Method = JsException then
  begin
    Outcome := JsException;
    Exit(True);
  end;
  if Method = JsUndefined then
    Exit(False);
  Values[0] := This;
  for Index := 0 to Count - 1 do
    Values[Index + 1] := Args[Index];
  Outcome := R.Call(Method, Pattern, @Values[0], Count + 1);
  Result := True;
end;

function StringSplit(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Separator: TJsString;
  Limit: LongWord;
  Extra: TJsValue;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('String.prototype.split called on null or undefined'));
  Extra := Arg(Args, ArgCount, 1);
  if Delegate(R, Arg(Args, ArgCount, 0), wsSplit, This, @Extra, 1, Result) then
    Exit;
  Text := ThisString(R, This, 'split');
  if Text = nil then
    Exit(JsException);
  Limit := High(LongWord);
  if Extra <> JsUndefined then
    if not ToUint32(R, Extra, Limit) then
      Exit(JsException);
  if Arg(Args, ArgCount, 0) = JsUndefined then
  begin
    Result := JsObjectValue(R.NewArray(0));
    if Limit > 0 then
      JsAsObject(Result).CreateDataProperty(R, JsInteger(0), JsStringValue(Text));
    Exit;
  end;
  Separator := ArgumentString(R, Args, ArgCount, 0);
  if Separator = nil then
    Exit(JsException);
  Result := SplitByString(R, Text, Separator, Limit);
end;

function GetSubstitution(R: TJsRealm; Matched, Text: TJsString; Position: Integer; const Captures: TJsValueList;
  NamedGroups: TJsValue; Replacement: TJsString): TJsString;
var
  Builder: TUnitBuilder;
  Index, Digit, Number, TailPosition, Close: Integer;
  Code: Word;
  Capture, GroupName: TJsValue;
  Piece: TJsString;
begin
  Builder.Units := nil;
  Builder.Count := 0;
  Replacement.Flatten(R.Heap);
  Text.Flatten(R.Heap);
  Matched.Flatten(R.Heap);
  Index := 0;
  while Index < Replacement.Length do
  begin
    Code := Replacement.CharAt(Index);
    if (Code <> Ord('$')) or (Index + 1 >= Replacement.Length) then
    begin
      AddUnit(Builder, Code);
      Inc(Index);
      Continue;
    end;
    Code := Replacement.CharAt(Index + 1);
    case Code of
      Ord('$'):
        begin
          AddUnit(Builder, Ord('$'));
          Inc(Index, 2);
        end;
      Ord('&'):
        begin
          AddString(Builder, Matched, 0, Matched.Length);
          Inc(Index, 2);
        end;
      Ord('`'):
        begin
          AddString(Builder, Text, 0, Position);
          Inc(Index, 2);
        end;
      Ord(''''):
        begin
          TailPosition := Min(Position + Matched.Length, Text.Length);
          AddString(Builder, Text, TailPosition, Text.Length - TailPosition);
          Inc(Index, 2);
        end;
      Ord('0')..Ord('9'):
        begin
          Digit := Code - Ord('0');
          Number := Digit;
          Close := Index + 2;
          if (Index + 2 < Replacement.Length) and (Replacement.CharAt(Index + 2) >= Ord('0')) and
            (Replacement.CharAt(Index + 2) <= Ord('9')) and
            (Digit * 10 + Replacement.CharAt(Index + 2) - Ord('0') <= Length(Captures)) and
            (Digit * 10 + Replacement.CharAt(Index + 2) - Ord('0') >= 1) then
          begin
            Number := Digit * 10 + Replacement.CharAt(Index + 2) - Ord('0');
            Close := Index + 3;
          end;
          if (Number >= 1) and (Number <= Length(Captures)) then
          begin
            Capture := Captures[Number - 1];
            if Capture <> JsUndefined then
            begin
              Piece := ToJsString(R, Capture);
              Piece.Flatten(R.Heap);
              AddString(Builder, Piece, 0, Piece.Length);
            end;
            Index := Close;
          end
          else
          begin
            AddUnit(Builder, Ord('$'));
            Inc(Index);
          end;
        end;
      Ord('<'):
        begin
          if NamedGroups = JsUndefined then
          begin
            AddUnit(Builder, Ord('$'));
            Inc(Index);
            Continue;
          end;
          Close := Index + 2;
          while (Close < Replacement.Length) and (Replacement.CharAt(Close) <> Ord('>')) do
            Inc(Close);
          if Close >= Replacement.Length then
          begin
            AddUnit(Builder, Ord('$'));
            Inc(Index);
            Continue;
          end;
          GroupName := JsStringValue(SubString(R.Heap, Replacement, Index + 2, Close - Index - 2));
          Capture := GetProperty(R, NamedGroups, GroupName);
          if (Capture <> JsException) and (Capture <> JsUndefined) then
          begin
            Piece := ToJsString(R, Capture);
            if Piece <> nil then
            begin
              Piece.Flatten(R.Heap);
              AddString(Builder, Piece, 0, Piece.Length);
            end;
          end;
          Index := Close + 1;
        end;
    else
      AddUnit(Builder, Ord('$'));
      Inc(Index);
    end;
  end;
  Result := BuildString(R, Builder);
end;

{ replace (0), replaceAll (1) }
function StringReplace(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Search, Replacement, Piece: TJsString;
  Pattern, Replacer, Flags, Outcome: TJsValue;
  IsPattern: Boolean;
  Positions: array of Integer;
  Count, Position, Found, Index, Previous: Integer;
  Builder: TUnitBuilder;
  Triple: array[0..2] of TJsValue;
  NoCaptures: TJsValueList;
  FlagText: TJsString;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('String.prototype.replace called on null or undefined'));
  Pattern := Arg(Args, ArgCount, 0);
  Replacer := Arg(Args, ArgCount, 1);
  if (Callee.Magic = 1) and JsIsObject(Pattern) then
  begin
    if not IsRegExpValue(R, Pattern, IsPattern) then
      Exit(JsException);
    if IsPattern then
    begin
      Flags := JsAsObject(Pattern).GetValue(R, R.Atom(anFlags));
      if Flags = JsException then
        Exit(JsException);
      if JsIsNullish(Flags) then
        Exit(R.ThrowTypeError('replaceAll called with a non-global RegExp argument'));
      FlagText := ToJsString(R, Flags);
      if FlagText = nil then
        Exit(JsException);
      if StringIndexOf(FlagText, JsAsString(R.Intern('g')), 0) < 0 then
        Exit(R.ThrowTypeError('replaceAll must be called with a global RegExp'));
    end;
  end;
  if Delegate(R, Pattern, wsReplace, This, @Replacer, 1, Outcome) then
    Exit(Outcome);
  Text := ThisString(R, This, 'replace');
  if Text = nil then
    Exit(JsException);
  Search := ArgumentString(R, Args, ArgCount, 0);
  if Search = nil then
    Exit(JsException);
  Replacement := nil;
  if not JsIsCallable(Replacer) then
  begin
    Replacement := ToJsString(R, Replacer);
    if Replacement = nil then
      Exit(JsException);
  end;
  Positions := nil;
  Count := 0;
  Position := 0;
  while True do
  begin
    Found := StringIndexOf(Text, Search, Position);
    if (Found < 0) or (Found > Text.Length) then
      Break;
    SetLength(Positions, Count + 1);
    Positions[Count] := Found;
    Inc(Count);
    if Callee.Magic = 0 then
      Break;
    Position := Found + Max(1, Search.Length);
    if Position > Text.Length then
      Break;
  end;
  if Count = 0 then
    Exit(JsStringValue(Text));
  Builder.Units := nil;
  Builder.Count := 0;
  Previous := 0;
  NoCaptures := nil;
  for Index := 0 to Count - 1 do
  begin
    AddString(Builder, Text, Previous, Positions[Index] - Previous);
    if Replacement = nil then
    begin
      Triple[0] := JsStringValue(Search);
      Triple[1] := JsInteger(Positions[Index]);
      Triple[2] := JsStringValue(Text);
      Outcome := R.Call(Replacer, JsUndefined, @Triple[0], 3);
      if Outcome = JsException then
        Exit(JsException);
      Piece := ToJsString(R, Outcome);
      if Piece = nil then
        Exit(JsException);
    end
    else
      Piece := GetSubstitution(R, Search, Text, Positions[Index], NoCaptures, JsUndefined, Replacement);
    Piece.Flatten(R.Heap);
    AddString(Builder, Piece, 0, Piece.Length);
    Previous := Positions[Index] + Search.Length;
  end;
  AddString(Builder, Text, Previous, Text.Length - Previous);
  Result := JsStringValue(BuildString(R, Builder));
end;

{ match (0), matchAll (1), search (2): with a string pattern a RegExp is
  made from it. }
function StringMatch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Pattern, Created, Flags: TJsValue;
  Symbol: TJsWellKnownSymbol;
  Text: TJsString;
  Values: array[0..1] of TJsValue;
  IsPattern: Boolean;
  FlagText: TJsString;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('String.prototype.match called on null or undefined'));
  Pattern := Arg(Args, ArgCount, 0);
  case Callee.Magic of
    0: Symbol := wsMatch;
    1: Symbol := wsMatchAll;
  else
    Symbol := wsSearch;
  end;
  if (Callee.Magic = 1) and JsIsObject(Pattern) then
  begin
    if not IsRegExpValue(R, Pattern, IsPattern) then
      Exit(JsException);
    if IsPattern then
    begin
      Flags := JsAsObject(Pattern).GetValue(R, R.Atom(anFlags));
      if Flags = JsException then
        Exit(JsException);
      FlagText := ToJsString(R, Flags);
      if FlagText = nil then
        Exit(JsException);
      if StringIndexOf(FlagText, JsAsString(R.Intern('g')), 0) < 0 then
        Exit(R.ThrowTypeError('matchAll must be called with a global RegExp'));
    end;
  end;
  if Delegate(R, Pattern, Symbol, This, nil, 0, Result) then
    Exit;
  Text := ThisString(R, This, 'match');
  if Text = nil then
    Exit(JsException);
  Values[0] := Pattern;
  if Callee.Magic = 1 then
    Values[1] := R.Intern('g')
  else
    Values[1] := JsUndefined;
  Created := R.Construct(JsObjectValue(R.Intrinsics[inRegExp]), @Values[0], 2, JsObjectValue(R.Intrinsics[inRegExp]));
  if Created = JsException then
    Exit(JsException);
  Values[0] := JsStringValue(Text);
  Result := R.Call(GetMethod(R, Created, R.Runtime.SymbolValue(Symbol)), Created, @Values[0], 1);
end;

{ A locale-free collation close to the root locale's for common text:
  letters compare case-insensitively first, then lowercase sorts before
  uppercase, then by code unit. }
function CompareForLocale(R: TJsRealm; Text, Other: TJsString): Integer;
var
  Index, Shorter: Integer;
  A, B: UnicodeString;
  Tie: Integer;
begin
  A := TCharacter.ToLower(StringToUnicode(R.Heap, Text));
  B := TCharacter.ToLower(StringToUnicode(R.Heap, Other));
  Shorter := Length(A);
  if Length(B) < Shorter then
    Shorter := Length(B);
  for Index := 1 to Shorter do
    if A[Index] <> B[Index] then
      Exit(Ord(A[Index]) - Ord(B[Index]));
  if Length(A) <> Length(B) then
    Exit(Length(A) - Length(B));
  Tie := 0;
  Text.Flatten(R.Heap);
  Other.Flatten(R.Heap);
  for Index := 0 to Text.Length - 1 do
    if Text.CharAt(Index) <> Other.CharAt(Index) then
    begin
      { Lowercase first: the larger code unit (lowercase ASCII) wins. }
      Tie := Integer(Other.CharAt(Index)) - Integer(Text.CharAt(Index));
      Break;
    end;
  Result := Tie;
end;

function StringLocaleCompare(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Other: TJsString;
  Comparison: Integer;
begin
  Text := ThisString(R, This, 'localeCompare');
  if Text = nil then
    Exit(JsException);
  Other := ArgumentString(R, Args, ArgCount, 0);
  if Other = nil then
    Exit(JsException);
  Comparison := CompareForLocale(R, Text, Other);
  if Comparison < 0 then
    Result := JsInteger(-1)
  else if Comparison > 0 then
    Result := JsInteger(1)
  else
    Result := JsInteger(0);
end;

function StringNormalize(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Form: TJsString;
  NormalForm: TJsNormalForm;
begin
  Text := ThisString(R, This, 'normalize');
  if Text = nil then
    Exit(JsException);
  NormalForm := nfC;
  if Arg(Args, ArgCount, 0) <> JsUndefined then
  begin
    Form := ArgumentString(R, Args, ArgCount, 0);
    if Form = nil then
      Exit(JsException);
    if StringEqualsAscii(Form, 'NFC') then
      NormalForm := nfC
    else if StringEqualsAscii(Form, 'NFD') then
      NormalForm := nfD
    else if StringEqualsAscii(Form, 'NFKC') then
      NormalForm := nfKC
    else if StringEqualsAscii(Form, 'NFKD') then
      NormalForm := nfKD
    else
      Exit(R.ThrowRangeError('The normalization form should be one of NFC, NFD, NFKC, NFKD.'));
  end;
  Result := JsStringValue(NewStringFromUnicode(R.Heap, NormalizeText(StringToUnicode(R.Heap, Text), NormalForm)));
end;

function StringValueOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if JsIsString(This) then
    Exit(This);
  if JsIsObject(This) and (JsAsObject(This).ObjectClass = ocString) then
    Exit(TJsPrimitiveObject(JsAsObject(This)).PrimitiveValue);
  Result := R.ThrowTypeError('String.prototype.valueOf requires that ''this'' be a String');
end;

function StringIteratorMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
begin
  Text := ThisString(R, This, '[Symbol.iterator]');
  if Text = nil then
    Exit(JsException);
  Result := CreateStringIterator(R, Text);
end;

{ isWellFormed (0), toWellFormed (1) }
function StringWellFormed(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Index: Integer;
  Code, Next: Word;
  Builder: TUnitBuilder;
  Lone: Boolean;
begin
  Text := ThisString(R, This, 'isWellFormed');
  if Text = nil then
    Exit(JsException);
  Builder.Units := nil;
  Builder.Count := 0;
  Lone := False;
  Index := 0;
  while Index < Text.Length do
  begin
    Code := Text.CharAt(Index);
    if (Code >= $D800) and (Code <= $DBFF) and (Index + 1 < Text.Length) then
    begin
      Next := Text.CharAt(Index + 1);
      if (Next >= $DC00) and (Next <= $DFFF) then
      begin
        AddUnit(Builder, Code);
        AddUnit(Builder, Next);
        Inc(Index, 2);
        Continue;
      end;
    end;
    if (Code >= $D800) and (Code <= $DFFF) then
    begin
      Lone := True;
      Code := $FFFD;
    end;
    AddUnit(Builder, Code);
    Inc(Index);
  end;
  if Callee.Magic = 0 then
    Exit(JsBoolean(not Lone));
  if not Lone then
    Exit(JsStringValue(Text));
  Result := JsStringValue(BuildString(R, Builder));
end;

procedure InstallString(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
begin
  Prototype := R.Intrinsics[inStringPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'String', @StringConstructor, 1, Prototype);
  DefineMethod(R, Constructor_, 'fromCharCode', @StringFromCharCode, 1);
  DefineMethod(R, Constructor_, 'fromCodePoint', @StringFromCodePoint, 1);
  DefineMethod(R, Constructor_, 'raw', @StringRaw, 1);
  DefineMethod(R, Prototype, 'charAt', @StringCharAt, 1, 0);
  DefineMethod(R, Prototype, 'charCodeAt', @StringCharAt, 1, 1);
  DefineMethod(R, Prototype, 'codePointAt', @StringCharAt, 1, 2);
  DefineMethod(R, Prototype, 'at', @StringCharAt, 1, 3);
  DefineMethod(R, Prototype, 'concat', @StringConcat, 1);
  DefineMethod(R, Prototype, 'startsWith', @StringStartsWith, 1, 0);
  DefineMethod(R, Prototype, 'endsWith', @StringStartsWith, 1, 1);
  DefineMethod(R, Prototype, 'includes', @StringStartsWith, 1, 2);
  DefineMethod(R, Prototype, 'indexOf', @StringIndexOfMethod, 1, 0);
  DefineMethod(R, Prototype, 'lastIndexOf', @StringIndexOfMethod, 1, 1);
  DefineMethod(R, Prototype, 'slice', @StringSlice, 2, 0);
  DefineMethod(R, Prototype, 'substring', @StringSlice, 2, 1);
  DefineMethod(R, Prototype, 'substr', @StringSlice, 2, 2);
  DefineMethod(R, Prototype, 'toLowerCase', @StringCase, 0, 0);
  DefineMethod(R, Prototype, 'toUpperCase', @StringCase, 0, 1);
  DefineMethod(R, Prototype, 'toLocaleLowerCase', @StringCase, 0, 0);
  DefineMethod(R, Prototype, 'toLocaleUpperCase', @StringCase, 0, 1);
  DefineMethod(R, Prototype, 'trim', @StringTrim, 0, 0);
  DefineMethod(R, Prototype, 'trimStart', @StringTrim, 0, 1);
  DefineMethod(R, Prototype, 'trimEnd', @StringTrim, 0, 2);
  Prototype.DefineData(R, R.Intern('trimLeft'), Prototype.GetValue(R, R.Intern('trimStart')), PropertyHidden);
  Prototype.DefineData(R, R.Intern('trimRight'), Prototype.GetValue(R, R.Intern('trimEnd')), PropertyHidden);
  DefineMethod(R, Prototype, 'padStart', @StringPad, 1, 0);
  DefineMethod(R, Prototype, 'padEnd', @StringPad, 1, 1);
  DefineMethod(R, Prototype, 'repeat', @StringRepeat, 1);
  DefineMethod(R, Prototype, 'split', @StringSplit, 2);
  DefineMethod(R, Prototype, 'replace', @StringReplace, 2, 0);
  DefineMethod(R, Prototype, 'replaceAll', @StringReplace, 2, 1);
  DefineMethod(R, Prototype, 'match', @StringMatch, 1, 0);
  DefineMethod(R, Prototype, 'matchAll', @StringMatch, 1, 1);
  DefineMethod(R, Prototype, 'search', @StringMatch, 1, 2);
  DefineMethod(R, Prototype, 'localeCompare', @StringLocaleCompare, 1);
  DefineMethod(R, Prototype, 'normalize', @StringNormalize, 0);
  DefineMethod(R, Prototype, 'toString', @StringValueOf, 0);
  DefineMethod(R, Prototype, 'valueOf', @StringValueOf, 0);
  DefineMethod(R, Prototype, 'isWellFormed', @StringWellFormed, 0, 0);
  DefineMethod(R, Prototype, 'toWellFormed', @StringWellFormed, 0, 1);
  DefineSymbolMethod(R, Prototype, wsIterator, '[Symbol.iterator]', @StringIteratorMethod, 0);
end;

end.

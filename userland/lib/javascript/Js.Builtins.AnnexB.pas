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
  The web compatibility built-ins of Annex B and the legacy RegExp
  features: escape and unescape, the String HTML methods (anchor, bold
  ...), Object.prototype.__defineGetter__ and its kin, and the RegExp
  statics ($1-$9, input, lastMatch, lastParen, leftContext,
  rightContext with their $ aliases), which the last successful match
  of a built-in exec updates (RecordLegacyMatch).
}
unit Js.Builtins.AnnexB;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Strings,
  Js.Objects,
  Js.Interpreter;

procedure InstallAnnexB(R: TJsInterpreterRealm);
{ Notes a match for the RegExp statics: the input and the capture
  positions (start and end per group, -1 when unmatched). }
procedure RecordLegacyMatch(R: TJsRealm; Input: TJsString; const Captures: array of Integer; GroupCount: Integer);

implementation

uses
  SysUtils,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Builtins.Objects;

{ escape and unescape }

function IsEscapeSafe(Code: Word): Boolean; inline;
begin
  Result := ((Code >= Ord('A')) and (Code <= Ord('Z'))) or ((Code >= Ord('a')) and (Code <= Ord('z'))) or
    ((Code >= Ord('0')) and (Code <= Ord('9'))) or (Code = Ord('@')) or (Code = Ord('*')) or (Code = Ord('_')) or
    (Code = Ord('+')) or (Code = Ord('-')) or (Code = Ord('.')) or (Code = Ord('/'));
end;

function GlobalEscape(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Hex: array[0..15] of WideChar = '0123456789ABCDEF';
var
  Text: TJsString;
  Output: UnicodeString;
  Index: Integer;
  Code: Word;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Output := '';
  for Index := 0 to Text.Length - 1 do
  begin
    Code := Text.CharAt(Index);
    if IsEscapeSafe(Code) then
      Output := Output + WideChar(Code)
    else if Code < 256 then
      Output := Output + '%' + Hex[Code shr 4] + Hex[Code and 15]
    else
      Output := Output + '%u' + Hex[Code shr 12] + Hex[(Code shr 8) and 15] + Hex[(Code shr 4) and 15] +
        Hex[Code and 15];
  end;
  Result := JsStringValue(NewStringFromUnicode(R.Heap, Output));
end;

function HexDigit(Code: Word): Integer;
begin
  case Code of
    Ord('0')..Ord('9'): Result := Code - Ord('0');
    Ord('a')..Ord('f'): Result := Code - Ord('a') + 10;
    Ord('A')..Ord('F'): Result := Code - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function GlobalUnescape(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Output: UnicodeString;
  Index, Length_, Value, Digit, Count: Integer;
  Code: Word;
  Valid: Boolean;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Output := '';
  Length_ := Text.Length;
  Index := 0;
  while Index < Length_ do
  begin
    Code := Text.CharAt(Index);
    if Code = Ord('%') then
    begin
      if (Index + 5 < Length_) and (Text.CharAt(Index + 1) = Ord('u')) then
      begin
        Value := 0;
        Valid := True;
        for Count := 2 to 5 do
        begin
          Digit := HexDigit(Text.CharAt(Index + Count));
          if Digit < 0 then
            Valid := False;
          Value := Value * 16 + Digit;
        end;
        if Valid then
        begin
          Output := Output + WideChar(Value);
          Inc(Index, 6);
          Continue;
        end;
      end;
      if Index + 2 < Length_ then
      begin
        if (HexDigit(Text.CharAt(Index + 1)) >= 0) and (HexDigit(Text.CharAt(Index + 2)) >= 0) then
        begin
          Output := Output + WideChar(HexDigit(Text.CharAt(Index + 1)) * 16 + HexDigit(Text.CharAt(Index + 2)));
          Inc(Index, 3);
          Continue;
        end;
      end;
    end;
    Output := Output + WideChar(Code);
    Inc(Index);
  end;
  Result := JsStringValue(NewStringFromUnicode(R.Heap, Output));
end;

{ The String HTML methods (CreateHTML). }

const
  HtmlTags: array[0..12] of string = ('a', 'big', 'blink', 'b', 'tt', 'font', 'font', 'i', 'a', 'small', 'strike',
    'sub', 'sup');
  HtmlAttributes: array[0..12] of string = ('name', '', '', '', '', 'color', 'size', '', 'href', '', '', '', '');
  HtmlMethods: array[0..12] of string = ('anchor', 'big', 'blink', 'bold', 'fixed', 'fontcolor', 'fontsize',
    'italics', 'link', 'small', 'strike', 'sub', 'sup');

function StringHtml(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text, Attribute: TJsString;
  Output, Value: UnicodeString;
  Index: Integer;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('String.prototype.' + HtmlMethods[Callee.Magic] + ' called on null or undefined'));
  Text := ToJsString(R, This);
  if Text = nil then
    Exit(JsException);
  Output := '<' + UnicodeString(HtmlTags[Callee.Magic]);
  if HtmlAttributes[Callee.Magic] <> '' then
  begin
    Attribute := ToJsString(R, Arg(Args, ArgCount, 0));
    if Attribute = nil then
      Exit(JsException);
    Value := StringToUnicode(R.Heap, Attribute);
    Output := Output + ' ' + UnicodeString(HtmlAttributes[Callee.Magic]) + '="';
    for Index := 1 to Length(Value) do
      if Value[Index] = '"' then
        Output := Output + '&quot;'
      else
        Output := Output + Value[Index];
    Output := Output + '"';
  end;
  Output := Output + '>' + StringToUnicode(R.Heap, Text) + '</' + UnicodeString(HtmlTags[Callee.Magic]) + '>';
  Result := JsStringValue(NewStringFromUnicode(R.Heap, Output));
end;

{ __defineGetter__ (0), __defineSetter__ (1), __lookupGetter__ (2),
  __lookupSetter__ (3). }
function LegacyAccessor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsValue;
  Current: TJsObject;
  Key, Function_: TJsValue;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Target := ToObject(R, This);
  if Target = JsException then
    Exit(JsException);
  if Callee.Magic <= 1 then
  begin
    Function_ := Arg(Args, ArgCount, 1);
    if not JsIsCallable(Function_) then
      Exit(R.ThrowTypeError('Object.prototype.__define' + Copy('GetterSetter', 1 + Callee.Magic * 6, 6) +
        '__: Expecting function'));
    Key := ToPropertyKey(R, Arg(Args, ArgCount, 0));
    if Key = JsException then
      Exit(JsException);
    if Callee.Magic = 0 then
    begin
      Desc := AccessorDescriptor(Function_, JsUndefined, PropertyEnumerable or PropertyConfigurable);
      Desc.Present := Desc.Present and not HasSetter;
    end
    else
    begin
      Desc := AccessorDescriptor(JsUndefined, Function_, PropertyEnumerable or PropertyConfigurable);
      Desc.Present := Desc.Present and not HasGetter;
    end;
    if JsAsObject(Target).DefineOwnProperty(R, Key, Desc, True) < 0 then
      Exit(JsException);
    Exit(JsUndefined);
  end;
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 0));
  if Key = JsException then
    Exit(JsException);
  Current := JsAsObject(Target);
  while Current <> nil do
  begin
    Found := Current.GetOwnProperty(R, Key, Desc);
    if Found < 0 then
      Exit(JsException);
    if Found > 0 then
    begin
      if not DescriptorIsAccessor(Desc) then
        Exit(JsUndefined);
      if Callee.Magic = 2 then
        Exit(Desc.Getter);
      Exit(Desc.Setter);
    end;
    if not Current.GetPrototype(R, Current) then
      Exit(JsException);
  end;
  Result := JsUndefined;
end;

{ The RegExp statics: the state is an array on the RegExp constructor
  (Data2): the input, then start and end per group. }

const
  StaticInput = 10;
  StaticLastMatch = 11;
  StaticLastParen = 12;
  StaticLeftContext = 13;
  StaticRightContext = 14;

function LegacyState(R: TJsRealm): TJsArray;
var
  Constructor_: TJsNativeFunction;
begin
  Constructor_ := TJsNativeFunction(R.Intrinsics[inRegExp]);
  if not JsIsObject(Constructor_.Data2) then
  begin
    Result := R.NewArray(0);
    Result.CreateDataProperty(R, JsInteger(0), R.Atom(anEmpty));
    Constructor_.Data2 := JsObjectValue(Result);
  end;
  Result := TJsArray(JsAsObject(Constructor_.Data2));
end;

procedure RecordLegacyMatch(R: TJsRealm; Input: TJsString; const Captures: array of Integer; GroupCount: Integer);
var
  State: TJsArray;
  Index, Count: Integer;
begin
  if R.Intrinsics[inRegExp] = nil then
    Exit;
  State := LegacyState(R);
  Count := (GroupCount + 1) * 2;
  State.EnsureElementCapacity(R, Count + 1);
  State.Elements^[0] := JsStringValue(Input);
  for Index := 0 to Count - 1 do
    State.Elements^[Index + 1] := JsInteger(Captures[Index]);
  State.ElementCount := Count + 1;
  State.ArrayLength := Count + 1;
end;

function StateSlice(R: TJsRealm; State: TJsArray; Group: Integer): TJsValue;
var
  Input: TJsString;
  Start, Finish: Integer;
begin
  Result := R.Atom(anEmpty);
  if (Group * 2 + 2 >= State.ElementCount) then
    Exit;
  Input := JsAsString(State.Elements^[0]);
  Start := JsAsInteger(State.Elements^[Group * 2 + 1]);
  Finish := JsAsInteger(State.Elements^[Group * 2 + 2]);
  if (Start < 0) or (Finish < Start) then
    Exit;
  Result := JsStringValue(SubString(R.Heap, Input, Start, Finish - Start));
end;

function RegExpStatic(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  State: TJsArray;
  Input: TJsString;
  Groups, Start, Finish: Integer;
begin
  State := LegacyState(R);
  case Callee.Magic of
    1..9: Result := StateSlice(R, State, Callee.Magic);
    StaticInput: Result := State.Elements^[0];
    StaticLastMatch: Result := StateSlice(R, State, 0);
    StaticLastParen:
      begin
        Groups := (State.ElementCount - 1) div 2 - 1;
        if Groups <= 0 then
          Exit(R.Atom(anEmpty));
        Result := StateSlice(R, State, Groups);
      end;
  else
    begin
      if State.ElementCount < 3 then
        Exit(R.Atom(anEmpty));
      Input := JsAsString(State.Elements^[0]);
      Start := JsAsInteger(State.Elements^[1]);
      Finish := JsAsInteger(State.Elements^[2]);
      if Callee.Magic = StaticLeftContext then
        Result := JsStringValue(SubString(R.Heap, Input, 0, Start))
      else
        Result := JsStringValue(SubString(R.Heap, Input, Finish, Input.Length - Finish));
    end;
  end;
end;

function RegExpSetInput(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  LegacyState(R).Elements^[0] := JsStringValue(Text);
  Result := JsUndefined;
end;

procedure InstallAnnexB(R: TJsInterpreterRealm);
const
  StaticNames: array[10..14] of string = ('input', 'lastMatch', 'lastParen', 'leftContext', 'rightContext');
  StaticAliases: array[10..14] of string = ('$_', '$&', '$+', '$`', '$''');
var
  Index: Integer;
  Constructor_: TJsObject;
  Getter, Setter: TJsValue;
begin
  DefineMethod(R, R.GlobalObject, 'escape', @GlobalEscape, 1);
  DefineMethod(R, R.GlobalObject, 'unescape', @GlobalUnescape, 1);
  for Index := 0 to High(HtmlMethods) do
    if HtmlAttributes[Index] <> '' then
      DefineMethod(R, R.Intrinsics[inStringPrototype], HtmlMethods[Index], @StringHtml, 1, Index)
    else
      DefineMethod(R, R.Intrinsics[inStringPrototype], HtmlMethods[Index], @StringHtml, 0, Index);
  DefineMethod(R, R.Intrinsics[inObjectPrototype], '__defineGetter__', @LegacyAccessor, 2, 0);
  DefineMethod(R, R.Intrinsics[inObjectPrototype], '__defineSetter__', @LegacyAccessor, 2, 1);
  DefineMethod(R, R.Intrinsics[inObjectPrototype], '__lookupGetter__', @LegacyAccessor, 1, 2);
  DefineMethod(R, R.Intrinsics[inObjectPrototype], '__lookupSetter__', @LegacyAccessor, 1, 3);
  Constructor_ := R.Intrinsics[inRegExp];
  if Constructor_ = nil then
    Exit;
  for Index := 1 to 9 do
  begin
    Getter := JsObjectValue(NewNativeFunction(R, 'get $' + IntToStr(Index), @RegExpStatic, 0, Index));
    Constructor_.DefineAccessor(R, R.Intern('$' + IntToStr(Index)), Getter, JsUndefined, PropertyConfigurable);
  end;
  for Index := 10 to 14 do
  begin
    Getter := JsObjectValue(NewNativeFunction(R, 'get ' + StaticNames[Index], @RegExpStatic, 0, Index));
    Setter := JsUndefined;
    if Index = StaticInput then
      Setter := JsObjectValue(NewNativeFunction(R, 'set input', @RegExpSetInput, 1));
    Constructor_.DefineAccessor(R, R.Intern(StaticNames[Index]), Getter, Setter, PropertyConfigurable);
    Constructor_.DefineAccessor(R, R.Intern(StaticAliases[Index]), Getter, Setter, PropertyConfigurable);
  end;
end;

end.

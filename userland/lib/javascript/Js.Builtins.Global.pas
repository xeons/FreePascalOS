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
  The global object's own functions and values, and console.

  globalThis, NaN, Infinity, undefined, parseInt, parseFloat, isNaN,
  isFinite, the URI functions, eval (indirect: the code runs in the
  global scope), queueMicrotask, and console (log, info, debug, warn,
  error, assert, group, groupEnd, table-less), which writes through
  the realm's ConsoleWriter with %s %d %i %f %o %O %j substitution.
}
unit Js.Builtins.Global;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
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
  Js.Lexer,
  Js.Compiler,
  Js.Inspect,
  Js.Interpreter;

procedure InstallGlobal(R: TJsInterpreterRealm);

implementation

function GlobalParseInt(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Radix32: LongInt;
  Radix, Position, Digit, Start: Integer;
  Negative, StripPrefix: Boolean;
  Value: Double;
  Code: Word;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  if not ToInt32(R, Arg(Args, ArgCount, 1), Radix32) then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Position := 0;
  while (Position < Text.Length) and IsJsSpace(Text.CharAt(Position)) do
    Inc(Position);
  Negative := False;
  if (Position < Text.Length) and ((Text.CharAt(Position) = Ord('-')) or (Text.CharAt(Position) = Ord('+'))) then
  begin
    Negative := Text.CharAt(Position) = Ord('-');
    Inc(Position);
  end;
  Radix := Radix32;
  StripPrefix := True;
  if Radix <> 0 then
  begin
    if (Radix < 2) or (Radix > 36) then
      Exit(JsNaN);
    if Radix <> 16 then
      StripPrefix := False;
  end
  else
    Radix := 10;
  if StripPrefix and (Position + 1 < Text.Length) and (Text.CharAt(Position) = Ord('0')) and
    ((Text.CharAt(Position + 1) = Ord('x')) or (Text.CharAt(Position + 1) = Ord('X'))) then
  begin
    Inc(Position, 2);
    Radix := 16;
  end;
  Start := Position;
  Value := 0;
  while Position < Text.Length do
  begin
    Code := Text.CharAt(Position);
    case Code of
      Ord('0')..Ord('9'): Digit := Code - Ord('0');
      Ord('a')..Ord('z'): Digit := Code - Ord('a') + 10;
      Ord('A')..Ord('Z'): Digit := Code - Ord('A') + 10;
    else
      Digit := 99;
    end;
    if Digit >= Radix then
      Break;
    Value := Value * Radix + Digit;
    Inc(Position);
  end;
  if Position = Start then
    Exit(JsNaN);
  if (Radix = 10) and (Position - Start > 15) then
    Value := TextToNumber(StringToUtf8(R.Heap, SubString(R.Heap, Text, Start, Position - Start)));
  if Negative then
    Value := -Value;
  Result := JsNumber(Value);
end;

function GlobalParseFloat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Position, Start, Best: Integer;
  Prefix: string;
  Code: Word;
  SawDigit: Boolean;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Position := 0;
  while (Position < Text.Length) and IsJsSpace(Text.CharAt(Position)) do
    Inc(Position);
  Start := Position;
  Prefix := '';
  if (Position < Text.Length) and ((Text.CharAt(Position) = Ord('-')) or (Text.CharAt(Position) = Ord('+'))) then
    Inc(Position);
  if StringEqualsAscii(SubString(R.Heap, Text, Position, Min(8, Text.Length - Position)), 'Infinity') then
  begin
    if Text.CharAt(Start) = Ord('-') then
      Exit(JsDouble(NegInfinity));
    Exit(JsDouble(Infinity));
  end;
  SawDigit := False;
  Best := -1;
  while (Position < Text.Length) and (Text.CharAt(Position) >= Ord('0')) and (Text.CharAt(Position) <= Ord('9')) do
  begin
    Inc(Position);
    SawDigit := True;
    Best := Position;
  end;
  if (Position < Text.Length) and (Text.CharAt(Position) = Ord('.')) then
  begin
    Inc(Position);
    while (Position < Text.Length) and (Text.CharAt(Position) >= Ord('0')) and (Text.CharAt(Position) <= Ord('9')) do
    begin
      Inc(Position);
      SawDigit := True;
      Best := Position;
    end;
  end;
  if not SawDigit then
    Exit(JsNaN);
  if (Position < Text.Length) and ((Text.CharAt(Position) = Ord('e')) or (Text.CharAt(Position) = Ord('E'))) then
  begin
    Inc(Position);
    if (Position < Text.Length) and ((Text.CharAt(Position) = Ord('-')) or (Text.CharAt(Position) = Ord('+'))) then
      Inc(Position);
    while (Position < Text.Length) and (Text.CharAt(Position) >= Ord('0')) and (Text.CharAt(Position) <= Ord('9')) do
    begin
      Inc(Position);
      Best := Position;
    end;
  end;
  Code := 0;
  if Code = 0 then;
  Result := JsNumber(TextToNumber(StringToUtf8(R.Heap, SubString(R.Heap, Text, Start, Best - Start))));
end;

function GlobalIsNaN(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number: Double;
begin
  if not ToDouble(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if Callee.Magic = 0 then
    Result := JsBoolean(IsNaNDouble(Number))
  else
    Result := JsBoolean(IsFiniteDouble(Number));
end;

const
  HexDigits = '0123456789ABCDEF';
  UriUnreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '!', '~', '*', '''', '(', ')'];
  UriReserved = [';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#'];

{ Magic: 0 encodeURIComponent, 1 encodeURI. }
function GlobalEncode(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Output: string;
  Index: Integer;
  CodePoint, Next: LongWord;
  Utf8: string;
  Position: Integer;

  procedure AddByte(Value: Byte);
  begin
    Output := Output + '%' + HexDigits[(Value shr 4) + 1] + HexDigits[(Value and 15) + 1];
  end;

begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Output := '';
  Index := 0;
  while Index < Text.Length do
  begin
    CodePoint := Text.CharAt(Index);
    if (CodePoint < 128) and ((Char(CodePoint) in UriUnreserved) or ((Callee.Magic = 1) and
      (Char(CodePoint) in UriReserved))) then
    begin
      Output := Output + Char(CodePoint);
      Inc(Index);
      Continue;
    end;
    if (CodePoint >= $DC00) and (CodePoint <= $DFFF) then
      Exit(R.ThrowError(ekUri, 'URI malformed'));
    if (CodePoint >= $D800) and (CodePoint <= $DBFF) then
    begin
      if Index + 1 >= Text.Length then
        Exit(R.ThrowError(ekUri, 'URI malformed'));
      Next := Text.CharAt(Index + 1);
      if (Next < $DC00) or (Next > $DFFF) then
        Exit(R.ThrowError(ekUri, 'URI malformed'));
      CodePoint := $10000 + ((CodePoint - $D800) shl 10) + (Next - $DC00);
      Inc(Index);
    end;
    if CodePoint < $80 then
      Utf8 := Char(CodePoint)
    else if CodePoint < $800 then
      Utf8 := Char($C0 or (CodePoint shr 6)) + Char($80 or (CodePoint and $3F))
    else if CodePoint < $10000 then
      Utf8 := Char($E0 or (CodePoint shr 12)) + Char($80 or ((CodePoint shr 6) and $3F)) +
        Char($80 or (CodePoint and $3F))
    else
      Utf8 := Char($F0 or (CodePoint shr 18)) + Char($80 or ((CodePoint shr 12) and $3F)) +
        Char($80 or ((CodePoint shr 6) and $3F)) + Char($80 or (CodePoint and $3F));
    for Position := 1 to Length(Utf8) do
      AddByte(Byte(Utf8[Position]));
    Inc(Index);
  end;
  Result := R.NewString(Output);
end;

function HexValue(Code: Word): Integer;
begin
  case Code of
    Ord('0')..Ord('9'): Result := Code - Ord('0');
    Ord('a')..Ord('f'): Result := Code - Ord('a') + 10;
    Ord('A')..Ord('F'): Result := Code - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ Magic: 0 decodeURIComponent, 1 decodeURI. }
function GlobalDecode(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Units: array of Word;
  Count, Index, Extra, Position: Integer;
  Value, CodePoint: LongWord;
  Byte_: Integer;

  function ReadByte(At: Integer): Integer;
  begin
    if (At + 2 >= Text.Length + 0) and (At + 2 > Text.Length - 1) then
      Exit(-1);
    if Text.CharAt(At) <> Ord('%') then
      Exit(-1);
    if (HexValue(Text.CharAt(At + 1)) < 0) or (HexValue(Text.CharAt(At + 2)) < 0) then
      Exit(-1);
    Result := HexValue(Text.CharAt(At + 1)) * 16 + HexValue(Text.CharAt(At + 2));
  end;

  procedure Put(Unit16: LongWord);
  begin
    if Count >= Length(Units) then
      SetLength(Units, Length(Units) * 2 + 16);
    Units[Count] := Unit16;
    Inc(Count);
  end;

begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Units := nil;
  Count := 0;
  Index := 0;
  while Index < Text.Length do
  begin
    if Text.CharAt(Index) <> Ord('%') then
    begin
      Put(Text.CharAt(Index));
      Inc(Index);
      Continue;
    end;
    Byte_ := ReadByte(Index);
    if Byte_ < 0 then
      Exit(R.ThrowError(ekUri, 'URI malformed'));
    if Byte_ < $80 then
    begin
      if (Callee.Magic = 1) and (Char(Byte_) in UriReserved) then
      begin
        for Position := 0 to 2 do
          Put(Text.CharAt(Index + Position));
      end
      else
        Put(Byte_);
      Inc(Index, 3);
      Continue;
    end;
    if (Byte_ and $E0) = $C0 then
    begin
      Extra := 1;
      Value := Byte_ and $1F;
    end
    else if (Byte_ and $F0) = $E0 then
    begin
      Extra := 2;
      Value := Byte_ and $0F;
    end
    else if (Byte_ and $F8) = $F0 then
    begin
      Extra := 3;
      Value := Byte_ and $07;
    end
    else
      Exit(R.ThrowError(ekUri, 'URI malformed'));
    Inc(Index, 3);
    for Position := 1 to Extra do
    begin
      Byte_ := ReadByte(Index);
      if (Byte_ < 0) or ((Byte_ and $C0) <> $80) then
        Exit(R.ThrowError(ekUri, 'URI malformed'));
      Value := (Value shl 6) or LongWord(Byte_ and $3F);
      Inc(Index, 3);
    end;
    CodePoint := Value;
    if (CodePoint >= $D800) and (CodePoint <= $DFFF) or (CodePoint > $10FFFF) then
      Exit(R.ThrowError(ekUri, 'URI malformed'));
    if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      Put($D800 + (CodePoint shr 10));
      Put($DC00 + (CodePoint and $3FF));
    end
    else
      Put(CodePoint);
  end;
  if Count = 0 then
    Exit(R.Atom(anEmpty));
  Result := JsStringValue(NewUtf16String(R.Heap, @Units[0], Count));
end;

function GlobalEval(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Source: TJsValue;
  Code: TJsCode;
begin
  Source := Arg(Args, ArgCount, 0);
  if not JsIsString(Source) then
    Exit(Source);
  try
    Code := CompileScript(R, StringToUnicode(R.Heap, JsAsString(Source)), '<eval>');
  except
    on Error: EJsSyntaxError do
      Exit(R.ThrowError(ekSyntax, Error.Message));
  end;
  Result := TJsInterpreterRealm(R).RunScript(Code);
end;

procedure MicrotaskJob(R: TJsRealm; const Values: array of TJsValue);
begin
  R.Call(Values[0], JsUndefined, nil, 0);
end;

function GlobalQueueMicrotask(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if not JsIsCallable(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('The callback must be a function'));
  R.EnqueueJob(@MicrotaskJob, Args^[0], JsUndefined, JsUndefined, JsUndefined);
  Result := JsUndefined;
end;

{ console }

function FormatArguments(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer): string;
var
  Format_, Piece: string;
  Index, Next: Integer;
  Number: Double;
  Integer32: LongInt;
begin
  Result := '';
  if ArgCount = 0 then
    Exit;
  Next := 1;
  if JsIsString(Args^[0]) then
  begin
    Format_ := StringToUtf8(R.Heap, JsAsString(Args^[0]));
    Index := 1;
    while Index <= Length(Format_) do
    begin
      if (Format_[Index] = '%') and (Index < Length(Format_)) then
      begin
        case Format_[Index + 1] of
          's', 'd', 'i', 'f', 'o', 'O', 'j', 'c':
            if Next < ArgCount then
            begin
              case Format_[Index + 1] of
                's':
                  if JsIsString(Args^[Next]) then
                    Piece := StringToUtf8(R.Heap, JsAsString(Args^[Next]))
                  else
                    Piece := InspectNested(R, Args^[Next]);
                'd', 'i':
                  begin
                    if ToDouble(R, Args^[Next], Number) then
                    begin
                      if Format_[Index + 1] = 'i' then
                        Number := Int(Number);
                      Piece := NumberToString(Number);
                    end
                    else
                    begin
                      R.Runtime.TakeException;
                      Piece := 'NaN';
                    end;
                    Integer32 := 0;
                    if Integer32 = 0 then;
                  end;
                'f':
                  if ToDouble(R, Args^[Next], Number) then
                    Piece := NumberToString(Number)
                  else
                  begin
                    R.Runtime.TakeException;
                    Piece := 'NaN';
                  end;
                'c':
                  Piece := '';
              else
                Piece := InspectNested(R, Args^[Next]);
              end;
              Result := Result + Piece;
              Inc(Next);
              Inc(Index, 2);
              Continue;
            end;
          '%':
            begin
              Result := Result + '%';
              Inc(Index, 2);
              Continue;
            end;
        end;
      end;
      Result := Result + Format_[Index];
      Inc(Index);
    end;
  end
  else
    Result := InspectValue(R, Args^[0]);
  for Index := Next to ArgCount - 1 do
    Result := Result + ' ' + InspectValue(R, Args^[Index]);
end;

procedure WriteConsole(R: TJsRealm; const Text: string; IsError: Boolean);
var
  Realm: TJsInterpreterRealm;
  Indented: string;
begin
  Realm := TJsInterpreterRealm(R);
  Indented := Text;
  if Realm.ConsoleIndent > 0 then
    Indented := StringOfChar(' ', Realm.ConsoleIndent) +
      StringReplace(Text, #10, #10 + StringOfChar(' ', Realm.ConsoleIndent), [rfReplaceAll]);
  if Assigned(Realm.ConsoleWriter) then
    Realm.ConsoleWriter(Indented, IsError)
  else if IsError then
    WriteLn(StdErr, Indented)
  else
    WriteLn(Indented);
end;

{ Magic: 0 log/info/debug, 1 warn/error. }
function ConsoleLog(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  WriteConsole(R, FormatArguments(R, Args, ArgCount), Callee.Magic = 1);
  Result := JsUndefined;
end;

function ConsoleAssert(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsUndefined;
  if ToBoolean(Arg(Args, ArgCount, 0)) then
    Exit;
  if ArgCount > 1 then
    WriteConsole(R, 'Assertion failed: ' + FormatArguments(R, @Args^[1], ArgCount - 1), True)
  else
    WriteConsole(R, 'Assertion failed', True);
end;

{ Magic: 0 group, 1 groupEnd. }
function ConsoleGroup(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Realm: TJsInterpreterRealm;
begin
  Realm := TJsInterpreterRealm(R);
  if Callee.Magic = 0 then
  begin
    if ArgCount > 0 then
      WriteConsole(R, FormatArguments(R, Args, ArgCount), False);
    Inc(Realm.ConsoleIndent, 2);
  end
  else if Realm.ConsoleIndent >= 2 then
    Dec(Realm.ConsoleIndent, 2);
  Result := JsUndefined;
end;

procedure InstallGlobal(R: TJsInterpreterRealm);
var
  Global, Console: TJsObject;
begin
  Global := R.GlobalObject;
  Global.DefineData(R, R.Atom(anGlobalThis), JsObjectValue(Global), PropertyHidden);
  Global.DefineData(R, R.Atom(anNaN), JsNaN, 0);
  Global.DefineData(R, R.Atom(anInfinity), JsDouble(Infinity), 0);
  Global.DefineData(R, R.Atom(anUndefined), JsUndefined, 0);
  DefineMethod(R, Global, 'parseInt', @GlobalParseInt, 2);
  DefineMethod(R, Global, 'parseFloat', @GlobalParseFloat, 1);
  DefineMethod(R, Global, 'isNaN', @GlobalIsNaN, 1, 0);
  DefineMethod(R, Global, 'isFinite', @GlobalIsNaN, 1, 1);
  DefineMethod(R, Global, 'encodeURIComponent', @GlobalEncode, 1, 0);
  DefineMethod(R, Global, 'encodeURI', @GlobalEncode, 1, 1);
  DefineMethod(R, Global, 'decodeURIComponent', @GlobalDecode, 1, 0);
  DefineMethod(R, Global, 'decodeURI', @GlobalDecode, 1, 1);
  DefineMethod(R, Global, 'eval', @GlobalEval, 1);
  R.Intrinsics[inEval] := JsAsObject(Global.GetValue(R, R.Atom(anEval)));
  DefineMethod(R, Global, 'queueMicrotask', @GlobalQueueMicrotask, 1);
  Console := R.NewPlainObject;
  DefineValue(R, Global, 'console', JsObjectValue(Console));
  DefineMethod(R, Console, 'log', @ConsoleLog, 0, 0);
  DefineMethod(R, Console, 'info', @ConsoleLog, 0, 0);
  DefineMethod(R, Console, 'debug', @ConsoleLog, 0, 0);
  DefineMethod(R, Console, 'warn', @ConsoleLog, 0, 1);
  DefineMethod(R, Console, 'error', @ConsoleLog, 0, 1);
  DefineMethod(R, Console, 'trace', @ConsoleLog, 0, 1);
  DefineMethod(R, Console, 'assert', @ConsoleAssert, 0);
  DefineMethod(R, Console, 'group', @ConsoleGroup, 0, 0);
  DefineMethod(R, Console, 'groupEnd', @ConsoleGroup, 0, 1);
end;

end.

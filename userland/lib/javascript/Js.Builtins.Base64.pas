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
  Uint8Array to and from base64 and hex (ECMAScript 2026):
  Uint8Array.fromBase64 / fromHex, and the prototype's toBase64,
  toHex, setFromBase64 and setFromHex.

  Decoding follows the specification's FromBase64: ASCII whitespace is
  skipped, the alphabet is base64 or base64url, and the last chunk is
  handled "loose" (padding optional), "strict" (padding and zero extra
  bits required) or "stop-before-partial" (an incomplete chunk is left
  unread). setFromBase64 decodes at most what fits.
}
unit Js.Builtins.Base64;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Interpreter;

procedure InstallBase64(R: TJsInterpreterRealm);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.ArrayBuffers,
  Js.Builtins.TypedArrays;

type
  TLastChunkHandling = (lcLoose, lcStrict, lcStopBeforePartial);

  TDecodeResult = record
    Read: SizeInt;
    Bytes: TBytes;
    Failed: Boolean;
  end;

const
  StandardAlphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  UrlAlphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  HexDigits: string = '0123456789abcdef';

function IsAsciiWhitespace(Code: Word): Boolean; inline;
begin
  Result := (Code = 9) or (Code = 10) or (Code = 12) or (Code = 13) or (Code = 32);
end;

function SkipWhitespace(Text: TJsString; Index: SizeInt): SizeInt;
begin
  while (Index < Text.Length) and IsAsciiWhitespace(Text.CharAt(Index)) do
    Inc(Index);
  Result := Index;
end;

function SextetOf(Code: Word): Integer;
begin
  case Code of
    Ord('A')..Ord('Z'): Result := Code - Ord('A');
    Ord('a')..Ord('z'): Result := Code - Ord('a') + 26;
    Ord('0')..Ord('9'): Result := Code - Ord('0') + 52;
    Ord('+'): Result := 62;
    Ord('/'): Result := 63;
  else
    Result := -1;
  end;
end;

procedure Append(var Bytes: TBytes; Value: Byte);
begin
  SetLength(Bytes, Length(Bytes) + 1);
  Bytes[High(Bytes)] := Value;
end;

{ DecodeBase64Chunk: 2 to 4 sextets; False when extra bits are set and
  that is an error. }
function DecodeChunk(const Chunk: array of Integer; Count: Integer; ThrowOnExtraBits: Boolean;
  var Bytes: TBytes): Boolean;
var
  Bits: LongWord;
  Index: Integer;
begin
  Bits := 0;
  for Index := 0 to 3 do
  begin
    Bits := Bits shl 6;
    if Index < Count then
      Bits := Bits or LongWord(Chunk[Index]);
  end;
  case Count of
    2:
      begin
        if ThrowOnExtraBits and (((Bits shr 8) and $FF) <> 0) then
          Exit(False);
        Append(Bytes, Byte(Bits shr 16));
      end;
    3:
      begin
        if ThrowOnExtraBits and ((Bits and $FF) <> 0) then
          Exit(False);
        Append(Bytes, Byte(Bits shr 16));
        Append(Bytes, Byte(Bits shr 8));
      end;
  else
    Append(Bytes, Byte(Bits shr 16));
    Append(Bytes, Byte(Bits shr 8));
    Append(Bytes, Byte(Bits));
  end;
  Result := True;
end;

function FromBase64(Text: TJsString; Url: Boolean; Handling: TLastChunkHandling; MaxLength: SizeInt): TDecodeResult;
var
  Chunk: array[0..3] of Integer;
  ChunkLength: Integer;
  Index, Remaining: SizeInt;
  Code: Word;
  Sextet: Integer;
begin
  Result.Read := 0;
  Result.Bytes := nil;
  Result.Failed := False;
  if MaxLength = 0 then
    Exit;
  ChunkLength := 0;
  Index := 0;
  while True do
  begin
    Index := SkipWhitespace(Text, Index);
    if Index = Text.Length then
    begin
      if ChunkLength > 0 then
      begin
        if Handling = lcStopBeforePartial then
          Exit;
        if (Handling = lcStrict) or (ChunkLength = 1) then
        begin
          Result.Failed := True;
          Exit;
        end;
        DecodeChunk(Chunk, ChunkLength, False, Result.Bytes);
      end;
      Result.Read := Text.Length;
      Exit;
    end;
    Code := Text.CharAt(Index);
    Inc(Index);
    if Code = Ord('=') then
    begin
      if ChunkLength < 2 then
      begin
        Result.Failed := True;
        Exit;
      end;
      Index := SkipWhitespace(Text, Index);
      if ChunkLength = 2 then
      begin
        if Index = Text.Length then
        begin
          if Handling <> lcStopBeforePartial then
            Result.Failed := True;
          Exit;
        end;
        if Text.CharAt(Index) = Ord('=') then
          Index := SkipWhitespace(Text, Index + 1);
      end;
      if Index < Text.Length then
      begin
        Result.Failed := True;
        Exit;
      end;
      if not DecodeChunk(Chunk, ChunkLength, Handling = lcStrict, Result.Bytes) then
      begin
        Result.Failed := True;
        Exit;
      end;
      Result.Read := Text.Length;
      Exit;
    end;
    if Url then
    begin
      if (Code = Ord('+')) or (Code = Ord('/')) then
        Code := 0
      else if Code = Ord('-') then
        Code := Ord('+')
      else if Code = Ord('_') then
        Code := Ord('/');
    end;
    Sextet := SextetOf(Code);
    if Sextet < 0 then
    begin
      Result.Failed := True;
      Exit;
    end;
    Remaining := MaxLength - Length(Result.Bytes);
    if ((Remaining = 1) and (ChunkLength = 2)) or ((Remaining = 2) and (ChunkLength = 3)) then
      Exit;
    Chunk[ChunkLength] := Sextet;
    Inc(ChunkLength);
    if ChunkLength = 4 then
    begin
      DecodeChunk(Chunk, 4, False, Result.Bytes);
      ChunkLength := 0;
      Result.Read := Index;
      if Length(Result.Bytes) = MaxLength then
        Exit;
    end;
  end;
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

function FromHex(Text: TJsString; MaxLength: SizeInt): TDecodeResult;
var
  High, Low: Integer;
begin
  Result.Read := 0;
  Result.Bytes := nil;
  Result.Failed := False;
  if Text.Length mod 2 <> 0 then
  begin
    Result.Failed := True;
    Exit;
  end;
  while (Result.Read < Text.Length) and (Length(Result.Bytes) < MaxLength) do
  begin
    High := HexValue(Text.CharAt(Result.Read));
    Low := HexValue(Text.CharAt(Result.Read + 1));
    if (High < 0) or (Low < 0) then
    begin
      Result.Failed := True;
      Exit;
    end;
    Inc(Result.Read, 2);
    Append(Result.Bytes, Byte(High * 16 + Low));
  end;
end;

{ Options }

function OptionsObject(R: TJsRealm; Value: TJsValue; out Options: TJsObject): Boolean;
begin
  Options := nil;
  if Value = JsUndefined then
    Exit(True);
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError('options must be an object');
    Exit(False);
  end;
  Options := JsAsObject(Value);
  Result := True;
end;

function AlphabetOption(R: TJsRealm; Options: TJsObject; out Url: Boolean): Boolean;
var
  Value: TJsValue;
begin
  Url := False;
  if Options = nil then
    Exit(True);
  Value := Options.GetValue(R, R.Intern('alphabet'));
  if Value = JsException then
    Exit(False);
  if Value = JsUndefined then
    Exit(True);
  if JsIsString(Value) and StringEqualsAscii(JsAsString(Value), 'base64url') then
    Url := True
  else if not (JsIsString(Value) and StringEqualsAscii(JsAsString(Value), 'base64')) then
  begin
    R.ThrowTypeError('alphabet must be "base64" or "base64url"');
    Exit(False);
  end;
  Result := True;
end;

function LastChunkOption(R: TJsRealm; Options: TJsObject; out Handling: TLastChunkHandling): Boolean;
var
  Value: TJsValue;
  Text: TJsString;
begin
  Handling := lcLoose;
  if Options = nil then
    Exit(True);
  Value := Options.GetValue(R, R.Intern('lastChunkHandling'));
  if Value = JsException then
    Exit(False);
  if Value = JsUndefined then
    Exit(True);
  Result := False;
  if not JsIsString(Value) then
  begin
    R.ThrowTypeError('lastChunkHandling must be "loose", "strict" or "stop-before-partial"');
    Exit;
  end;
  Text := JsAsString(Value);
  if StringEqualsAscii(Text, 'strict') then
    Handling := lcStrict
  else if StringEqualsAscii(Text, 'stop-before-partial') then
    Handling := lcStopBeforePartial
  else if not StringEqualsAscii(Text, 'loose') then
  begin
    R.ThrowTypeError('lastChunkHandling must be "loose", "strict" or "stop-before-partial"');
    Exit;
  end;
  Result := True;
end;

function ThisUint8Array(R: TJsRealm; Value: TJsValue; out Target: TJsTypedArray): Boolean;
begin
  Target := nil;
  if not JsIsObject(Value) or not (JsAsObject(Value) is TJsTypedArray) or
    (TJsTypedArray(JsAsObject(Value)).ElementKind <> taUint8) then
  begin
    R.ThrowTypeError('Not a Uint8Array');
    Exit(False);
  end;
  Target := TJsTypedArray(JsAsObject(Value));
  Result := True;
end;

function NewUint8ArrayFrom(R: TJsRealm; const Bytes: TBytes): TJsValue;
var
  Target: TJsTypedArray;
begin
  Target := NewTypedArray(R, taUint8, Length(Bytes));
  if Target = nil then
    Exit(JsException);
  if Length(Bytes) > 0 then
    Move(Bytes[0], Target.ElementAddress(0)^, Length(Bytes));
  Result := JsObjectValue(Target);
end;

function ReadWrittenResult(R: TJsRealm; Read, Written: SizeInt): TJsValue;
var
  Outcome: TJsObject;
begin
  Outcome := R.NewPlainObject;
  Outcome.DefineData(R, R.Intern('read'), JsNumber(Read));
  Outcome.DefineData(R, R.Intern('written'), JsNumber(Written));
  Result := JsObjectValue(Outcome);
end;

{ Uint8Array.fromBase64 }
function FromBase64Function(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Options: TJsObject;
  Url: Boolean;
  Handling: TLastChunkHandling;
  Decoded: TDecodeResult;
begin
  if not JsIsString(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('fromBase64 expects a string'));
  if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) or not AlphabetOption(R, Options, Url) or
    not LastChunkOption(R, Options, Handling) then
    Exit(JsException);
  JsAsString(Args^[0]).Flatten(R.Heap);
  Decoded := FromBase64(JsAsString(Args^[0]), Url, Handling, High(SizeInt));
  if Decoded.Failed then
    Exit(R.ThrowError(ekSyntax, 'Invalid base64 string'));
  Result := NewUint8ArrayFrom(R, Decoded.Bytes);
end;

{ Uint8Array.fromHex }
function FromHexFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Decoded: TDecodeResult;
begin
  if not JsIsString(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('fromHex expects a string'));
  JsAsString(Args^[0]).Flatten(R.Heap);
  Decoded := FromHex(JsAsString(Args^[0]), High(SizeInt));
  if Decoded.Failed then
    Exit(R.ThrowError(ekSyntax, 'Invalid hex string'));
  Result := NewUint8ArrayFrom(R, Decoded.Bytes);
end;

{ setFromBase64 (Magic 0) and setFromHex (1). }
function SetFromFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Options: TJsObject;
  Url: Boolean;
  Handling: TLastChunkHandling;
  Decoded: TDecodeResult;
begin
  if not ThisUint8Array(R, This, Target) then
    Exit(JsException);
  if not JsIsString(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('expected a string'));
  JsAsString(Args^[0]).Flatten(R.Heap);
  if Callee.Magic = 0 then
  begin
    if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) or not AlphabetOption(R, Options, Url) or
      not LastChunkOption(R, Options, Handling) then
      Exit(JsException);
  end;
  if Target.IsOutOfBounds then
    Exit(R.ThrowTypeError('Uint8Array is detached or out of bounds'));
  if Callee.Magic = 0 then
    Decoded := FromBase64(JsAsString(Args^[0]), Url, Handling, Target.CurrentLength)
  else
    Decoded := FromHex(JsAsString(Args^[0]), Target.CurrentLength);
  if Length(Decoded.Bytes) > 0 then
    Move(Decoded.Bytes[0], Target.ElementAddress(0)^, Length(Decoded.Bytes));
  if Decoded.Failed then
  begin
    if Callee.Magic = 0 then
      Exit(R.ThrowError(ekSyntax, 'Invalid base64 string'));
    Exit(R.ThrowError(ekSyntax, 'Invalid hex string'));
  end;
  Result := ReadWrittenResult(R, Decoded.Read, Length(Decoded.Bytes));
end;

{ toBase64 }
function ToBase64Function(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Options: TJsObject;
  Url, OmitPadding: Boolean;
  Value: TJsValue;
  Alphabet, Text: string;
  Bytes: PByte;
  Count, Index, Position: SizeInt;
  Bits: LongWord;
begin
  if not ThisUint8Array(R, This, Target) then
    Exit(JsException);
  if not OptionsObject(R, Arg(Args, ArgCount, 0), Options) or not AlphabetOption(R, Options, Url) then
    Exit(JsException);
  OmitPadding := False;
  if Options <> nil then
  begin
    Value := Options.GetValue(R, R.Intern('omitPadding'));
    if Value = JsException then
      Exit(JsException);
    OmitPadding := ToBoolean(Value);
  end;
  if Target.IsOutOfBounds then
    Exit(R.ThrowTypeError('Uint8Array is detached or out of bounds'));
  if Url then
    Alphabet := UrlAlphabet
  else
    Alphabet := StandardAlphabet;
  Count := Target.CurrentLength;
  Bytes := Target.ElementAddress(0);
  SetLength(Text, ((Count + 2) div 3) * 4);
  Position := 0;
  Index := 0;
  while Index + 2 < Count do
  begin
    Bits := (LongWord(Bytes[Index]) shl 16) or (LongWord(Bytes[Index + 1]) shl 8) or Bytes[Index + 2];
    Text[Position + 1] := Alphabet[(Bits shr 18) + 1];
    Text[Position + 2] := Alphabet[((Bits shr 12) and 63) + 1];
    Text[Position + 3] := Alphabet[((Bits shr 6) and 63) + 1];
    Text[Position + 4] := Alphabet[(Bits and 63) + 1];
    Inc(Position, 4);
    Inc(Index, 3);
  end;
  if Index < Count then
  begin
    Bits := LongWord(Bytes[Index]) shl 16;
    if Index + 1 < Count then
      Bits := Bits or (LongWord(Bytes[Index + 1]) shl 8);
    Text[Position + 1] := Alphabet[(Bits shr 18) + 1];
    Text[Position + 2] := Alphabet[((Bits shr 12) and 63) + 1];
    Inc(Position, 2);
    if Index + 1 < Count then
    begin
      Text[Position + 1] := Alphabet[((Bits shr 6) and 63) + 1];
      Inc(Position);
    end
    else if not OmitPadding then
    begin
      Text[Position + 1] := '=';
      Inc(Position);
    end;
    if not OmitPadding then
    begin
      Text[Position + 1] := '=';
      Inc(Position);
    end;
  end;
  SetLength(Text, Position);
  Result := R.NewString(Text);
end;

{ toHex }
function ToHexFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Text: string;
  Bytes: PByte;
  Index: SizeInt;
begin
  if not ThisUint8Array(R, This, Target) then
    Exit(JsException);
  if Target.IsOutOfBounds then
    Exit(R.ThrowTypeError('Uint8Array is detached or out of bounds'));
  SetLength(Text, Target.CurrentLength * 2);
  Bytes := Target.ElementAddress(0);
  for Index := 0 to Target.CurrentLength - 1 do
  begin
    Text[Index * 2 + 1] := HexDigits[(Bytes[Index] shr 4) + 1];
    Text[Index * 2 + 2] := HexDigits[(Bytes[Index] and 15) + 1];
  end;
  Result := R.NewString(Text);
end;

procedure InstallBase64(R: TJsInterpreterRealm);
var
  Constructor_, Prototype: TJsObject;
begin
  Constructor_ := R.Intrinsics[inUint8Array];
  Prototype := R.Intrinsics[inUint8ArrayPrototype];
  DefineMethod(R, Constructor_, 'fromBase64', @FromBase64Function, 1);
  DefineMethod(R, Constructor_, 'fromHex', @FromHexFunction, 1);
  DefineMethod(R, Prototype, 'setFromBase64', @SetFromFunction, 1, 0);
  DefineMethod(R, Prototype, 'setFromHex', @SetFromFunction, 1, 1);
  DefineMethod(R, Prototype, 'toBase64', @ToBase64Function, 0);
  DefineMethod(R, Prototype, 'toHex', @ToHexFunction, 0);
end;

end.

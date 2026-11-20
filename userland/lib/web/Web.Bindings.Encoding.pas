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
  bindings/Encoding.webidl: TextEncoder and TextDecoder (Encoding
  Standard 7) over libweb's decoders, with the fatal and ignoreBOM
  options and streaming.

  Bytes cross as Uint8Array when the engine has typed arrays (looked up
  on the global object when needed); until then encode gives an array of
  numbers, and decode takes any array-like of bytes (and ArrayBuffer and
  views once they exist).
}
unit Web.Bindings.Encoding;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Encoding.Members.inc}

implementation

uses
  SysUtils,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders,
  Web.Encoding.DecoderFactory,
  Web.Bindings.Context;

type
  TTextDecoderData = class
  public
    Encoding: TTextEncoding;
    Fatal: Boolean;
    IgnoreBom: Boolean;
    BomSeen: Boolean;
    Streaming: Boolean;
    Decoder: TTextDecoder;
    destructor Destroy; override;
  end;

destructor TTextDecoderData.Destroy;
begin
  Decoder.Free;
  inherited Destroy;
end;

type
  { A TextEncoder has no state. }
  TTextEncoderData = class
  end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function GlobalConstructor(Context: TBindingContext; const Name: string): TJsValue;
begin
  Result := Context.Engine.GlobalObject.GetValue(Context.Engine.Realm, Context.Engine.Realm.Intern(Name));
  if not JsIsConstructor(Result) then
    Result := JsUndefined;
end;

{ A Uint8Array (or an array where there are no typed arrays) of Bytes. }
function ByteArrayValue(Context: TBindingContext; const Bytes: string): TJsValue;
var
  Items: TJsValueList;
  Index: Integer;
  Constructor_, Plain: TJsValue;
  Mark: Integer;
begin
  Items := nil;
  SetLength(Items, Length(Bytes));
  for Index := 1 to Length(Bytes) do
    Items[Index - 1] := JsInteger(Ord(Bytes[Index]));
  Plain := Context.NewArray(Items);
  Constructor_ := GlobalConstructor(Context, 'Uint8Array');
  if Constructor_ = JsUndefined then
    Exit(Plain);
  Mark := Context.Engine.Runtime.PushRoot(Plain);
  try
    Result := Context.Engine.Realm.Construct(Constructor_, @Plain, 1, Constructor_);
    if Result = JsException then
      raise EBindingPendingException.Create('');
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

function GetNumberProperty(Context: TBindingContext; Target: TJsValue; const Name: string): Double;
var
  Value: TJsValue;
begin
  Value := GetProperty(Context.Engine.Realm, Target, Context.Engine.Realm.Intern(Name));
  if Value = JsException then
    raise EBindingPendingException.Create('');
  if Value = JsUndefined then
    Exit(-1);
  if not ToDouble(Context.Engine.Realm, Value, Result) then
    raise EBindingPendingException.Create('');
end;

{ The bytes of a BufferSource or array-like value. }
function BytesOf(Context: TBindingContext; Value: TJsValue): string;
var
  R: TJsRealm;
  Target: TJsObject;
  Constructor_, View, Element: TJsValue;
  Count, Index: Int64;
  Number: Double;
  Mark: Integer;
  Arguments: array[0..2] of TJsValue;
begin
  Result := '';
  R := Context.Engine.Realm;
  if JsIsNullish(Value) then
    Exit;
  if not JsIsObject(Value) then
    raise EBindingTypeError.Create('the input is not a buffer');
  Target := JsAsObject(Value);
  View := Value;
  Mark := Context.Engine.Runtime.PushRoot(Value);
  try
    Constructor_ := GlobalConstructor(Context, 'Uint8Array');
    if (Constructor_ <> JsUndefined) and (Target.ObjectClass in [ocArrayBuffer, ocTypedArray, ocDataView]) then
    begin
      if Target.ObjectClass = ocArrayBuffer then
        View := R.Construct(Constructor_, @Value, 1, Constructor_)
      else
      begin
        Arguments[0] := GetProperty(R, Value, R.Intern('buffer'));
        Arguments[1] := JsNumber(GetNumberProperty(Context, Value, 'byteOffset'));
        Arguments[2] := JsNumber(GetNumberProperty(Context, Value, 'byteLength'));
        View := R.Construct(Constructor_, @Arguments[0], 3, Constructor_);
      end;
      if View = JsException then
        raise EBindingPendingException.Create('');
      Context.Engine.Runtime.PushRoot(View);
    end;
    Count := Trunc(GetNumberProperty(Context, View, 'length'));
    if Count < 0 then
      raise EBindingTypeError.Create('the input is not a buffer');
    SetLength(Result, Count);
    for Index := 0 to Count - 1 do
    begin
      Element := GetProperty(R, View, JsNumber(Index));
      if (Element = JsException) or not ToDouble(R, Element, Number) then
        raise EBindingPendingException.Create('');
      Result[Index + 1] := Chr(DoubleToUint32(Number) and $FF);
    end;
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

{ TextEncoder }

function TextEncoder_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).ConstructedObject(Call, TTextEncoderData.Create);
end;

function TextEncoder_get_encoding(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue('utf-8');
end;

function TextEncoder_encode(var Call: TBindingCall): TJsValue;
begin
  Result := ByteArrayValue(Context(Call), Call.Text(0));
end;

function Utf16UnitsOf(const Bytes: string; Start, Count: Integer): Integer;
begin
  { One UTF-16 unit per sequence, two for a four byte one. }
  if Count = 4 then
    Result := 2
  else
    Result := 1;
end;

function TextEncoder_encodeInto(var Call: TBindingCall): TJsValue;
var
  R: TJsRealm;
  Source: string;
  Destination, Summary: TJsValue;
  Capacity, Written, ReadUnits: Int64;
  Index, SequenceLength, Position: Integer;
  Lead: Byte;
  ResultObject: TJsObject;
begin
  R := Context(Call).Engine.Realm;
  Source := Call.Text(0);
  Destination := Call.Script(1);
  Capacity := Trunc(GetNumberProperty(Context(Call), Destination, 'length'));
  Written := 0;
  ReadUnits := 0;
  Index := 1;
  while Index <= Length(Source) do
  begin
    Lead := Ord(Source[Index]);
    if Lead < $80 then
      SequenceLength := 1
    else if Lead < $E0 then
      SequenceLength := 2
    else if Lead < $F0 then
      SequenceLength := 3
    else
      SequenceLength := 4;
    if Written + SequenceLength > Capacity then
      Break;
    for Position := 0 to SequenceLength - 1 do
      if not SetProperty(R, Destination, JsNumber(Written + Position), JsInteger(Ord(Source[Index + Position])),
        True) then
        raise EBindingPendingException.Create('');
    Inc(Written, SequenceLength);
    Inc(ReadUnits, Utf16UnitsOf(Source, Index, SequenceLength));
    Inc(Index, SequenceLength);
  end;
  ResultObject := R.NewPlainObject;
  Summary := JsObjectValue(ResultObject);
  ResultObject.CreateDataProperty(R, R.Intern('read'), JsNumber(ReadUnits));
  ResultObject.CreateDataProperty(R, R.Intern('written'), JsNumber(Written));
  Result := Summary;
end;

{ TextDecoder }

function ThisDecoder(const Call: TBindingCall): TTextDecoderData; inline;
begin
  Result := TTextDecoderData(Call.Target);
end;

function TextDecoder_constructor(var Call: TBindingCall): TJsValue;
var
  Data: TTextDecoderData;
  Encoding: TTextEncoding;
begin
  if not EncodingForLabel(Trim(Call.Text(0)), Encoding) or (Encoding = TextEncodingReplacement) then
    raise EBindingRangeError.Create('''' + Call.Text(0) + ''' is not a supported encoding');
  if not IsDecodableEncoding(Encoding) then
    raise EBindingRangeError.Create('''' + Call.Text(0) + ''' cannot be decoded yet');
  Data := TTextDecoderData.Create;
  Data.Encoding := Encoding;
  Data.Fatal := Call.Arguments[1].Items[TextDecoderOptions_fatal].Flag;
  Data.IgnoreBom := Call.Arguments[1].Items[TextDecoderOptions_ignoreBOM].Flag;
  Data.Decoder := CreateDecoder(Encoding);
  Result := Context(Call).ConstructedObject(Call, Data);
end;

function TextDecoder_get_encoding(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(AnsiLowerCase(EncodingName(ThisDecoder(Call).Encoding)));
end;

function TextDecoder_get_fatal(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisDecoder(Call).Fatal);
end;

function TextDecoder_get_ignoreBOM(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisDecoder(Call).IgnoreBom);
end;

function TextDecoder_decode(var Call: TBindingCall): TJsValue;
var
  Data: TTextDecoderData;
  Bytes, Text: string;
  Output: TTextBuffer;
  Errors: SizeInt;
  Stream: Boolean;
begin
  Data := ThisDecoder(Call);
  Bytes := BytesOf(Context(Call), Call.Script(0));
  Stream := Call.Arguments[1].Items[TextDecodeOptions_stream].Flag;
  if not Data.Streaming then
  begin
    Data.Decoder.Reset;
    Data.BomSeen := False;
  end;
  Data.Streaming := Stream;
  Errors := Data.Decoder.ErrorCount;
  Output := TTextBuffer.Create;
  try
    if Length(Bytes) > 0 then
      Data.Decoder.Decode(PByte(PChar(Bytes)), Length(Bytes), Output, not Stream)
    else
      Data.Decoder.Decode(nil, 0, Output, not Stream);
    Text := Output.Text;
  finally
    Output.Free;
  end;
  if Data.Fatal and (Data.Decoder.ErrorCount <> Errors) then
  begin
    Data.Decoder.Reset;
    Data.Streaming := False;
    raise EBindingTypeError.Create('the input is not valid ' + EncodingName(Data.Encoding));
  end;
  if not Data.IgnoreBom and not Data.BomSeen and (Text <> '') and
    (Data.Encoding in [TextEncodingUtf8, TextEncodingUtf16Le, TextEncodingUtf16Be]) and
    (Copy(Text, 1, 3) = #$EF#$BB#$BF) then
    Delete(Text, 1, 3);
  if Text <> '' then
    Data.BomSeen := True;
  Result := Context(Call).TextValue(Text);
end;

end.

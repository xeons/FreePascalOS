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
  ArrayBuffer (resizable, transfer, detached), SharedArrayBuffer
  (growable; one thread, so plain memory) and DataView.

  transfer() hands the old buffer's memory to the new one when it can
  (no copy), reallocating only when the length changes.
}
unit Js.Builtins.ArrayBuffer;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
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
  Js.ArrayBuffers,
  Js.Interpreter;

procedure InstallArrayBuffer(R: TJsInterpreterRealm);

implementation

uses
  SysUtils;

const
  { Magic numbers of the shared callbacks. }
  BufferPlain = 0;
  BufferShared = 1;

function ThisBuffer(R: TJsRealm; const This: TJsValue; Shared: Boolean; const Method: string;
  out Buffer: TJsArrayBuffer): Boolean;
begin
  Buffer := nil;
  if JsIsObject(This) and (JsAsObject(This) is TJsArrayBuffer) and
    (TJsArrayBuffer(JsAsObject(This)).Shared = Shared) then
  begin
    Buffer := TJsArrayBuffer(JsAsObject(This));
    Exit(True);
  end;
  if Shared then
    R.ThrowTypeError('Method SharedArrayBuffer.prototype.' + Method + ' called on incompatible receiver')
  else
    R.ThrowTypeError('Method ArrayBuffer.prototype.' + Method + ' called on incompatible receiver');
  Result := False;
end;

{ The maxByteLength option: -1 when absent. }
function MaxByteLengthOption(R: TJsRealm; Options: TJsValue; out MaxByteLength: Int64): Boolean;
var
  Value: TJsValue;
begin
  MaxByteLength := -1;
  if not JsIsObject(Options) then
    Exit(True);
  Value := JsAsObject(Options).GetValue(R, R.Intern('maxByteLength'));
  if Value = JsException then
    Exit(False);
  if Value = JsUndefined then
    Exit(True);
  Result := ToIndex(R, Value, MaxByteLength);
end;

function BufferConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  ByteLength, MaxByteLength: Int64;
  Prototype: TJsObject;
  Buffer: TJsArrayBuffer;
  Shared: Boolean;
begin
  Shared := Callee.Magic = BufferShared;
  if NewTarget = JsUndefined then
  begin
    if Shared then
      Exit(R.ThrowTypeError('Constructor SharedArrayBuffer requires ''new'''));
    Exit(R.ThrowTypeError('Constructor ArrayBuffer requires ''new'''));
  end;
  if not ToIndex(R, Arg(Args, ArgCount, 0), ByteLength) then
    Exit(JsException);
  if not MaxByteLengthOption(R, Arg(Args, ArgCount, 1), MaxByteLength) then
    Exit(JsException);
  if (MaxByteLength >= 0) and (ByteLength > MaxByteLength) then
    Exit(R.ThrowRangeError('Invalid array buffer length'));
  if Shared then
    Prototype := PrototypeFromConstructor(R, NewTarget, inSharedArrayBufferPrototype)
  else
    Prototype := PrototypeFromConstructor(R, NewTarget, inArrayBufferPrototype);
  if Prototype = nil then
    Exit(JsException);
  if (ByteLength > MaximumArrayBufferLength) or (MaxByteLength > MaximumArrayBufferLength) then
    Exit(R.ThrowRangeError('Array buffer allocation failed'));
  Buffer := NewArrayBuffer(R, Prototype, ByteLength, MaxByteLength, Shared);
  if Buffer = nil then
    Exit(JsException);
  Result := JsObjectValue(Buffer);
end;

function BufferIsView(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  Value := Arg(Args, ArgCount, 0);
  Result := JsBoolean(JsIsObject(Value) and ((JsAsObject(Value) is TJsTypedArray) or
    (JsAsObject(Value) is TJsDataView)));
end;

function SpeciesGetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

const
  PropertyByteLength = 0;
  PropertyMaxByteLength = 1;
  PropertyResizable = 2;
  PropertyDetached = 3;

{ Magic: property * 2 + shared. }
function BufferProperty(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Names: array[0..3] of string = ('byteLength', 'maxByteLength', 'resizable', 'detached');
var
  Buffer: TJsArrayBuffer;
begin
  if not ThisBuffer(R, This, (Callee.Magic and 1) <> 0, Names[Callee.Magic shr 1], Buffer) then
    Exit(JsException);
  case Callee.Magic shr 1 of
    PropertyByteLength: Result := JsNumber(Buffer.ByteLength);
    PropertyMaxByteLength:
      if Buffer.Detached then
        Result := JsInteger(0)
      else
        Result := JsNumber(Buffer.MaxByteLength);
    PropertyResizable: Result := JsBoolean(Buffer.Resizable);
  else
    Result := JsBoolean(Buffer.Detached);
  end;
end;

function BufferResize(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Buffer: TJsArrayBuffer;
  NewLength: Int64;
  Shared: Boolean;
begin
  Shared := Callee.Magic = BufferShared;
  if Shared then
  begin
    if not ThisBuffer(R, This, True, 'grow', Buffer) then
      Exit(JsException);
    if not Buffer.Resizable then
      Exit(R.ThrowTypeError('SharedArrayBuffer is not growable'));
  end
  else
  begin
    if not ThisBuffer(R, This, False, 'resize', Buffer) then
      Exit(JsException);
    if not Buffer.Resizable then
      Exit(R.ThrowTypeError('ArrayBuffer is not resizable'));
  end;
  if not ToIndex(R, Arg(Args, ArgCount, 0), NewLength) then
    Exit(JsException);
  if Buffer.Detached then
    Exit(R.ThrowTypeError('ArrayBuffer is detached'));
  if NewLength > Buffer.MaxByteLength then
    Exit(R.ThrowRangeError('Invalid array buffer length'));
  if Shared and (NewLength < Buffer.ByteLength) then
    Exit(R.ThrowRangeError('SharedArrayBuffer cannot shrink'));
  if Assigned(Buffer.HostResize) then
  begin
    if not Buffer.HostResize(Buffer, NewLength) then
      Exit(R.ThrowRangeError('The buffer cannot be resized to that length'));
    Exit(JsUndefined);
  end;
  if not ResizeArrayBuffer(R, Buffer, NewLength) then
    Exit(R.ThrowRangeError('Array buffer allocation failed'));
  Result := JsUndefined;
end;

function BufferSlice(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Buffer, Created: TJsArrayBuffer;
  Shared: Boolean;
  First, Final, NewLength, Count: Int64;
  Constructor_, Made: TJsValue;
  Argument: TJsValue;
  Mark: Integer;
begin
  Shared := Callee.Magic = BufferShared;
  if not ThisBuffer(R, This, Shared, 'slice', Buffer) then
    Exit(JsException);
  if Buffer.Detached then
    Exit(R.ThrowTypeError('Cannot perform ArrayBuffer.prototype.slice on a detached ArrayBuffer'));
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Buffer.ByteLength, 0, First) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Buffer.ByteLength, Buffer.ByteLength, Final) then
    Exit(JsException);
  NewLength := Final - First;
  if NewLength < 0 then
    NewLength := 0;
  if Shared then
    Constructor_ := SpeciesConstructor(R, Buffer, JsObjectValue(R.Intrinsics[inSharedArrayBuffer]))
  else
    Constructor_ := SpeciesConstructor(R, Buffer, JsObjectValue(R.Intrinsics[inArrayBuffer]));
  if Constructor_ = JsException then
    Exit(JsException);
  Argument := JsNumber(NewLength);
  Made := R.Construct(Constructor_, @Argument, 1, Constructor_);
  if Made = JsException then
    Exit(JsException);
  if not JsIsObject(Made) or not (JsAsObject(Made) is TJsArrayBuffer) or
    (TJsArrayBuffer(JsAsObject(Made)).Shared <> Shared) then
    Exit(R.ThrowTypeError('Species constructor did not return an ArrayBuffer'));
  Created := TJsArrayBuffer(JsAsObject(Made));
  if Created.Detached then
    Exit(R.ThrowTypeError('Species constructor returned a detached ArrayBuffer'));
  if Created = Buffer then
    Exit(R.ThrowTypeError('Species constructor returned the same ArrayBuffer'));
  if Created.ByteLength < NewLength then
    Exit(R.ThrowTypeError('Species constructor returned a too small ArrayBuffer'));
  if Buffer.Detached then
    Exit(R.ThrowTypeError('ArrayBuffer was detached'));
  Mark := R.Runtime.PushRoot(Made);
  if First < Buffer.ByteLength then
  begin
    Count := Buffer.ByteLength - First;
    if Count > NewLength then
      Count := NewLength;
    if Count > 0 then
      Move((Buffer.Data + First)^, Created.Data^, Count);
  end;
  R.Runtime.PopRoots(Mark);
  Result := Made;
end;

{ transfer (Magic 0) and transferToFixedLength (1). }
function BufferTransfer(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Buffer, Created: TJsArrayBuffer;
  NewLength, MaxLength: Int64;
  Method: string;
begin
  if Callee.Magic = 0 then
    Method := 'transfer'
  else
    Method := 'transferToFixedLength';
  if not ThisBuffer(R, This, False, Method, Buffer) then
    Exit(JsException);
  if Arg(Args, ArgCount, 0) = JsUndefined then
    NewLength := Buffer.ByteLength
  else if not ToIndex(R, Arg(Args, ArgCount, 0), NewLength) then
    Exit(JsException);
  if Buffer.Detached then
    Exit(R.ThrowTypeError('Cannot perform ArrayBuffer.prototype.' + Method + ' on a detached ArrayBuffer'));
  if Buffer.HostDetachOnly then
    Exit(R.ThrowTypeError('Cannot perform ArrayBuffer.prototype.' + Method + ' on an ArrayBuffer that cannot be detached'));
  MaxLength := -1;
  if (Callee.Magic = 0) and Buffer.Resizable then
    MaxLength := Buffer.MaxByteLength;
  if (MaxLength >= 0) and (NewLength > MaxLength) then
    Exit(R.ThrowRangeError('Invalid array buffer length'));
  if NewLength > MaximumArrayBufferLength then
    Exit(R.ThrowRangeError('Array buffer allocation failed'));
  Created := NewArrayBuffer(R, R.Intrinsics[inArrayBufferPrototype], 0, MaxLength, False);
  if Created = nil then
    Exit(JsException);
  { The memory moves over; only a change of length copies. }
  Created.Data := Buffer.Data;
  Created.ByteLength := Buffer.ByteLength;
  Created.External := Buffer.External;
  Created.FreeProc := Buffer.FreeProc;
  Created.FreeContext := Buffer.FreeContext;
  Buffer.ReleaseData;
  if not ResizeArrayBuffer(R, Created, NewLength) then
    Exit(R.ThrowRangeError('Array buffer allocation failed'));
  if MaxLength < 0 then
    Created.MaxByteLength := Created.ByteLength;
  Result := JsObjectValue(Created);
end;

{ DataView }

function ViewConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  BufferValue: TJsValue;
  Buffer: TJsArrayBuffer;
  Offset, ViewLength: Int64;
  Tracking: Boolean;
  Prototype: TJsObject;
  View: TJsDataView;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor DataView requires ''new'''));
  BufferValue := Arg(Args, ArgCount, 0);
  if not JsIsObject(BufferValue) or not (JsAsObject(BufferValue) is TJsArrayBuffer) then
    Exit(R.ThrowTypeError('First argument to DataView constructor must be an ArrayBuffer'));
  Buffer := TJsArrayBuffer(JsAsObject(BufferValue));
  if not ToIndex(R, Arg(Args, ArgCount, 1), Offset) then
    Exit(JsException);
  if Buffer.Detached then
    Exit(R.ThrowTypeError('Cannot construct a DataView on a detached ArrayBuffer'));
  if Offset > Buffer.ByteLength then
    Exit(R.ThrowRangeError('Start offset ' + IntToStr(Offset) + ' is outside the bounds of the buffer'));
  Tracking := False;
  ViewLength := 0;
  if Arg(Args, ArgCount, 2) = JsUndefined then
  begin
    if Buffer.Resizable then
      Tracking := True
    else
      ViewLength := Buffer.ByteLength - Offset;
  end
  else
  begin
    if not ToIndex(R, Arg(Args, ArgCount, 2), ViewLength) then
      Exit(JsException);
    if Offset + ViewLength > Buffer.ByteLength then
      Exit(R.ThrowRangeError('Invalid DataView length ' + IntToStr(ViewLength)));
  end;
  Prototype := PrototypeFromConstructor(R, NewTarget, inDataViewPrototype);
  if Prototype = nil then
    Exit(JsException);
  if Buffer.Detached then
    Exit(R.ThrowTypeError('Cannot construct a DataView on a detached ArrayBuffer'));
  if Offset > Buffer.ByteLength then
    Exit(R.ThrowRangeError('Start offset is outside the bounds of the buffer'));
  if not Tracking and (Offset + ViewLength > Buffer.ByteLength) then
    Exit(R.ThrowRangeError('Invalid DataView length'));
  View := TJsDataView(R.NewObjectOfClass(TJsDataView, Prototype, ocDataView));
  View.Buffer := Buffer;
  View.ByteOffset := Offset;
  View.FixedByteLength := ViewLength;
  View.LengthTracking := Tracking;
  Result := JsObjectValue(View);
end;

function ThisView(R: TJsRealm; const This: TJsValue; const Method: string; out View: TJsDataView): Boolean;
begin
  View := nil;
  if JsIsObject(This) and (JsAsObject(This) is TJsDataView) then
  begin
    View := TJsDataView(JsAsObject(This));
    Exit(True);
  end;
  R.ThrowTypeError('Method DataView.prototype.' + Method + ' called on incompatible receiver');
  Result := False;
end;

{ buffer (0), byteLength (1), byteOffset (2). }
function ViewProperty(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Names: array[0..2] of string = ('buffer', 'byteLength', 'byteOffset');
var
  View: TJsDataView;
  Length: SizeInt;
begin
  if not ThisView(R, This, Names[Callee.Magic], View) then
    Exit(JsException);
  if Callee.Magic = 0 then
    Exit(JsObjectValue(View.Buffer));
  Length := View.CurrentByteLength;
  if Length < 0 then
    Exit(R.ThrowTypeError('DataView is out of bounds'));
  if Callee.Magic = 1 then
    Result := JsNumber(Length)
  else
    Result := JsNumber(View.ByteOffset);
end;

procedure ReverseBytes(Bytes: PByte; Count: Integer);
var
  Low, High: Integer;
  Swap: Byte;
begin
  Low := 0;
  High := Count - 1;
  while Low < High do
  begin
    Swap := Bytes[Low];
    Bytes[Low] := Bytes[High];
    Bytes[High] := Swap;
    Inc(Low);
    Dec(High);
  end;
end;

function HostIsLittleEndian: Boolean; inline;
begin
  {$ifdef ENDIAN_LITTLE}
  Result := True;
  {$else}
  Result := False;
  {$endif}
end;

{ getInt8 ... getBigUint64: Magic is the element kind. }
function ViewGet(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  View: TJsDataView;
  Index: Int64;
  LittleEndian: Boolean;
  Kind: TJsTypedArrayKind;
  Size: Integer;
  Length: SizeInt;
  Bytes: array[0..7] of Byte;
begin
  Kind := TJsTypedArrayKind(Callee.Magic);
  if not ThisView(R, This, 'get', View) then
    Exit(JsException);
  if not ToIndex(R, Arg(Args, ArgCount, 0), Index) then
    Exit(JsException);
  LittleEndian := ToBoolean(Arg(Args, ArgCount, 1));
  Length := View.CurrentByteLength;
  if Length < 0 then
    Exit(R.ThrowTypeError('DataView is out of bounds'));
  Size := TypedArrayElementSizes[Kind];
  if Index + Size > Length then
    Exit(R.ThrowRangeError('Offset is outside the bounds of the DataView'));
  Move((View.Buffer.Data + View.ByteOffset + Index)^, Bytes[0], Size);
  if LittleEndian <> HostIsLittleEndian then
    ReverseBytes(@Bytes[0], Size);
  Result := ReadElement(R, Kind, @Bytes[0]);
end;

function ViewSet(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  View: TJsDataView;
  Index: Int64;
  LittleEndian: Boolean;
  Kind: TJsTypedArrayKind;
  Size: Integer;
  Length: SizeInt;
  Value: TJsValue;
  Bytes: array[0..7] of Byte;
begin
  Kind := TJsTypedArrayKind(Callee.Magic);
  if not ThisView(R, This, 'set', View) then
    Exit(JsException);
  if not ToIndex(R, Arg(Args, ArgCount, 0), Index) then
    Exit(JsException);
  Value := ConvertForKind(R, Kind, Arg(Args, ArgCount, 1));
  if Value = JsException then
    Exit(JsException);
  LittleEndian := ToBoolean(Arg(Args, ArgCount, 2));
  Length := View.CurrentByteLength;
  if Length < 0 then
    Exit(R.ThrowTypeError('DataView is out of bounds'));
  Size := TypedArrayElementSizes[Kind];
  if Index + Size > Length then
    Exit(R.ThrowRangeError('Offset is outside the bounds of the DataView'));
  WriteElement(R, Kind, @Bytes[0], Value);
  if LittleEndian <> HostIsLittleEndian then
    ReverseBytes(@Bytes[0], Size);
  Move(Bytes[0], (View.Buffer.Data + View.ByteOffset + Index)^, Size);
  Result := JsUndefined;
end;

procedure InstallArrayBuffer(R: TJsInterpreterRealm);
const
  ViewKinds: array[0..10] of TJsTypedArrayKind = (taInt8, taUint8, taInt16, taUint16, taInt32, taUint32,
    taFloat16, taFloat32, taFloat64, taBigInt64, taBigUint64);
  ViewNames: array[0..10] of string = ('Int8', 'Uint8', 'Int16', 'Uint16', 'Int32', 'Uint32', 'Float16',
    'Float32', 'Float64', 'BigInt64', 'BigUint64');
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
  Species: TJsNativeFunction;
  Index: Integer;
begin
  Species := NewNativeFunction(R, 'get [Symbol.species]', @SpeciesGetter, 0);

  Prototype := R.Intrinsics[inArrayBufferPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'ArrayBuffer', @BufferConstructor, 1, Prototype);
  Constructor_.Magic := BufferPlain;
  R.Intrinsics[inArrayBuffer] := Constructor_;
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies), JsObjectValue(Species), JsUndefined,
    PropertyConfigurable);
  DefineMethod(R, Constructor_, 'isView', @BufferIsView, 1);
  DefineGetter(R, Prototype, 'byteLength', @BufferProperty, PropertyByteLength * 2);
  DefineGetter(R, Prototype, 'maxByteLength', @BufferProperty, PropertyMaxByteLength * 2);
  DefineGetter(R, Prototype, 'resizable', @BufferProperty, PropertyResizable * 2);
  DefineGetter(R, Prototype, 'detached', @BufferProperty, PropertyDetached * 2);
  DefineMethod(R, Prototype, 'resize', @BufferResize, 1, BufferPlain);
  DefineMethod(R, Prototype, 'slice', @BufferSlice, 2, BufferPlain);
  DefineMethod(R, Prototype, 'transfer', @BufferTransfer, 0, 0);
  DefineMethod(R, Prototype, 'transferToFixedLength', @BufferTransfer, 0, 1);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('ArrayBuffer'), PropertyConfigurable);

  Prototype := R.NewObject(R.Intrinsics[inObjectPrototype]);
  R.Intrinsics[inSharedArrayBufferPrototype] := Prototype;
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'SharedArrayBuffer', @BufferConstructor, 1, Prototype);
  Constructor_.Magic := BufferShared;
  R.Intrinsics[inSharedArrayBuffer] := Constructor_;
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies), JsObjectValue(Species), JsUndefined,
    PropertyConfigurable);
  DefineGetter(R, Prototype, 'byteLength', @BufferProperty, PropertyByteLength * 2 + 1);
  DefineGetter(R, Prototype, 'maxByteLength', @BufferProperty, PropertyMaxByteLength * 2 + 1);
  DefineGetter(R, Prototype, 'growable', @BufferProperty, PropertyResizable * 2 + 1);
  DefineMethod(R, Prototype, 'grow', @BufferResize, 1, BufferShared);
  DefineMethod(R, Prototype, 'slice', @BufferSlice, 2, BufferShared);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('SharedArrayBuffer'),
    PropertyConfigurable);

  Prototype := R.Intrinsics[inDataViewPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'DataView', @ViewConstructor, 1, Prototype);
  R.Intrinsics[inDataView] := Constructor_;
  DefineGetter(R, Prototype, 'buffer', @ViewProperty, 0);
  DefineGetter(R, Prototype, 'byteLength', @ViewProperty, 1);
  DefineGetter(R, Prototype, 'byteOffset', @ViewProperty, 2);
  for Index := 0 to High(ViewKinds) do
  begin
    DefineMethod(R, Prototype, 'get' + ViewNames[Index], @ViewGet, 1, Ord(ViewKinds[Index]));
    DefineMethod(R, Prototype, 'set' + ViewNames[Index], @ViewSet, 2, Ord(ViewKinds[Index]));
  end;
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('DataView'), PropertyConfigurable);
end;

end.

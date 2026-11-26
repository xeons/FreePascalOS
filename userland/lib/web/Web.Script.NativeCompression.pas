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
  The natives behind CompressionStream and DecompressionStream
  (platform/41-compression.js), over libcompression's deflater and
  inflater:

    natives.compressBytes(format, bytes)    the whole compressed stream
    natives.decompressBytes(format, bytes, final)
                                            what bytes decompress to; a
                                            TypeError when the data is
                                            broken or followed by
                                            anything, and (final) when it
                                            is cut short

  Format is "deflate" (zlib), "deflate-raw", "gzip" (one member) or
  "brotli" (decoded fully; compressed as stored meta-blocks, as there is
  no brotli encoder yet).
}
unit Web.Script.NativeCompression;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineCompressionNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Js.Conversions,
  Compression.Formats,
  Compression.Deflater,
  Compression.Inflater,
  Compression.StreamingDecoders,
  Compression.BrotliDecoder,
  Compression.BrotliStored,
  Web.Bindings.Types;

const
  ChunkSize = 64 * 1024;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

const
  BrotliFormatName = 'brotli';

function FormatOf(const Name: string): TCompressionFormat;
begin
  if Name = 'deflate' then
    Result := FormatZlib
  else if Name = 'deflate-raw' then
    Result := FormatRaw
  else if Name = 'gzip' then
    Result := FormatGzip
  else
    raise EBindingTypeError.Create('Unsupported compression format: ''' + Name + '''');
end;

procedure InputOf(Context: TBindingContext; Value: TJsValue; out Data: PByte; out Count: SizeInt);
begin
  if not Context.Engine.BufferSourceData(Value, Data, Count) then
  begin
    Data := nil;
    Count := 0;
  end;
end;

procedure Append(var Output: TBytes; var Used: SizeInt; const Buffer: TBytes; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  if Used + Count > Length(Output) then
    SetLength(Output, 2 * (Used + Count));
  Move(Buffer[0], Output[Used], Count);
  Inc(Used, Count);
end;

function BytesValue(Context: TBindingContext; const Output: TBytes; Used: SizeInt): TJsValue;
begin
  if Used = 0 then
    Result := Context.Engine.NewUint8Array(nil, 0)
  else
    Result := Context.Engine.NewUint8Array(@Output[0], Used);
end;

function NativeCompressBytes(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Deflater: TDeflater;
  Data: PByte;
  Count, Written, Used: SizeInt;
  Buffer, Output: TBytes;
begin
  Context := ContextOfRealm(R);
  try
    if Context.Engine.ToText(Arg(Args, ArgCount, 0)) = BrotliFormatName then
    begin
      InputOf(Context, Arg(Args, ArgCount, 1), Data, Count);
      Output := StoreAsBrotli(Data, Count);
      Exit(BytesValue(Context, Output, Length(Output)));
    end;
    Deflater := TDeflater.Create(FormatOf(Context.Engine.ToText(Arg(Args, ArgCount, 0))), CompressionLevelDefault);
    try
      InputOf(Context, Arg(Args, ArgCount, 1), Data, Count);
      if Count > 0 then
        Deflater.SetInput(Data, Count);
      SetLength(Buffer, ChunkSize);
      Output := nil;
      Used := 0;
      while Deflater.Compress(@Buffer[0], ChunkSize, Written, True) <> DeflateFinished do
        Append(Output, Used, Buffer, Written);
      Append(Output, Used, Buffer, Written);
      Result := BytesValue(Context, Output, Used);
    finally
      Deflater.Free;
    end;
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function DecompressBrotli(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Decoder: TBrotliDecoder;
  Data: PByte;
  Count, Written, Used: SizeInt;
  Buffer, Output: TBytes;
  Outcome: TDecompressResult;
begin
  Decoder := TBrotliDecoder.Create;
  try
    InputOf(Context, Arg(Args, ArgCount, 1), Data, Count);
    if Count > 0 then
      Decoder.SetInput(Data, Count);
    SetLength(Buffer, ChunkSize);
    Output := nil;
    Used := 0;
    repeat
      Outcome := Decoder.Decompress(@Buffer[0], ChunkSize, Written);
      Append(Output, Used, Buffer, Written);
    until Outcome <> DecompressOutputFull;
    if Outcome = DecompressFailed then
      raise EBindingTypeError.Create('The compressed data is not valid');
    if (Outcome <> DecompressFinished) and ToBoolean(Arg(Args, ArgCount, 2)) then
      raise EBindingTypeError.Create('The compressed data ends too soon');
    if (Outcome = DecompressFinished) and (Decoder.InputRemaining > 0) then
      raise EBindingTypeError.Create('Data follows the end of the compressed data');
    Result := BytesValue(Context, Output, Used);
  finally
    Decoder.Free;
  end;
end;

function NativeDecompressBytes(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Inflater: TInflater;
  Data: PByte;
  Count, Written, Used: SizeInt;
  Buffer, Output: TBytes;
  Outcome: TInflateResult;
begin
  Context := ContextOfRealm(R);
  try
    if Context.Engine.ToText(Arg(Args, ArgCount, 0)) = BrotliFormatName then
      Exit(DecompressBrotli(Context, Args, ArgCount));
    Inflater := TInflater.Create(FormatOf(Context.Engine.ToText(Arg(Args, ArgCount, 0))));
    try
      Inflater.ConcatenatedMembers := False;
      InputOf(Context, Arg(Args, ArgCount, 1), Data, Count);
      if Count > 0 then
        Inflater.SetInput(Data, Count);
      SetLength(Buffer, ChunkSize);
      Output := nil;
      Used := 0;
      repeat
        Outcome := Inflater.Decompress(@Buffer[0], ChunkSize, Written);
        Append(Output, Used, Buffer, Written);
      until Outcome <> InflateOutputFull;
      if Outcome = InflateFailed then
        raise EBindingTypeError.Create('The compressed data is not valid');
      if (Outcome <> InflateFinished) and ToBoolean(Arg(Args, ArgCount, 2)) then
        raise EBindingTypeError.Create('The compressed data ends too soon');
      if Inflater.InputRemaining > 0 then
        raise EBindingTypeError.Create('Data follows the end of the compressed data');
      Result := BytesValue(Context, Output, Used);
    finally
      Inflater.Free;
    end;
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

procedure DefineCompressionNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'compressBytes', @NativeCompressBytes, 2);
  Context.Engine.DefineFunction(Natives, 'decompressBytes', @NativeDecompressBytes, 3);
end;

end.

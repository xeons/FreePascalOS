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
  Content codings (RFC 9110 section 8.4.1) undone as the content
  arrives, in pieces, through libcompression's streaming decoders:

    gzip, x-gzip   gzip members (several in a row are taken)
    deflate        zlib data; raw deflate data (which some servers send
                   for "deflate") when the first two bytes are not a
                   zlib header
    br             brotli (RFC 7932), TBrotliDecoder
    zstd           Zstandard frames (RFC 8878, several in a row are
                   taken), TZstdDecoder
    identity       nothing to do

  SupportedAcceptEncoding lists exactly the codings compiled in (the
  DecodeBrotli and DecodeZstandard switches below); a coding left out is
  neither offered nor accepted.

  A coding list ("gzip, deflate" as applied) is undone last first, each
  decoder a sink in front of the next.

  Plain Pascal (the RTL and libcompression), checked on the host by
  tools/HttpTest.
}
unit Http.ContentDecoding;

{$mode objfpc}
{$H+}

interface

{$define DecodeBrotli}
{$define DecodeZstandard}

uses
  Compression.StreamingDecoders,
  Http.BodySinks;

const
  { What a client sends as Accept-Encoding: the codings undone here. }
  SupportedAcceptEncoding = 'gzip, deflate'
    {$ifdef DecodeBrotli} + ', br' {$endif}
    {$ifdef DecodeZstandard} + ', zstd' {$endif};

type
  TContentCoding = (CodingIdentity, CodingGzip, CodingDeflate, CodingBrotli, CodingZstandard, CodingUnknown);

  THttpDecodingSink = class(THttpBodySink)
  private
    FNext: THttpBodySink;
    FOwnsNext: Boolean;
    FCoding: TContentCoding;
    FDecoder: TStreamingDecoder;
    FHeader: array[0..1] of Byte;
    FHeaderCount: Integer;
    function StartDeflate: Boolean;
    function Decode(Data: Pointer; Count: PtrUInt): Boolean;
    function PassOn(Data: Pointer; Count: PtrUInt): Boolean;
  public
    constructor Create(Next: THttpBodySink; Coding: TContentCoding; OwnsNext: Boolean = False);
    destructor Destroy; override;
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
    function Finish: Boolean; override;
  end;

function ContentCodingOf(const Name: string): TContentCoding;
{ Every coding of a Content-Encoding value can be undone. }
function ContentEncodingSupported(const ContentEncoding: string): Boolean;
{ Decoders for a Content-Encoding value in front of Final (not owned):
  Final itself when there is nothing to undo. nil when a coding is not
  supported. The chain is freed by freeing the result (unless it is
  Final). }
function CreateDecodingChain(Final: THttpBodySink; const ContentEncoding: string): THttpBodySink;

implementation

uses
  SysUtils,
  Compression.Formats,
  Compression.InflatingDecoders,
  {$ifdef DecodeBrotli} Compression.BrotliDecoder, {$endif}
  {$ifdef DecodeZstandard} Compression.ZstdDecoder, {$endif}
  Http.FieldValues;

const
  DecodeBufferSize = 32 * 1024;

function ContentCodingOf(const Name: string): TContentCoding;
var
  Lower: string;
begin
  Lower := LowerCase(Trim(Name));
  if (Lower = '') or (Lower = 'identity') then
    Result := CodingIdentity
  else if (Lower = 'gzip') or (Lower = 'x-gzip') then
    Result := CodingGzip
  else if Lower = 'deflate' then
    Result := CodingDeflate
  {$ifdef DecodeBrotli}
  else if Lower = 'br' then
    Result := CodingBrotli
  {$endif}
  {$ifdef DecodeZstandard}
  else if Lower = 'zstd' then
    Result := CodingZstandard
  {$endif}
  else
    Result := CodingUnknown;
end;

function ContentEncodingSupported(const ContentEncoding: string): Boolean;
var
  Name: string;
begin
  for Name in SplitFieldList(ContentEncoding) do
    if ContentCodingOf(Name) = CodingUnknown then
      Exit(False);
  Result := True;
end;

function CreateDecodingChain(Final: THttpBodySink; const ContentEncoding: string): THttpBodySink;
var
  Names: TStringArray;
  Index: Integer;
  Coding: TContentCoding;
begin
  if not ContentEncodingSupported(ContentEncoding) then
    Exit(nil);
  Result := Final;
  Names := SplitFieldList(ContentEncoding);
  { The first coding applied is undone last: it is nearest Final. }
  for Index := 0 to High(Names) do
  begin
    Coding := ContentCodingOf(Names[Index]);
    if Coding = CodingIdentity then
      Continue;
    Result := THttpDecodingSink.Create(Result, Coding, Result <> Final);
  end;
end;

constructor THttpDecodingSink.Create(Next: THttpBodySink; Coding: TContentCoding; OwnsNext: Boolean);
begin
  inherited Create;
  FNext := Next;
  FOwnsNext := OwnsNext;
  FCoding := Coding;
  case Coding of
    CodingGzip:
      FDecoder := TInflatingDecoder.Create(FormatGzip);
    {$ifdef DecodeBrotli}
    CodingBrotli:
      FDecoder := TBrotliDecoder.Create;
    {$endif}
    {$ifdef DecodeZstandard}
    CodingZstandard:
      FDecoder := TZstdDecoder.Create;
    {$endif}
  else
    { deflate: made when its first two bytes have come. }
    FDecoder := nil;
  end;
end;

destructor THttpDecodingSink.Destroy;
begin
  FDecoder.Free;
  if FOwnsNext then
    FNext.Free;
  inherited Destroy;
end;

function THttpDecodingSink.PassOn(Data: Pointer; Count: PtrUInt): Boolean;
begin
  Result := FNext.Write(Data, Count);
  if Result then
    Inc(FWritten, Count)
  else
  begin
    FErrorCode := FNext.ErrorCode;
    FDamagedData := FNext.DamagedData;
    FErrorText := FNext.ErrorText;
  end;
end;

{ "deflate": zlib when the first two bytes make a zlib header (method 8,
  the check bits right), raw deflate otherwise. }
function THttpDecodingSink.StartDeflate: Boolean;
var
  IsZlib: Boolean;
begin
  IsZlib := ((FHeader[0] and $0F) = 8) and ((FHeader[0] shr 4) <= 7) and
    (((LongWord(FHeader[0]) shl 8) or FHeader[1]) mod 31 = 0);
  if IsZlib then
    FDecoder := TInflatingDecoder.Create(FormatZlib)
  else
    FDecoder := TInflatingDecoder.Create(FormatRaw);
  Result := Decode(@FHeader[0], FHeaderCount);
end;

{ After the end of zlib, raw deflate or brotli data the rest is left
  alone; gzip members and zstd frames may follow one another. }
function THttpDecodingSink.Decode(Data: Pointer; Count: PtrUInt): Boolean;
var
  Buffer: array[0..DecodeBufferSize - 1] of Byte;
  Produced: SizeInt;
  Outcome: TDecompressResult;
begin
  Result := True;
  if (Count = 0) or (FDecoder.Finished and (FCoding in [CodingDeflate, CodingBrotli])) then
    Exit;
  FDecoder.SetInput(Data, Count);
  repeat
    Outcome := FDecoder.Decompress(@Buffer[0], SizeOf(Buffer), Produced);
    if Outcome = DecompressFailed then
    begin
      FDamagedData := True;
      FErrorText := 'damaged compressed data';
      Exit(False);
    end;
    if (Produced > 0) and not PassOn(@Buffer[0], Produced) then
      Exit(False);
  until Outcome <> DecompressOutputFull;
end;

function THttpDecodingSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
var
  Bytes: PByte;
begin
  if FCoding = CodingIdentity then
    Exit(PassOn(Data, Count));
  if FDecoder <> nil then
    Exit(Decode(Data, Count));
  { deflate: the first two bytes decide which. }
  Bytes := Data;
  while (Count > 0) and (FHeaderCount < 2) do
  begin
    FHeader[FHeaderCount] := Bytes^;
    Inc(FHeaderCount);
    Inc(Bytes);
    Dec(Count);
  end;
  if FHeaderCount < 2 then
    Exit(True);
  Result := StartDeflate and Decode(Bytes, Count);
end;

function THttpDecodingSink.Finish: Boolean;
begin
  if FCoding <> CodingIdentity then
  begin
    if (FDecoder = nil) and (FHeaderCount > 0) then
      StartDeflate;
    if (FDecoder = nil) or not FDecoder.Finished then
    begin
      FDamagedData := True;
      FErrorText := 'the compressed data ended early';
      Exit(False);
    end;
  end;
  Result := FNext.Finish;
end;

end.

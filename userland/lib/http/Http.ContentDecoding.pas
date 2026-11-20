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
  arrives, through libcompression's TInflater:

    gzip, x-gzip   gzip members (several in a row are taken)
    deflate        zlib data; raw deflate data (which some servers send
                   for "deflate") when the first two bytes are not a
                   zlib header
    identity       nothing to do

  Brotli ("br") is not offered: its decoder needs the 122 KiB static
  dictionary of RFC 7932, which is not in the tree yet; zstd neither.

  A coding list ("gzip, deflate" as applied) is undone last first, each
  decoder a sink in front of the next.

  Plain Pascal (the RTL and libcompression), checked on the host by
  tools/HttpTest.
}
unit Http.ContentDecoding;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Inflater,
  Http.BodySinks;

const
  { What a client sends as Accept-Encoding. }
  SupportedAcceptEncoding = 'gzip, deflate';

type
  TContentCoding = (CodingIdentity, CodingGzip, CodingDeflate, CodingUnknown);

  THttpDecodingSink = class(THttpBodySink)
  private
    FNext: THttpBodySink;
    FOwnsNext: Boolean;
    FCoding: TContentCoding;
    FInflater: TInflater;
    FHeader: array[0..1] of Byte;
    FHeaderCount: Integer;
    function StartInflater: Boolean;
    function Inflate(Data: Pointer; Count: PtrUInt): Boolean;
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
  Http.FieldValues;

const
  InflateBufferSize = 32 * 1024;

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
  if Coding = CodingGzip then
  begin
    FInflater := TInflater.Create(FormatGzip);
    FInflater.ConcatenatedMembers := True;
  end;
end;

destructor THttpDecodingSink.Destroy;
begin
  FInflater.Free;
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
function THttpDecodingSink.StartInflater: Boolean;
var
  IsZlib: Boolean;
begin
  IsZlib := ((FHeader[0] and $0F) = 8) and ((FHeader[0] shr 4) <= 7) and
    (((LongWord(FHeader[0]) shl 8) or FHeader[1]) mod 31 = 0);
  if IsZlib then
    FInflater := TInflater.Create(FormatZlib)
  else
    FInflater := TInflater.Create(FormatRaw);
  Result := Inflate(@FHeader[0], FHeaderCount);
end;

function THttpDecodingSink.Inflate(Data: Pointer; Count: PtrUInt): Boolean;
var
  Buffer: array[0..InflateBufferSize - 1] of Byte;
  Produced: SizeInt;
  Outcome: TInflateResult;
begin
  Result := True;
  if (Count = 0) or FInflater.Finished then
    Exit;
  FInflater.SetInput(Data, Count);
  repeat
    Outcome := FInflater.Decompress(@Buffer[0], SizeOf(Buffer), Produced);
    if Outcome = InflateFailed then
    begin
      FDamagedData := True;
      FErrorText := 'damaged compressed data';
      Exit(False);
    end;
    if (Produced > 0) and not PassOn(@Buffer[0], Produced) then
      Exit(False);
  until Outcome <> InflateOutputFull;
end;

function THttpDecodingSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
var
  Bytes: PByte;
begin
  if FCoding = CodingIdentity then
    Exit(PassOn(Data, Count));
  if FInflater <> nil then
    Exit(Inflate(Data, Count));
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
  Result := StartInflater and Inflate(Bytes, Count);
end;

function THttpDecodingSink.Finish: Boolean;
begin
  if FCoding <> CodingIdentity then
  begin
    if (FInflater = nil) and (FHeaderCount > 0) then
      StartInflater;
    if (FInflater = nil) or not FInflater.Finished then
    begin
      FDamagedData := True;
      FErrorText := 'the compressed data ended early';
      Exit(False);
    end;
  end;
  Result := FNext.Finish;
end;

end.

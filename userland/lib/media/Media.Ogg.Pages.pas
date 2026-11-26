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
  Ogg pages (RFC 3533): finding them in a stream and checking them.

  A page is the capture pattern "OggS", version 0, flags (continued,
  first, last), the granule position, the stream's serial number, the
  page sequence number, a CRC-32 (polynomial 0x04C11DB7, most significant
  bit first, computed with the field zeroed), and a segment table of up
  to 255 lacing values followed by the body. A packet is the segments up
  to and including one shorter than 255 bytes.

  TOggPageReader.ReadPageFrom looks for the next page at or after an offset, skipping
  bytes until a page whose checksum is right (resynchronising after
  damage); a page cut short by the end of the stream is not a page.
}
unit Media.Ogg.Pages;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

const
  OggFlagContinued = 1;
  OggFlagFirst = 2;
  OggFlagLast = 4;
  OggMaximumPageSize = 27 + 255 + 255 * 255;

type
  TOggPage = record
    { Where the page starts in the stream, and its whole size. }
    Offset: Int64;
    Size: Integer;
    Flags: Byte;
    { -1: no packet ends on this page. }
    Granule: Int64;
    Serial: LongWord;
    Sequence: LongWord;
    SegmentCount: Integer;
    Lacing: array[0..254] of Byte;
    Body: TBytes;
  end;

  { Reads pages through a buffer of its own, so reading them one after
    the other reads the stream in large pieces. }
  TOggPageReader = class
  private
    FStream: TStream;
    FBuffer: TBytes;
    FBufferStart: Int64;
    FFilled: Integer;
  public
    constructor Create(Stream: TStream);
    { The next valid page starting at or after Offset, found within Limit
      bytes (all of the rest when Limit < 0); False if there is none. }
    function ReadPageFrom(Offset: Int64; out Page: TOggPage; Limit: Int64 = -1): Boolean;
    { Forgets the buffer (the stream grew or changed). }
    procedure Invalidate;
  end;

function OggCrc(Bytes: PByte; Count: Integer; Crc: LongWord = 0): LongWord;

implementation

var
  CrcTable: array[0..255] of LongWord;

procedure BuildCrcTable;
var
  Index, Bit: Integer;
  Value: LongWord;
begin
  for Index := 0 to 255 do
  begin
    Value := LongWord(Index) shl 24;
    for Bit := 0 to 7 do
      if (Value and $80000000) <> 0 then
        Value := (Value shl 1) xor $04C11DB7
      else
        Value := Value shl 1;
    CrcTable[Index] := Value;
  end;
end;

function OggCrc(Bytes: PByte; Count: Integer; Crc: LongWord): LongWord;
var
  Index: Integer;
begin
  Result := Crc;
  for Index := 0 to Count - 1 do
    Result := (Result shl 8) xor CrcTable[((Result shr 24) xor Bytes[Index]) and $FF];
end;

{ Checks and fills Page from the page at Buffer[Start] (Available bytes
  from there); False if it is not a whole valid page. }
function ParsePage(const Buffer: TBytes; Start, Available: Integer; out Page: TOggPage): Boolean;
var
  Index, BodySize, HeaderSize: Integer;
  Stored, Computed: LongWord;
  Header: array[0..27 + 255 - 1] of Byte;
begin
  Result := False;
  Page := Default(TOggPage);
  if Available < 27 then
    Exit;
  if (Buffer[Start] <> Ord('O')) or (Buffer[Start + 1] <> Ord('g')) or (Buffer[Start + 2] <> Ord('g'))
    or (Buffer[Start + 3] <> Ord('S')) or (Buffer[Start + 4] <> 0) then
    Exit;
  Page.SegmentCount := Buffer[Start + 26];
  HeaderSize := 27 + Page.SegmentCount;
  if Available < HeaderSize then
    Exit;
  BodySize := 0;
  for Index := 0 to Page.SegmentCount - 1 do
  begin
    Page.Lacing[Index] := Buffer[Start + 27 + Index];
    Inc(BodySize, Page.Lacing[Index]);
  end;
  if Available < HeaderSize + BodySize then
    Exit;
  Move(Buffer[Start], Header[0], HeaderSize);
  Stored := LongWord(Header[22]) or (LongWord(Header[23]) shl 8) or (LongWord(Header[24]) shl 16) or
    (LongWord(Header[25]) shl 24);
  Header[22] := 0;
  Header[23] := 0;
  Header[24] := 0;
  Header[25] := 0;
  Computed := OggCrc(@Header[0], HeaderSize);
  if BodySize > 0 then
    Computed := OggCrc(@Buffer[Start + HeaderSize], BodySize, Computed);
  if Computed <> Stored then
    Exit;
  Page.Flags := Header[5];
  Page.Granule := 0;
  for Index := 13 downto 6 do
    Page.Granule := (Page.Granule shl 8) or Header[Index];
  Page.Serial := LongWord(Header[14]) or (LongWord(Header[15]) shl 8) or (LongWord(Header[16]) shl 16) or
    (LongWord(Header[17]) shl 24);
  Page.Sequence := LongWord(Header[18]) or (LongWord(Header[19]) shl 8) or (LongWord(Header[20]) shl 16) or
    (LongWord(Header[21]) shl 24);
  Page.Size := HeaderSize + BodySize;
  Page.Body := nil;
  SetLength(Page.Body, BodySize);
  if BodySize > 0 then
    Move(Buffer[Start + HeaderSize], Page.Body[0], BodySize);
  Result := True;
end;

constructor TOggPageReader.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
  FBuffer := nil;
  SetLength(FBuffer, 2 * OggMaximumPageSize);
  FBufferStart := 0;
  FFilled := 0;
end;

procedure TOggPageReader.Invalidate;
begin
  FFilled := 0;
end;

function TOggPageReader.ReadPageFrom(Offset: Int64; out Page: TOggPage; Limit: Int64): Boolean;
var
  Scan, Count: Integer;
  StreamSize, Searched: Int64;
begin
  Result := False;
  Page := Default(TOggPage);
  StreamSize := FStream.Size;
  if Offset < 0 then
    Offset := 0;
  if (Offset < FBufferStart) or (Offset > FBufferStart + FFilled) then
  begin
    FBufferStart := Offset;
    FFilled := 0;
  end;
  Scan := Offset - FBufferStart;
  Searched := 0;
  while True do
  begin
    { Keep at least a whole page ahead of the scan position. }
    if (FFilled - Scan < OggMaximumPageSize) and (FBufferStart + FFilled < StreamSize) then
    begin
      if Scan > 0 then
      begin
        Move(FBuffer[Scan], FBuffer[0], FFilled - Scan);
        Dec(FFilled, Scan);
        Inc(FBufferStart, Scan);
        Scan := 0;
      end;
      FStream.Position := FBufferStart + FFilled;
      Count := FStream.Read(FBuffer[FFilled], Length(FBuffer) - FFilled);
      if Count > 0 then
        Inc(FFilled, Count);
    end;
    if Scan + 27 > FFilled then
      Exit;
    if (Limit >= 0) and (Searched > Limit) then
      Exit;
    if (FBuffer[Scan] = Ord('O')) and ParsePage(FBuffer, Scan, FFilled - Scan, Page) then
    begin
      Page.Offset := FBufferStart + Scan;
      Exit(True);
    end;
    Inc(Scan);
    Inc(Searched);
  end;
end;

initialization
  BuildCrcTable;
end.

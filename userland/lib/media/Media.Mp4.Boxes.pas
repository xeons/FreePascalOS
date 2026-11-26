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
  ISO base media file format boxes (ISO/IEC 14496-12): a 32-bit size and
  a four-character type, the size 1 meaning a 64-bit size follows and 0
  meaning the box runs to the end of what holds it; then the contents.
  A full box starts its contents with a version byte and 24 flag bits.

  The boxes holding the index (moov, moof) are read into memory whole
  and walked here with offsets; the top level is walked in the stream.
}
unit Media.Mp4.Boxes;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TMp4Box = record
    Kind: string;
    { Offsets of the box, its contents and its end. }
    Start, ContentStart, Finish: Int64;
  end;

{ The box at Offset in Data (not past Limit); Offset moves past it. False
  at Limit; raises EMediaError for a box that does not fit. }
function NextBox(const Data: TBytes; var Offset: Integer; Limit: Integer; out Box: TMp4Box): Boolean;
{ The first child of kind Kind among the boxes from Start to Limit. }
function FindChild(const Data: TBytes; Start, Limit: Integer; const Kind: string; out Box: TMp4Box): Boolean;
{ The box header at Position in Stream (contents not read); False if the
  stream ends before a whole header. Size 0 runs to the end of the
  stream. }
function ReadBoxHeader(Stream: TStream; Position: Int64; out Box: TMp4Box): Boolean;

implementation

uses
  Media.Errors,
  Media.ByteReaders;

function NextBox(const Data: TBytes; var Offset: Integer; Limit: Integer; out Box: TMp4Box): Boolean;
var
  Size: Int64;
  Header: Integer;
begin
  Box := Default(TMp4Box);
  if Offset + 8 > Limit then
    Exit(False);
  Size := BigEndian32(Data, Offset);
  Box.Kind := FourCCAt(Data, Offset + 4);
  Header := 8;
  if Size = 1 then
  begin
    if Offset + 16 > Limit then
      MediaFail('MP4 box header cut short');
    Size := Int64(BigEndian64(Data, Offset + 8));
    Header := 16;
  end
  else if Size = 0 then
    Size := Limit - Offset;
  if (Size < Header) or (Size > Limit - Offset) then
    MediaFail('MP4 box ' + Box.Kind + ' does not fit');
  Box.Start := Offset;
  Box.ContentStart := Offset + Header;
  Box.Finish := Offset + Size;
  Offset := Box.Finish;
  Result := True;
end;

function FindChild(const Data: TBytes; Start, Limit: Integer; const Kind: string; out Box: TMp4Box): Boolean;
var
  Offset: Integer;
begin
  Offset := Start;
  while NextBox(Data, Offset, Limit, Box) do
    if Box.Kind = Kind then
      Exit(True);
  Result := False;
end;

function ReadBoxHeader(Stream: TStream; Position: Int64; out Box: TMp4Box): Boolean;
var
  Header: array[0..15] of Byte;
  Bytes: TBytes;
  Size, StreamSize: Int64;
  HeaderSize: Integer;
begin
  Box := Default(TMp4Box);
  Result := False;
  StreamSize := Stream.Size;
  if Position + 8 > StreamSize then
    Exit;
  Stream.Position := Position;
  if Stream.Read(Header, 8) <> 8 then
    Exit;
  Bytes := nil;
  SetLength(Bytes, 16);
  Move(Header[0], Bytes[0], 8);
  Size := BigEndian32(Bytes, 0);
  Box.Kind := FourCCAt(Bytes, 4);
  HeaderSize := 8;
  if Size = 1 then
  begin
    if (Position + 16 > StreamSize) or (Stream.Read(Bytes[8], 8) <> 8) then
      Exit;
    Size := Int64(BigEndian64(Bytes, 8));
    HeaderSize := 16;
  end
  else if Size = 0 then
    Size := StreamSize - Position;
  if Size < HeaderSize then
    MediaFail('MP4 box ' + Box.Kind + ' has a bad size');
  Box.Start := Position;
  Box.ContentStart := Position + HeaderSize;
  Box.Finish := Position + Size;
  Result := True;
end;

end.

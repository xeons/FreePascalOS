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
  EBML (RFC 8794), the binary format of Matroska and WebM: elements of
  an ID and a size, both variable-length integers (the count of leading
  zero bits of the first byte says how many more bytes follow), then the
  data. An ID keeps its length marker; a size drops it, and a size of all
  one bits is unknown (the element runs until something that cannot be
  inside it).

  TEbmlReader reads elements from a stream through a buffer of its own.
  Reading past the end of the stream raises EMediaError.
}
unit Media.Ebml;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

const
  EbmlUnknownSize = -1;

type
  TEbmlElement = record
    Id: LongWord;
    { The data's size; EbmlUnknownSize if unknown. }
    Size: Int64;
    { Where the element and its data start. }
    Start: Int64;
    DataStart: Int64;
  end;

  TEbmlReader = class
  private
    FStream: TStream;
    FBuffer: TBytes;
    FBufferStart: Int64;
    FFilled: Integer;
    FPosition: Int64;
    FSize: Int64;
    function Fill(Count: Integer): Boolean;
  public
    constructor Create(Stream: TStream);
    { Reads the stream's size again (it may have grown). }
    procedure Refresh;
    function ReadByte: Byte;
    procedure ReadExact(var Target; Count: Integer);
    function ReadBytes(Count: Int64): TBytes;
    { An element header at the position; False (position unchanged) if
      the stream ends before a whole header. Raises EMediaError for a
      header that is not one. }
    function ReadElement(out Element: TEbmlElement): Boolean;
    function ReadUnsigned(Size: Int64): QWord;
    function ReadSigned(Size: Int64): Int64;
    function ReadFloat(Size: Int64): Double;
    function ReadString(Size: Int64): string;
    procedure Skip(Count: Int64);
    function Remaining: Int64;
    property Position: Int64 read FPosition write FPosition;
    property Size: Int64 read FSize;
  end;

{ A variable-length integer (marker removed) of Bytes at Offset, which
  moves past it; -1 for an unknown (all ones) value. Raises EMediaError
  if it does not fit. }
function ReadVintAt(const Bytes: TBytes; var Offset: Integer; Limit: Integer): Int64;
{ A signed variable-length integer (EBML lacing differences). }
function ReadSignedVintAt(const Bytes: TBytes; var Offset: Integer; Limit: Integer): Int64;

implementation

uses
  Math,
  Media.Errors;

const
  BufferSize = 65536;

constructor TEbmlReader.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
  FBuffer := nil;
  SetLength(FBuffer, BufferSize);
  FSize := Stream.Size;
end;

procedure TEbmlReader.Refresh;
begin
  FSize := FStream.Size;
  FFilled := 0;
end;

{ Makes Count bytes at the position available in the buffer, if the
  stream has them. }
function TEbmlReader.Fill(Count: Integer): Boolean;
var
  Read: Integer;
begin
  if (FPosition >= FBufferStart) and (FPosition + Count <= FBufferStart + FFilled) then
    Exit(True);
  if FPosition + Count > FSize then
    Exit(False);
  FBufferStart := FPosition;
  FStream.Position := FPosition;
  Read := FStream.Read(FBuffer[0], BufferSize);
  if Read < 0 then
    Read := 0;
  FFilled := Read;
  Result := FFilled >= Count;
end;

function TEbmlReader.ReadByte: Byte;
begin
  if not Fill(1) then
    MediaFail('unexpected end of file');
  Result := FBuffer[FPosition - FBufferStart];
  Inc(FPosition);
end;

procedure TEbmlReader.ReadExact(var Target; Count: Integer);
var
  Destination: PByte;
begin
  if Count <= 0 then
    Exit;
  if FPosition + Count > FSize then
    MediaFail('unexpected end of file');
  if Count <= BufferSize then
  begin
    if not Fill(Count) then
      MediaFail('unexpected end of file');
    Move(FBuffer[FPosition - FBufferStart], Target, Count);
  end
  else
  begin
    Destination := @Target;
    FStream.Position := FPosition;
    if FStream.Read(Destination^, Count) <> Count then
      MediaFail('unexpected end of file');
  end;
  Inc(FPosition, Count);
end;

function TEbmlReader.ReadBytes(Count: Int64): TBytes;
begin
  Result := nil;
  if (Count < 0) or (Count > Remaining) then
    MediaFail('element runs past the end of the file');
  SetLength(Result, Count);
  if Count > 0 then
    ReadExact(Result[0], Count);
end;

function TEbmlReader.Remaining: Int64;
begin
  Result := FSize - FPosition;
end;

procedure TEbmlReader.Skip(Count: Int64);
begin
  if Count < 0 then
    MediaFail('negative skip');
  Inc(FPosition, Count);
end;

function TEbmlReader.ReadElement(out Element: TEbmlElement): Boolean;
var
  First: Byte;
  Length, Index: Integer;
  Value: QWord;
  AllOnes: Boolean;
  Saved: Int64;
begin
  Element := Default(TEbmlElement);
  Saved := FPosition;
  Result := False;
  if FPosition >= FSize then
    Exit;
  Element.Start := FPosition;
  try
    First := ReadByte;
    if First = 0 then
      MediaFail('invalid EBML ID');
    Length := 1;
    while (First and ($80 shr (Length - 1))) = 0 do
      Inc(Length);
    if Length > 4 then
      MediaFail('invalid EBML ID');
    Element.Id := First;
    for Index := 2 to Length do
      Element.Id := (Element.Id shl 8) or ReadByte;
    First := ReadByte;
    if First = 0 then
      MediaFail('invalid EBML size');
    Length := 1;
    while (First and ($80 shr (Length - 1))) = 0 do
      Inc(Length);
    Value := First and ($FF shr Length);
    AllOnes := Value = ($FF shr Length);
    for Index := 2 to Length do
    begin
      First := ReadByte;
      if First <> $FF then
        AllOnes := False;
      Value := (Value shl 8) or First;
    end;
    if AllOnes then
      Element.Size := EbmlUnknownSize
    else
    begin
      if Value > QWord(High(Int64) div 2) then
        MediaFail('EBML size too large');
      Element.Size := Int64(Value);
    end;
  except
    on EMediaError do
    begin
      if FPosition >= FSize then
      begin
        { Cut short by the end of the stream: no element. }
        FPosition := Saved;
        Exit(False);
      end;
      raise;
    end;
  end;
  Element.DataStart := FPosition;
  Result := True;
end;

function TEbmlReader.ReadUnsigned(Size: Int64): QWord;
var
  Index: Integer;
begin
  if (Size < 0) or (Size > 8) then
    MediaFail('bad EBML integer size');
  Result := 0;
  for Index := 1 to Size do
    Result := (Result shl 8) or ReadByte;
end;

function TEbmlReader.ReadSigned(Size: Int64): Int64;
var
  Value: QWord;
begin
  Value := ReadUnsigned(Size);
  if (Size > 0) and (Size < 8) and ((Value shr (Size * 8 - 1)) <> 0) then
    Value := Value or (not QWord(0) shl (Size * 8));
  Result := Int64(Value);
end;

function TEbmlReader.ReadFloat(Size: Int64): Double;
var
  Raw32: LongWord;
  Raw64: QWord;
  Single32: Single absolute Raw32;
  Double64: Double absolute Raw64;
begin
  case Size of
    0: Result := 0;
    4:
      begin
        Raw32 := LongWord(ReadUnsigned(4));
        Result := Single32;
      end;
    8:
      begin
        Raw64 := ReadUnsigned(8);
        Result := Double64;
      end;
  else
    MediaFail('bad EBML float size');
    Result := 0;
  end;
  if IsNan(Result) or IsInfinite(Result) then
    Result := 0;
end;

function TEbmlReader.ReadString(Size: Int64): string;
var
  Bytes: TBytes;
  Count: Integer;
begin
  if Size > 65536 then
    MediaFail('EBML string too long');
  Bytes := ReadBytes(Size);
  Count := 0;
  while (Count < Length(Bytes)) and (Bytes[Count] <> 0) do
    Inc(Count);
  SetLength(Result, Count);
  if Count > 0 then
    Move(Bytes[0], Result[1], Count);
end;

function ReadVintAt(const Bytes: TBytes; var Offset: Integer; Limit: Integer): Int64;
var
  First: Byte;
  Length, Index: Integer;
  Value: Int64;
  AllOnes: Boolean;
begin
  if Offset >= Limit then
    MediaFail('block cut short');
  First := Bytes[Offset];
  if First = 0 then
    MediaFail('invalid variable-length integer');
  Length := 1;
  while (First and ($80 shr (Length - 1))) = 0 do
    Inc(Length);
  if Offset + Length > Limit then
    MediaFail('block cut short');
  Value := First and ($FF shr Length);
  AllOnes := Value = ($FF shr Length);
  for Index := 1 to Length - 1 do
  begin
    if Bytes[Offset + Index] <> $FF then
      AllOnes := False;
    Value := (Value shl 8) or Bytes[Offset + Index];
  end;
  Inc(Offset, Length);
  if AllOnes then
    Result := -1
  else
    Result := Value;
end;

function ReadSignedVintAt(const Bytes: TBytes; var Offset: Integer; Limit: Integer): Int64;
var
  Start: Integer;
  Value: Int64;
  Length: Integer;
begin
  Start := Offset;
  Value := ReadVintAt(Bytes, Offset, Limit);
  Length := Offset - Start;
  if Value < 0 then
    MediaFail('invalid lace size');
  Result := Value - ((Int64(1) shl (7 * Length - 1)) - 1);
end;

end.

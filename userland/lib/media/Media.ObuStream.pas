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
  AV1 low overhead bitstreams (".obu" files, the AV1 specification's
  section 5.2): OBUs one after another, each with its size field, every
  temporal unit starting with a temporal delimiter. The file must start
  with one (a temporal delimiter OBU with a size of zero). Each temporal
  unit is one packet of the single AV1 track; the file carries no
  times, so packets are numbered (a time base of one unit per frame).
}
unit Media.ObuStream;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, Media.Packets, Media.Demuxers, Media.Errors;

type
  TObuStreamDemuxer = class(TMediaDemuxer)
  private
    FData: TBytes;
    FPosition: Integer;
    FNumber: Int64;
    { The size of the OBU at Position (header included); -1 if broken. }
    function ObuSize(Position: Integer; out ObuType: Integer): Integer;
  public
    class function Recognizes(const Head: TBytes): Boolean; override;
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function FormatName: string; override;
  end;

implementation

const
  ObuTemporalDelimiter = 2;

class function TObuStreamDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  { obu_type 2, no extension, obu_has_size_field 1: $12; obu_size 0. }
  Result := (Length(Head) >= 4) and (Head[0] = $12) and (Head[1] = 0);
end;

function TObuStreamDemuxer.ObuSize(Position: Integer; out ObuType: Integer): Integer;
var
  Header, Index, Shift: Integer;
  Value: QWord;
  Byte: Integer;
begin
  Result := -1;
  ObuType := 0;
  if Position >= Length(FData) then
    Exit;
  Header := FData[Position];
  ObuType := (Header shr 3) and 15;
  if (Header and 2) = 0 then
    Exit;    { a size field is required in this format }
  Index := Position + 1;
  if (Header and 4) <> 0 then
    Inc(Index);
  Value := 0;
  Shift := 0;
  repeat
    if (Index >= Length(FData)) or (Shift > 56) then
      Exit;
    Byte := FData[Index];
    Inc(Index);
    Value := Value or (QWord(Byte and $7F) shl Shift);
    Inc(Shift, 7);
  until (Byte and $80) = 0;
  if Value > QWord(Length(FData) - Index) then
    Exit;
  Result := Index - Position + Integer(Value);
end;

procedure TObuStreamDemuxer.Open;
var
  Track: TMediaTrack;
begin
  FData := nil;
  SetLength(FData, FStream.Size);
  FStream.Position := 0;
  if Length(FData) > 0 then
    FStream.ReadBuffer(FData[0], Length(FData));
  if not Recognizes(FData) then
    MediaFail('not an AV1 OBU stream');
  Track := AddTrack;
  Track.Kind := mkVideo;
  Track.Codec := codecAv1;
  Track.CodecName := 'obu';
  Track.TimeBase := MakeTimeBase(1, 1);
  FPosition := 0;
  FNumber := 0;
end;

function TObuStreamDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  Start, Size, ObuType: Integer;
begin
  Packet := NewPacket(0);
  Result := FPosition < Length(FData);
  if not Result then
    Exit;
  Start := FPosition;
  repeat
    Size := ObuSize(FPosition, ObuType);
    if Size < 0 then
      MediaFail('broken OBU in an AV1 OBU stream');
    Inc(FPosition, Size);
    if FPosition >= Length(FData) then
      Break;
    ObuSize(FPosition, ObuType);
  until ObuType = ObuTemporalDelimiter;
  Packet.Data := Copy(FData, Start, FPosition - Start);
  Packet.PresentationTime := FNumber;
  Packet.DecodeTime := FNumber;
  Packet.KeyFrame := FNumber = 0;
  Inc(FNumber);
end;

function TObuStreamDemuxer.FormatName: string;
begin
  Result := 'obu';
end;

end.

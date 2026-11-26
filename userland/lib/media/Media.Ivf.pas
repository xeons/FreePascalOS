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
  IVF files, the simple container the AV1, VP8 and VP9 tools write: a
  32-byte header ("DKIF", version, header size, the codec's FourCC
  (AV01, VP80, VP90), width, height, the time base as rate and scale,
  the frame count), then for each frame its size (32 bits), its
  timestamp (64 bits, little-endian) and its data (an AV1 temporal unit,
  a VP8 or VP9 frame). One video track; every packet is taken as a key
  frame candidate (IVF does not say), and seeking is not offered.
}
unit Media.Ivf;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, Media.Packets, Media.Demuxers, Media.Errors;

type
  TIvfDemuxer = class(TMediaDemuxer)
  public
    class function Recognizes(const Head: TBytes): Boolean; override;
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function FormatName: string; override;
  end;

implementation

function LittleEndian32(const Data: array of Byte; Offset: Integer): LongWord;
begin
  Result := Data[Offset] or (Data[Offset + 1] shl 8) or (Data[Offset + 2] shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

class function TIvfDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  Result := (Length(Head) >= 32) and (Head[0] = Ord('D')) and (Head[1] = Ord('K')) and (Head[2] = Ord('I')) and
    (Head[3] = Ord('F'));
end;

procedure TIvfDemuxer.Open;
var
  Header: array[0..31] of Byte;
  FourCC: string;
  HeaderSize: Integer;
  Track: TMediaTrack;
  Rate, Scale: LongWord;
begin
  FStream.Position := 0;
  if FStream.Read(Header, 32) <> 32 then
    MediaFail('IVF header cut short');
  if (Header[0] <> Ord('D')) or (Header[1] <> Ord('K')) or (Header[2] <> Ord('I')) or (Header[3] <> Ord('F')) then
    MediaFail('not an IVF file');
  HeaderSize := Header[6] or (Header[7] shl 8);
  if HeaderSize < 32 then
    MediaFail('IVF header too short');
  SetString(FourCC, PChar(@Header[8]), 4);
  Track := AddTrack;
  Track.Kind := mkVideo;
  Track.CodecName := FourCC;
  if FourCC = 'AV01' then
    Track.Codec := codecAv1
  else if FourCC = 'VP80' then
    Track.Codec := codecVp8
  else if FourCC = 'VP90' then
    Track.Codec := codecVp9
  else
    Track.Codec := codecUnknown;
  Track.Width := Header[12] or (Header[13] shl 8);
  Track.Height := Header[14] or (Header[15] shl 8);
  Track.DisplayWidth := Track.Width;
  Track.DisplayHeight := Track.Height;
  Rate := LittleEndian32(Header, 16);
  Scale := LittleEndian32(Header, 20);
  if (Rate = 0) or (Scale = 0) then
  begin
    Rate := 1000;
    Scale := 1;
  end;
  { Timestamps count Scale / Rate seconds. }
  Track.TimeBase := MakeTimeBase(Scale, Rate);
  FStream.Position := HeaderSize;
end;

function TIvfDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  FrameHeader: array[0..11] of Byte;
  Size: LongWord;
begin
  Packet := NewPacket(0);
  Result := False;
  if FStream.Read(FrameHeader, 12) <> 12 then
    Exit;
  Size := LittleEndian32(FrameHeader, 0);
  if Size > FStream.Size - FStream.Position then
    MediaFail('IVF frame cut short');
  SetLength(Packet.Data, Size);
  if Size > 0 then
    FStream.ReadBuffer(Packet.Data[0], Size);
  Packet.PresentationTime := Int64(LittleEndian32(FrameHeader, 4)) or (Int64(LittleEndian32(FrameHeader, 8)) shl 32);
  Packet.DecodeTime := Packet.PresentationTime;
  Packet.KeyFrame := True;
  Result := True;
end;

function TIvfDemuxer.FormatName: string;
begin
  Result := 'ivf';
end;

end.

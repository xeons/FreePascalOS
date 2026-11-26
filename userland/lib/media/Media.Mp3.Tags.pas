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
  What surrounds and introduces the audio of an .mp3 file:

  - ID3v2 tags at the start (a 10-byte header with a syncsafe size, and
    a 10-byte footer when its flag says so; several may follow each
    other), skipped;
  - ID3v1 ("TAG", the last 128 bytes) and APEv2 ("APETAGEX" footer) tags
    at the end, cut off;
  - the first frame's Xing / Info header (frame count, byte count, a
    100-entry seek table) with LAME's extension (encoder delay and
    padding), or Fraunhofer's VBRI header (counts and a seek table).
    Such a frame carries no audio.
}
unit Media.Mp3.Tags;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TMp3StreamInfo = record
    { Whether the first frame is an information frame (no audio). }
    HasInfoFrame: Boolean;
    { -1 if not known. }
    FrameCount: Int64;
    ByteCount: Int64;
    { Xing: 100 entries, each the byte position (of 256 parts) at that
      percentage of the duration. }
    HasXingTable: Boolean;
    XingTable: array[0..99] of Byte;
    { VBRI: byte lengths of equal runs of frames. }
    VbriTable: array of Int64;
    VbriFramesPerEntry: Integer;
    { LAME: samples the encoder added at the start and the end. }
    HasEncoderDelay: Boolean;
    EncoderDelay, EncoderPadding: Integer;
  end;

{ The length of the ID3v2 tag at Data (Count bytes available), 0 if
  there is none. }
function Id3v2TagLength(Data: PByte; Count: Integer): Integer;
{ How many bytes at the end of the last Count bytes Tail of a file are
  ID3v1 and APE tags (Tail is the file's end). }
function TrailingTagLength(Tail: PByte; Count: Integer): Integer;
{ Reads the information headers of the frame at Frame (FrameBytes long). }
function ReadStreamInfo(Frame: PByte; FrameBytes: Integer): TMp3StreamInfo;

implementation

uses
  Media.Mp3.Header;

function BigEndianAt(Data: PByte; Count: Integer): Int64;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := (Result shl 8) or Data[Index];
end;

function Id3v2TagLength(Data: PByte; Count: Integer): Integer;
var
  Index: Integer;
begin
  Result := 0;
  if (Count < 10) or (Data[0] <> Ord('I')) or (Data[1] <> Ord('D')) or (Data[2] <> Ord('3')) then
    Exit;
  if (Data[3] = $FF) or (Data[4] = $FF) then
    Exit;
  for Index := 6 to 9 do
    if (Data[Index] and $80) <> 0 then
      Exit;
  Result := 10 + ((Data[6] shl 21) or (Data[7] shl 14) or (Data[8] shl 7) or Data[9]);
  if (Data[5] and $10) <> 0 then
    Inc(Result, 10);
end;

function TrailingTagLength(Tail: PByte; Count: Integer): Integer;
var
  Footer: PByte;
  ApeSize: Int64;
begin
  Result := 0;
  if (Count >= 128) and (Tail[Count - 128] = Ord('T')) and (Tail[Count - 127] = Ord('A'))
    and (Tail[Count - 126] = Ord('G')) then
    Result := 128;
  if Count - Result >= 32 then
  begin
    Footer := Tail + Count - Result - 32;
    if CompareByte(Footer^, PChar('APETAGEX')^, 8) = 0 then
    begin
      ApeSize := Footer[12] or (Footer[13] shl 8) or (Footer[14] shl 16) or (Int64(Footer[15]) shl 24);
      { The size counts the items and the footer; a header (flag bit 31)
        adds 32 more. }
      if (Footer[23] and $80) <> 0 then
        Inc(ApeSize, 32);
      if ApeSize <= Count - Result then
        Inc(Result, ApeSize);
    end;
  end;
end;

function SideInfoBytes(Frame: PByte): Integer;
begin
  if HeaderIsMpeg1(Frame) then
  begin
    if HeaderIsMono(Frame) then
      Result := 17
    else
      Result := 32;
  end
  else if HeaderIsMono(Frame) then
    Result := 9
  else
    Result := 17;
end;

procedure ReadLameTag(var Info: TMp3StreamInfo; Tag: PByte; Available: Integer);
var
  Packed24: Integer;
begin
  { "LAME" (or "Lavc"/"Lavf" from ffmpeg's muxer) and its version: 9
    bytes, then revision, low pass, replay gain (8), flags, bit rate,
    and the delay and padding as two 12-bit numbers. }
  if Available < 24 then
    Exit;
  if not ((CompareByte(Tag^, PChar('LAME')^, 4) = 0) or (CompareByte(Tag^, PChar('Lavc')^, 4) = 0)
    or (CompareByte(Tag^, PChar('Lavf')^, 4) = 0) or (CompareByte(Tag^, PChar('L3.9')^, 4) = 0)) then
    Exit;
  Packed24 := (Tag[21] shl 16) or (Tag[22] shl 8) or Tag[23];
  Info.HasEncoderDelay := True;
  Info.EncoderDelay := Packed24 shr 12;
  Info.EncoderPadding := Packed24 and $FFF;
end;

procedure ReadXing(var Info: TMp3StreamInfo; Frame: PByte; FrameBytes, Offset: Integer);
var
  Flags: LongWord;
  Position: Integer;
begin
  Info.HasInfoFrame := True;
  Position := Offset + 4;
  if Position + 4 > FrameBytes then
    Exit;
  Flags := BigEndianAt(Frame + Position, 4);
  Inc(Position, 4);
  if ((Flags and 1) <> 0) and (Position + 4 <= FrameBytes) then
  begin
    Info.FrameCount := BigEndianAt(Frame + Position, 4);
    Inc(Position, 4);
  end;
  if ((Flags and 2) <> 0) and (Position + 4 <= FrameBytes) then
  begin
    Info.ByteCount := BigEndianAt(Frame + Position, 4);
    Inc(Position, 4);
  end;
  if ((Flags and 4) <> 0) and (Position + 100 <= FrameBytes) then
  begin
    Move(Frame[Position], Info.XingTable[0], 100);
    Info.HasXingTable := True;
    Inc(Position, 100);
  end;
  if (Flags and 8) <> 0 then
    Inc(Position, 4);
  if Position < FrameBytes then
    ReadLameTag(Info, Frame + Position, FrameBytes - Position);
end;

procedure ReadVbri(var Info: TMp3StreamInfo; Frame: PByte; FrameBytes, Offset: Integer);
var
  Entries, Scale, EntryBytes, Index: Integer;
  Entry: PByte;
begin
  if Offset + 26 > FrameBytes then
    Exit;
  Info.HasInfoFrame := True;
  Info.ByteCount := BigEndianAt(Frame + Offset + 10, 4);
  Info.FrameCount := BigEndianAt(Frame + Offset + 14, 4);
  Entries := BigEndianAt(Frame + Offset + 18, 2);
  Scale := BigEndianAt(Frame + Offset + 20, 2);
  EntryBytes := BigEndianAt(Frame + Offset + 22, 2);
  Info.VbriFramesPerEntry := BigEndianAt(Frame + Offset + 24, 2);
  if (EntryBytes < 1) or (EntryBytes > 4) or (Offset + 26 + Entries * EntryBytes > FrameBytes) then
    Exit;
  SetLength(Info.VbriTable, Entries);
  Entry := Frame + Offset + 26;
  for Index := 0 to Entries - 1 do
  begin
    Info.VbriTable[Index] := BigEndianAt(Entry, EntryBytes) * Scale;
    Inc(Entry, EntryBytes);
  end;
end;

function IsXingTag(Frame: PByte; FrameBytes, Offset: Integer): Boolean;
begin
  Result := (Offset + 8 <= FrameBytes) and ((CompareByte(Frame[Offset], PChar('Xing')^, 4) = 0)
    or (CompareByte(Frame[Offset], PChar('Info')^, 4) = 0));
end;

function ReadStreamInfo(Frame: PByte; FrameBytes: Integer): TMp3StreamInfo;
var
  Offset: Integer;
begin
  Result := Default(TMp3StreamInfo);
  Result.FrameCount := -1;
  Result.ByteCount := -1;
  Result.VbriTable := nil;
  { LAME puts the tag right after the side information even in a frame
    marked as protected (no room for the CRC); others leave the room. }
  Offset := Mp3HeaderSize + SideInfoBytes(Frame);
  if HeaderHasCrc(Frame) and not IsXingTag(Frame, FrameBytes, Offset) then
    Inc(Offset, 2);
  if IsXingTag(Frame, FrameBytes, Offset) then
    ReadXing(Result, Frame, FrameBytes, Offset)
  else if (36 + 26 <= FrameBytes) and (CompareByte(Frame[36], PChar('VBRI')^, 4) = 0) then
    ReadVbri(Result, Frame, FrameBytes, 36);
end;

end.

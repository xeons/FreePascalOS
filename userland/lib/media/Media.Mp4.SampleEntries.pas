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
  MP4 sample entries (the stsd box): what codec a track is in and its
  setup, turned into the container-independent form of Media.Packets.

  Audio entries: Opus (dOps, rewritten as an OpusHead: RFC 7845's layout,
  little-endian, version 1), fLaC (dfLa: the STREAMINFO body), mp4a
  (esds: object type 0x40/0x66-0x68 AAC with its AudioSpecificConfig,
  0x69/0x6B MP3; QuickTime's version 1 and 2 layouts, and esds inside a
  wave box), .mp3, ipcm and fpcm (pcmC), sowt, twos, raw, in24, in32,
  fl32, fl64 and lpcm. Video entries: av01 (av1C), vp09 and vp08 (vpcC,
  version and flags first), avc1/avc3 (avcC), hvc1/hev1 (hvcC).
}
unit Media.Mp4.SampleEntries;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets;

{ Describes Track from the sample entry box at Start (to Finish) in Data. }
procedure DescribeSampleEntry(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);

implementation

uses
  Media.Errors,
  Media.ByteReaders,
  Media.Mp4.Boxes,
  Media.Ogg.Codecs;

const
  AudioEntryHeader = 8 + 20;
  VisualEntryHeader = 8 + 70;

function OpusHeadOfDops(const Data: TBytes; Start, Finish: Integer): TBytes;
var
  Count, Family, Index: Integer;
begin
  Result := nil;
  Count := Finish - Start;
  if Count < 11 then
    MediaFail('dOps too short');
  Family := Data[Start + 10];
  SetLength(Result, 19);
  Move(PChar('OpusHead')^, Result[0], 8);
  Result[8] := 1;
  Result[9] := Data[Start + 1];
  PutLittleEndian16(Result, 10, BigEndian16(Data, Start + 2));
  PutLittleEndian32(Result, 12, BigEndian32(Data, Start + 4));
  PutLittleEndian16(Result, 16, BigEndian16(Data, Start + 8));
  Result[18] := Family;
  if Family <> 0 then
  begin
    if Count < 13 + Data[Start + 1] then
      MediaFail('dOps channel mapping cut short');
    SetLength(Result, 21 + Data[Start + 1]);
    for Index := 0 to 1 + Data[Start + 1] do
      Result[19 + Index] := Data[Start + 11 + Index];
  end;
end;

function StreamInfoOfDfla(const Data: TBytes; Start, Finish: Integer): TBytes;
var
  Offset, BlockSize: Integer;
begin
  Result := nil;
  Offset := Start + 4;
  while Offset + 4 <= Finish do
  begin
    BlockSize := BigEndian24(Data, Offset + 1);
    if Offset + 4 + BlockSize > Finish then
      MediaFail('dfLa block cut short');
    if (Data[Offset] and $7F) = 0 then
      Exit(SliceBytes(Data, Offset + 4, BlockSize));
    if (Data[Offset] and $80) <> 0 then
      Break;
    Inc(Offset, 4 + BlockSize);
  end;
  MediaFail('dfLa without STREAMINFO');
end;

{ A descriptor's tag and length (the length in 7-bit groups); Offset moves
  past them. }
function ReadDescriptor(const Data: TBytes; var Offset: Integer; Limit: Integer; out Tag: Integer): Integer;
var
  Index: Integer;
  Value: Byte;
begin
  if Offset >= Limit then
    MediaFail('esds cut short');
  Tag := Data[Offset];
  Inc(Offset);
  Result := 0;
  for Index := 1 to 4 do
  begin
    if Offset >= Limit then
      MediaFail('esds cut short');
    Value := Data[Offset];
    Inc(Offset);
    Result := (Result shl 7) or (Value and $7F);
    if (Value and $80) = 0 then
      Break;
  end;
  if Offset + Result > Limit then
    Result := Limit - Offset;
end;

procedure ReadEsds(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);
var
  Offset, Tag, Length, Flags, ObjectType, DescriptorEnd: Integer;
begin
  Offset := Start + 4;
  Length := ReadDescriptor(Data, Offset, Finish, Tag);
  if Tag <> 3 then
    Exit;
  DescriptorEnd := Offset + Length;
  if Offset + 3 > DescriptorEnd then
    MediaFail('esds cut short');
  Flags := Data[Offset + 2];
  Inc(Offset, 3);
  if (Flags and $80) <> 0 then
    Inc(Offset, 2);
  if (Flags and $40) <> 0 then
  begin
    if Offset >= DescriptorEnd then
      MediaFail('esds cut short');
    Inc(Offset, 1 + Data[Offset]);
  end;
  if (Flags and $20) <> 0 then
    Inc(Offset, 2);
  if Offset >= DescriptorEnd then
    MediaFail('esds cut short');
  Length := ReadDescriptor(Data, Offset, DescriptorEnd, Tag);
  if (Tag <> 4) or (Length < 13) then
    Exit;
  ObjectType := Data[Offset];
  DescriptorEnd := Offset + Length;
  Inc(Offset, 13);
  case ObjectType of
    $40, $66, $67, $68:
      begin
        Track.Codec := codecAac;
        if Offset < DescriptorEnd then
        begin
          Length := ReadDescriptor(Data, Offset, DescriptorEnd, Tag);
          if Tag = 5 then
            Track.AddHeader(SliceBytes(Data, Offset, Length));
        end;
      end;
    $69, $6B: Track.Codec := codecMp3;
  else
    Track.Codec := codecUnknown;
  end;
end;

procedure ReadPcmConfig(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);
begin
  if Finish - Start < 6 then
    MediaFail('pcmC too short');
  Track.PcmBigEndian := (Data[Start + 4] and 1) = 0;
  Track.BitsPerSample := Data[Start + 5];
end;

procedure DescribeAudio(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);
var
  Version, ChildStart, Offset: Integer;
  Child, Inner: TMp4Box;
  Info: TStreamInfo;
  Head: TOpusHead;
  Kind: string;
  LpcmFlags: LongWord;
  RateBits: QWord;
  Rate: Double absolute RateBits;
begin
  Kind := Track.CodecName;
  Track.Kind := mkAudio;
  if Finish - Start < AudioEntryHeader then
    MediaFail('audio sample entry too short');
  Version := BigEndian16(Data, Start + 8);
  Track.Channels := BigEndian16(Data, Start + 16);
  Track.BitsPerSample := BigEndian16(Data, Start + 18);
  Track.SampleRate := BigEndian32(Data, Start + 24) shr 16;
  ChildStart := Start + AudioEntryHeader;
  LpcmFlags := 0;
  if Version = 1 then
    Inc(ChildStart, 16)
  else if Version = 2 then
  begin
    if Finish - Start < AudioEntryHeader + 36 then
      MediaFail('audio sample entry too short');
    RateBits := BigEndian64(Data, Start + 32);
    if (Rate > 0) and (Rate < 10000000) then
      Track.SampleRate := Round(Rate);
    Track.Channels := BigEndian32(Data, Start + 40);
    Track.BitsPerSample := BigEndian32(Data, Start + 48);
    LpcmFlags := BigEndian32(Data, Start + 52);
    Inc(ChildStart, 36);
  end;
  if Kind = 'Opus' then
    Track.Codec := codecOpus
  else if Kind = 'fLaC' then
    Track.Codec := codecFlac
  else if Kind = '.mp3' then
    Track.Codec := codecMp3
  else if (Kind = 'ipcm') or (Kind = 'fpcm') then
  begin
    Track.Codec := codecPcm;
    Track.PcmFloat := Kind = 'fpcm';
  end
  else if (Kind = 'sowt') or (Kind = 'twos') or (Kind = 'raw ') or (Kind = 'in24') or (Kind = 'in32')
    or (Kind = 'fl32') or (Kind = 'fl64') or (Kind = 'lpcm') then
  begin
    Track.Codec := codecPcm;
    Track.PcmBigEndian := (Kind <> 'sowt') and (Kind <> 'raw ');
    if Kind = 'in24' then Track.BitsPerSample := 24;
    if Kind = 'in32' then Track.BitsPerSample := 32;
    if Kind = 'fl32' then
    begin
      Track.BitsPerSample := 32;
      Track.PcmFloat := True;
    end;
    if Kind = 'fl64' then
    begin
      Track.BitsPerSample := 64;
      Track.PcmFloat := True;
    end;
    if Kind = 'raw ' then Track.BitsPerSample := 8;
    if Kind = 'lpcm' then
    begin
      Track.PcmFloat := (LpcmFlags and 1) <> 0;
      Track.PcmBigEndian := (LpcmFlags and 2) <> 0;
    end;
  end
  else if Kind = 'mp4a' then
    Track.Codec := codecUnknown
  else
    Track.Codec := codecUnknown;
  Offset := ChildStart;
  while NextBox(Data, Offset, Finish, Child) do
  begin
    if Child.Kind = 'dOps' then
    begin
      Track.AddHeader(OpusHeadOfDops(Data, Child.ContentStart, Child.Finish));
      Head := ReadOpusHead(Track.Headers[0]);
      Track.CodecDelay := Head.PreSkip;
      Track.Channels := Head.Channels;
      Track.SampleRate := 48000;
      Track.SeekPreRoll := 80000;
    end
    else if Child.Kind = 'dfLa' then
    begin
      Track.AddHeader(StreamInfoOfDfla(Data, Child.ContentStart, Child.Finish));
      Info := ReadStreamInfo(Track.Headers[0]);
      if Info.Valid then
      begin
        Track.SampleRate := Info.SampleRate;
        Track.Channels := Info.Channels;
        Track.BitsPerSample := Info.BitsPerSample;
      end;
    end
    else if (Child.Kind = 'esds') and (Kind = 'mp4a') then
      ReadEsds(Data, Child.ContentStart, Child.Finish, Track)
    else if (Child.Kind = 'wave') and (Kind = 'mp4a') then
    begin
      if FindChild(Data, Child.ContentStart, Child.Finish, 'esds', Inner) then
        ReadEsds(Data, Inner.ContentStart, Inner.Finish, Track);
    end
    else if Child.Kind = 'pcmC' then
      ReadPcmConfig(Data, Child.ContentStart, Child.Finish, Track)
    else if Child.Kind = 'enda' then
    begin
      if (Child.Finish - Child.ContentStart >= 2) and (Data[Child.ContentStart + 1] <> 0) then
        Track.PcmBigEndian := False;
    end;
  end;
end;

procedure DescribeVideo(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);
var
  Offset: Integer;
  Child: TMp4Box;
  Kind, Wanted: string;
begin
  Kind := Track.CodecName;
  Track.Kind := mkVideo;
  if Finish - Start < VisualEntryHeader then
    MediaFail('visual sample entry too short');
  Track.Width := BigEndian16(Data, Start + 24);
  Track.Height := BigEndian16(Data, Start + 26);
  Wanted := '';
  if Kind = 'av01' then
  begin
    Track.Codec := codecAv1;
    Wanted := 'av1C';
  end
  else if Kind = 'vp09' then
  begin
    Track.Codec := codecVp9;
    Wanted := 'vpcC';
  end
  else if Kind = 'vp08' then
  begin
    Track.Codec := codecVp8;
    Wanted := 'vpcC';
  end
  else if (Kind = 'avc1') or (Kind = 'avc3') then
  begin
    Track.Codec := codecH264;
    Wanted := 'avcC';
  end
  else if (Kind = 'hvc1') or (Kind = 'hev1') then
  begin
    Track.Codec := codecHevc;
    Wanted := 'hvcC';
  end
  else
    Track.Codec := codecUnknown;
  Offset := Start + VisualEntryHeader;
  while NextBox(Data, Offset, Finish, Child) do
    if (Child.Kind = Wanted) and (Length(Track.Headers) = 0) then
      Track.AddHeader(SliceBytes(Data, Child.ContentStart, Child.Finish - Child.ContentStart));
end;

procedure DescribeSampleEntry(const Data: TBytes; Start, Finish: Integer; Track: TMediaTrack);
var
  Offset: Integer;
  Entry: TMp4Box;
begin
  Offset := Start;
  if not NextBox(Data, Offset, Finish, Entry) then
    MediaFail('empty sample description');
  Track.CodecName := Entry.Kind;
  if Track.Kind = mkAudio then
    DescribeAudio(Data, Entry.ContentStart, Entry.Finish, Track)
  else if Track.Kind = mkVideo then
    DescribeVideo(Data, Entry.ContentStart, Entry.Finish, Track)
  else
    Track.Codec := codecUnknown;
  Track.DisplayWidth := Track.Width;
  Track.DisplayHeight := Track.Height;
end;

end.

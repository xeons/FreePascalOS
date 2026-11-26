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
  The AV1 decoder's interface: TAv1Decoder takes the OBUs of a stream
  (a temporal unit at a time, as containers store them: an IVF frame, a
  Matroska/WebM block, an MP4 sample) and hands out the frames it shows,
  in order, as Media.Frames TVideoFrame records.

  It follows operating point 0 (OBUs of other layers are dropped),
  decodes all of the Main profile and the High and Professional
  profiles' 4:4:4, 4:2:2 and 12-bit formats, applies film grain, and
  decodes the tiles of a frame on several threads when asked to.
  Large scale tile streams (Annex D) are not supported.
}
unit Av1.Decoder;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, Media.Frames, Av1.Common, Av1.Constants, Av1.BitReader, Av1.SequenceHeader,
  Av1.FrameHeader, Av1.FrameHeaderParsing, Av1.References, Av1.FrameDecoding;

type
  EAv1DecoderError = EAv1Error;

  TAv1Decoder = class
  private
    FFrames: TFrameDecoder;
    FSequence: TSequenceHeader;
    FHaveSequence: Boolean;
    FHeaderState: THeaderState;
    FSeenFrameHeader: Boolean;
    FHeader: TFrameHeader;
    FOutput: array of TVideoFrame;
    FOutputFirst: Integer;
    procedure FrameShown(const Frame: TVideoFrame);
    procedure DecodeObu(ObuType, TemporalId, SpatialId: Integer; Data: PByte; Size: Integer);
    procedure DecodeFrameHeader(var Reader: TBitReader; TemporalId, SpatialId: Integer);
  public
    { ThreadCount: threads for the tiles of a frame (0 or 1 decodes on the caller's thread). }
    constructor Create(ThreadCount: Integer = 0);
    destructor Destroy; override;
    { Decodes the OBUs in Size bytes at Data (a temporal unit, or any whole
      number of OBUs); the frames shown get PresentationTime. Raises
      EAv1Error for streams it cannot decode. }
    procedure Decode(Data: PByte; Size: Integer; PresentationTime: Int64 = 0);
    procedure DecodeBytes(const Data: TBytes; PresentationTime: Int64 = 0);
    { The next frame shown, if any. }
    function TakeFrame(out Frame: TVideoFrame): Boolean;
    function FramesWaiting: Integer;
    { Forgets every reference frame and header, as at the start of a stream. }
    procedure Reset;
    property Sequence: TSequenceHeader read FSequence;
    property HaveSequence: Boolean read FHaveSequence;
  end;

implementation

constructor TAv1Decoder.Create(ThreadCount: Integer);
begin
  inherited Create;
  FFrames := TFrameDecoder.Create(ThreadCount);
  FFrames.OnFrameShown := @FrameShown;
end;

destructor TAv1Decoder.Destroy;
begin
  FFrames.Free;
  inherited Destroy;
end;

procedure TAv1Decoder.Reset;
begin
  FFrames.Reset;
  FHaveSequence := False;
  FSeenFrameHeader := False;
  FOutput := nil;
  FOutputFirst := 0;
end;

procedure TAv1Decoder.FrameShown(const Frame: TVideoFrame);
begin
  SetLength(FOutput, Length(FOutput) + 1);
  FOutput[High(FOutput)] := Frame;
end;

function TAv1Decoder.FramesWaiting: Integer;
begin
  Result := Length(FOutput) - FOutputFirst;
end;

function TAv1Decoder.TakeFrame(out Frame: TVideoFrame): Boolean;
begin
  Result := FOutputFirst < Length(FOutput);
  if not Result then
  begin
    Frame := Default(TVideoFrame);
    Exit;
  end;
  Frame := FOutput[FOutputFirst];
  FOutput[FOutputFirst] := Default(TVideoFrame);
  Inc(FOutputFirst);
  if FOutputFirst = Length(FOutput) then
  begin
    FOutput := nil;
    FOutputFirst := 0;
  end;
end;

procedure TAv1Decoder.DecodeFrameHeader(var Reader: TBitReader; TemporalId, SpatialId: Integer);
begin
  if not FHaveSequence then
    RaiseAv1Error('frame header before any sequence header');
  ParseUncompressedHeader(Reader, FSequence, FFrames.ReferenceSlots^, FHeaderState, TemporalId, SpatialId, FHeader);
  if FHeader.show_existing_frame then
  begin
    FFrames.ShowExistingFrame(FSequence, FHeader);
    FSeenFrameHeader := False;
  end
  else
  begin
    FFrames.StartFrame(FSequence, FHeader);
    FSeenFrameHeader := True;
  end;
end;

procedure TAv1Decoder.DecodeObu(ObuType, TemporalId, SpatialId: Integer; Data: PByte; Size: Integer);
var
  Reader: TBitReader;
  HeaderBytes: Integer;
begin
  InitializeBitReader(Reader, Data, Size);
  case ObuType of
    OBU_SEQUENCE_HEADER:
      begin
        ParseSequenceHeader(Reader, FSequence);
        FHaveSequence := True;
      end;
    OBU_TEMPORAL_DELIMITER:
      FSeenFrameHeader := False;
    OBU_FRAME_HEADER, OBU_REDUNDANT_FRAME_HEADER:
      if not FSeenFrameHeader then
        DecodeFrameHeader(Reader, TemporalId, SpatialId);
    OBU_FRAME:
      begin
        if FSeenFrameHeader then
          RaiseAv1Error('frame OBU after a frame header');
        DecodeFrameHeader(Reader, TemporalId, SpatialId);
        if FHeader.show_existing_frame then
          RaiseAv1Error('frame OBU with show_existing_frame');
        AlignToByte(Reader);
        HeaderBytes := BytePosition(Reader);
        FFrames.DecodeTileGroup(Data + HeaderBytes, Size - HeaderBytes);
        FSeenFrameHeader := False;
      end;
    OBU_TILE_GROUP:
      begin
        if not FSeenFrameHeader then
          RaiseAv1Error('tile group without a frame header');
        FFrames.DecodeTileGroup(Data, Size);
      end;
  else
    { metadata, tile lists, padding and reserved OBUs are skipped }
  end;
end;

procedure TAv1Decoder.Decode(Data: PByte; Size: Integer; PresentationTime: Int64);
var
  Reader: TBitReader;
  Position, ObuType, TemporalId, SpatialId, HeaderStart: Integer;
  ExtensionFlag, HasSizeField: Boolean;
  ObuSize: QWord;
  InTemporalLayer, InSpatialLayer: Boolean;
begin
  FFrames.PresentationTime := PresentationTime;
  Position := 0;
  while Position < Size do
  begin
    InitializeBitReader(Reader, Data + Position, Size - Position);
    HeaderStart := Position;
    if ReadBit(Reader) <> 0 then
      RaiseAv1Error('forbidden bit set in an OBU header');
    ObuType := ReadBits(Reader, 4);
    ExtensionFlag := ReadFlag(Reader);
    HasSizeField := ReadFlag(Reader);
    ReadBit(Reader);
    TemporalId := 0;
    SpatialId := 0;
    if ExtensionFlag then
    begin
      TemporalId := ReadBits(Reader, 3);
      SpatialId := ReadBits(Reader, 2);
      ReadBits(Reader, 3);
    end;
    if HasSizeField then
      ObuSize := ReadLeb128(Reader)
    else
      ObuSize := Size - Position - 1 - Ord(ExtensionFlag);
    Position := HeaderStart + BytePosition(Reader);
    if ObuSize > QWord(Size - Position) then
      RaiseAv1Error('OBU larger than its data');
    if (ObuType <> OBU_SEQUENCE_HEADER) and (ObuType <> OBU_TEMPORAL_DELIMITER) and FHaveSequence and
      (FSequence.OperatingPointIdc <> 0) and ExtensionFlag then
    begin
      InTemporalLayer := ((FSequence.OperatingPointIdc shr TemporalId) and 1) <> 0;
      InSpatialLayer := ((FSequence.OperatingPointIdc shr (SpatialId + 8)) and 1) <> 0;
      if not (InTemporalLayer and InSpatialLayer) then
      begin
        Inc(Position, ObuSize);
        Continue;
      end;
    end;
    DecodeObu(ObuType, TemporalId, SpatialId, Data + Position, ObuSize);
    Inc(Position, ObuSize);
  end;
end;

procedure TAv1Decoder.DecodeBytes(const Data: TBytes; PresentationTime: Int64);
begin
  if Length(Data) > 0 then
    Decode(@Data[0], Length(Data), PresentationTime);
end;

end.

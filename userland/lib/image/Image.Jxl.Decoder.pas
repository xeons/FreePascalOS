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
  A JPEG XL file as a libimage image.

  The codestream (from the container if there is one) starts with the
  image headers and the ICC profile; a preview frame, if any, is
  passed over; then frames follow until the last. LF frames are kept
  for the frames using them, frames saved to a reference slot for the
  frames blending onto them or copying patches from them. Each regular
  frame is blended onto the canvas; the frames shown (all of an
  animation's frames that have a duration, and the last) become the
  image, an animation's each as a whole canvas (so the compositor
  replaces rather than blends), its delay the duration in ticks turned
  into milliseconds.

  The orientation is noted, the pixels staying as stored. A lossless
  image with an ICC profile keeps it with its pixels as coded; an XYB
  coded (lossy) image is converted to sRGB and keeps no profile. A
  frame that cannot be decoded after an animation's first ends the
  animation there.
}
unit Image.Jxl.Decoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model;

function DecodeJxlImage(const Data: TBytes): TImage;

implementation

uses
  Math,
  Image.Errors,
  Image.Metadata,
  Image.Frames,
  Image.Jxl.BitReader,
  Image.Jxl.Container,
  Image.Jxl.Headers,
  Image.Jxl.Icc,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.FrameDecoder,
  Image.Jxl.Canvas,
  Image.Jxl.Output;

type
  TShownFrame = record
    Image: TImage;
    Duration: LongWord;
    Encoding: LongWord;
  end;

  TShownFrames = array of TShownFrame;

function ChromaticityName(const Encoding: TJxlColorEncoding): string;
begin
  case Encoding.Primaries of
    JxlPrimariesSrgb: Result := 'sRGB';
    JxlPrimariesP3: Result := 'Display P3';
    JxlPrimaries2100: Result := 'Rec. 2100';
  else
    Result := 'custom primaries';
  end;
end;

function TransferName(const Encoding: TJxlColorEncoding): string;
begin
  if Encoding.HaveGamma then
    Exit(Format('gamma %.3f', [10000000.0 / Max(1, Encoding.Gamma)]));
  case Encoding.TransferFunction of
    JxlTransferSrgb: Result := '';
    JxlTransferLinear: Result := 'linear';
    JxlTransfer709: Result := 'BT.709';
    JxlTransferPq: Result := 'PQ';
    JxlTransferHlg: Result := 'HLG';
    JxlTransferDci: Result := 'DCI';
  else
    Result := 'unknown transfer';
  end;
end;

{ The colour space the pixels are in, for the metadata. }
function ColorSpaceDescription(const Metadata: TJxlImageMetadata): string;
var
  Transfer: string;
begin
  if Metadata.XybEncoded then
    Exit('sRGB');
  if Metadata.ColorEncoding.WantIcc then
    Exit('ICC');
  Transfer := TransferName(Metadata.ColorEncoding);
  if Metadata.ColorEncoding.ColorSpace = JxlColorSpaceGrey then
  begin
    if Transfer = '' then
      Exit('Grey');
    Exit('Grey (' + Transfer + ')');
  end;
  Result := ChromaticityName(Metadata.ColorEncoding);
  if Transfer = 'linear' then
    Result := 'Linear ' + Result
  else if Transfer <> '' then
    Result := Result + ' (' + Transfer + ')';
end;

function JoinNames(const Names: array of string): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to High(Names) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + Names[Index];
  end;
end;

procedure ReleaseContext(var Context: TJxlDecodingContext);
var
  Slot: LongInt;
begin
  for Slot := 0 to 3 do
  begin
    FreeJxlPlanes(Context.References[Slot]);
    FreeJxlPlanes(Context.LowFrequencyFrames[Slot]);
  end;
end;

procedure StoreReference(var Context: TJxlDecodingContext; Slot: LongInt; var Planes: TJxlPlaneSet;
  InColorTransformSpace: Boolean);
begin
  FreeJxlPlanes(Context.References[Slot]);
  Context.References[Slot] := Planes;
  Planes := nil;
  if Length(Context.References[Slot]) > 0 then
  begin
    Context.ReferenceSizes[Slot].Width := Context.References[Slot][0].Width;
    Context.ReferenceSizes[Slot].Height := Context.References[Slot][0].Height;
  end
  else
  begin
    Context.ReferenceSizes[Slot].Width := 0;
    Context.ReferenceSizes[Slot].Height := 0;
  end;
  Context.ReferenceBeforeColorTransform[Slot] := InColorTransformSpace;
end;

function ClonePlanes(const Planes: TJxlPlaneSet): TJxlPlaneSet;
var
  Index: LongInt;
begin
  SetLength(Result, Length(Planes));
  for Index := 0 to High(Planes) do
    Result[Index] := Planes[Index].Clone;
end;

{ Files the frame away and, if it is shown, adds its canvas to Shown. }
procedure HandleFrame(var Frame: TJxlDecodedFrame; var Context: TJxlDecodingContext;
  const Headers: TJxlImageHeaders; var Shown: TShownFrames);
var
  Header: TJxlFrameHeader;
  Canvas: TJxlPlaneSet;
  Saved: TJxlPlaneSet;
  Index: LongInt;
begin
  Header := Frame.Header;
  case Header.FrameType of
    JxlFrameLowFrequency:
      begin
        Index := LongInt(Header.LowFrequencyLevel) - 1;
        FreeJxlPlanes(Context.LowFrequencyFrames[Index]);
        Context.LowFrequencyFrames[Index] := Copy(Frame.Planes, 0, 3);
        for Index := 3 to High(Frame.Planes) do
          Frame.Planes[Index].Free;
        Frame.Planes := nil;
      end;
    JxlFrameReferenceOnly:
      if Header.SaveBeforeColorTransform then
        StoreReference(Context, Header.SaveAsReference, Frame.Planes,
          Header.ColorTransform <> JxlColorTransformNone)
      else
        StoreReference(Context, Header.SaveAsReference, Frame.Planes, False);
  else
    begin
      Canvas := BlendJxlFrameOntoCanvas(Frame, Context, Headers.Width, Headers.Height,
        Headers.Metadata.ExtraChannels);
      try
        if JxlFrameCanBeReferenced(Header) then
        begin
          if Header.SaveBeforeColorTransform then
          begin
            Saved := Frame.SavedPlanes;
            Frame.SavedPlanes := nil;
            StoreReference(Context, Header.SaveAsReference, Saved, Header.ColorTransform <> JxlColorTransformNone);
          end
          else
          begin
            Saved := ClonePlanes(Canvas);
            StoreReference(Context, Header.SaveAsReference, Saved, False);
          end;
        end;
        if Header.IsLast or (Headers.Metadata.HaveAnimation and (Header.Duration > 0)) then
        begin
          SetLength(Shown, Length(Shown) + 1);
          Shown[High(Shown)].Image := JxlPlanesToImage(Canvas, Headers.Metadata);
          Shown[High(Shown)].Duration := Header.Duration;
          Shown[High(Shown)].Encoding := Header.Encoding;
        end;
      finally
        FreeJxlPlanes(Canvas);
      end;
    end;
  end;
end;

function DelayInMilliseconds(Duration: LongWord; const Animation: TJxlAnimationHeader): LongInt;
var
  Milliseconds: Double;
begin
  if Animation.TicksPerSecondNumerator = 0 then
    Exit(0);
  Milliseconds := Duration * 1000.0 * Animation.TicksPerSecondDenominator / Animation.TicksPerSecondNumerator;
  if Milliseconds > High(LongInt) then
    Exit(High(LongInt));
  Result := Round(Milliseconds);
end;

procedure DescribeImage(Image: TImage; const Headers: TJxlImageHeaders; const Contents: TJxlFileContents;
  const Profile: TBytes; Encoding: LongWord);
var
  ColorChannels: LongInt;
begin
  Image.SourceFormatName := 'JPEG XL';
  Image.SourceHasAlpha := JxlAlphaChannelIndex(Headers.Metadata) >= 0;
  if JxlIsGrey(Headers.Metadata) then
    ColorChannels := 1
  else
    ColorChannels := 3;
  if Image.SourceHasAlpha then
    Inc(ColorChannels);
  Image.SourceBitsPerPixel := LongInt(Headers.Metadata.BitDepth.BitsPerSample) * ColorChannels;
  Image.Orientation := OrientationFromExif(Headers.Metadata.Orientation);
  if Headers.Metadata.ColorEncoding.WantIcc and not Headers.Metadata.XybEncoded then
    Image.IccProfile := Profile;
  Image.Metadata.SetValue(MetadataKeyColorSpace, ColorSpaceDescription(Headers.Metadata));
  if Encoding = JxlEncodingVarDct then
    Image.Metadata.SetValue('JxlEncoding', 'VarDCT')
  else
    Image.Metadata.SetValue('JxlEncoding', 'Modular');
  if Length(Contents.BoxNames) > 0 then
    Image.Metadata.SetValue('JxlBoxes', JoinNames(Contents.BoxNames));
end;

{ The image of the shown frames (which it takes as its own). }
function BuildImage(var Shown: TShownFrames; const Headers: TJxlImageHeaders): TImage;
var
  Animation: TAnimatedImage;
  First: TImage;
  Index: LongInt;
  Frame: TImageFrame;
begin
  if (not Headers.Metadata.HaveAnimation) or (Length(Shown) < 2) then
  begin
    Result := Shown[High(Shown)].Image;
    Shown[High(Shown)].Image := nil;
    Exit;
  end;
  Animation := TAnimatedImage.Create(Headers.Width, Headers.Height);
  try
    Animation.LoopCount := Headers.Metadata.Animation.LoopCount;
    for Index := 0 to High(Shown) do
    begin
      Frame := TImageFrame.Create(Shown[Index].Image);
      Shown[Index].Image := nil;
      Frame.Left := 0;
      Frame.Top := 0;
      Frame.Delay := DelayInMilliseconds(Shown[Index].Duration, Headers.Metadata.Animation);
      Frame.Disposal := FrameDisposalNone;
      Frame.Blend := FrameBlendSource;
      Animation.AddFrame(Frame);
    end;
    First := Animation.Frames[0].Image;
    Move(First.Pixels^, Animation.Pixels^, SizeOf(LongWord) * PtrUInt(First.Width) * PtrUInt(First.Height));
  except
    Animation.Free;
    raise;
  end;
  Result := Animation;
end;

function DecodeJxlImage(const Data: TBytes): TImage;
var
  Contents: TJxlFileContents;
  Codestream: TBytes;
  Reader: TJxlBitReader;
  Headers: TJxlImageHeaders;
  Profile: TBytes;
  Position: PtrInt;
  Context: TJxlDecodingContext;
  Frame: TJxlDecodedFrame;
  Shown: TShownFrames;
  IsLast: Boolean;
  Index: LongInt;
  FrameCount: LongInt;
begin
  Contents := ReadJxlFileContents(Data);
  Codestream := Contents.Codestream;
  if Length(Codestream) < 2 then
    RaiseImageError(ImageErrorTruncated, 'JPEG XL codestream');
  if (Codestream[0] <> JxlCodestreamSignature[0]) or (Codestream[1] <> JxlCodestreamSignature[1]) then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL codestream signature');
  Profile := nil;
  Reader := TJxlBitReader.Create(Codestream, 2, -1);
  try
    Headers := ReadJxlImageHeaders(Reader);
    CheckImageSize(Headers.Width, Headers.Height);
    if Headers.Metadata.ColorEncoding.WantIcc then
      Profile := ReadJxlIccProfile(Reader);
    Reader.ZeroPadToByte;
    Position := Reader.BytePosition;
  finally
    Reader.Free;
  end;
  Context := Default(TJxlDecodingContext);
  Shown := nil;
  try
    if Headers.Metadata.HavePreview then
      SkipJxlFrame(Codestream, Position, Headers, True);
    FrameCount := 0;
    IsLast := False;
    while not IsLast do
    begin
      Inc(FrameCount);
      if FrameCount > 1000000 then
        RaiseImageError(ImageErrorMalformed, 'JPEG XL: too many frames');
      try
        Frame := DecodeJxlFrame(Codestream, Position, Headers, Context);
      except
        on EImageError do
        begin
          if Length(Shown) > 0 then
            Break;
          raise;
        end;
      end;
      try
        IsLast := Frame.Header.IsLast;
        HandleFrame(Frame, Context, Headers, Shown);
      finally
        FreeJxlDecodedFrame(Frame);
      end;
    end;
    if Length(Shown) = 0 then
      RaiseImageError(ImageErrorMalformed, 'JPEG XL: no frame to show');
    Result := BuildImage(Shown, Headers);
    DescribeImage(Result, Headers, Contents, Profile, Shown[0].Encoding);
  finally
    for Index := 0 to High(Shown) do
      Shown[Index].Image.Free;
    ReleaseContext(Context);
  end;
end;

end.

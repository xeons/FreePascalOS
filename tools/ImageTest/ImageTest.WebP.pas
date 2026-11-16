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
  WebP: the fixtures of make-webp-fixtures.py against Pillow's (that
  is libwebp's) decoding: lossless exactly, lossy within one step per
  channel (the decoder follows libwebp's arithmetic, so it should be
  exact); the metadata; animations frame by frame as seen; and the
  encoder, read back exactly here and by Pillow (check-with-pillow.py).
}
unit ImageTest.WebP;

{$mode objfpc}
{$H+}

interface

procedure TestWebP;

implementation

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Frames,
  Image.Compositing,
  Image.Codecs,
  Image.Files,
  Image.WebP.Decoder,
  ImageTest.Checks;

const
  LossyTolerance = 1;
  LossyMeanTolerance = 0.01;
  { Premultiplied colour steps between libdrawing's exact blending of
    translucent pixels and libwebp's (whose rounding drifts most where
    both pixels are nearly transparent). }
  TranslucentTolerance = 4;

  LosslessFixtures: array[0..12] of string = (
    'webp-lossless-photo', 'webp-lossless-alpha', 'webp-lossless-palette2', 'webp-lossless-palette4',
    'webp-lossless-palette16', 'webp-lossless-palette200', 'webp-lossless-flat', 'webp-lossless-1x1',
    'webp-lossless-column', 'webp-lossless-fast', 'webp-lossless-best', 'webp-lossless-smooth', 'webp-metadata');

  LossyFixtures: array[0..20] of string = (
    'webp-lossy-q10', 'webp-lossy-q50', 'webp-lossy-q75', 'webp-lossy-q95', 'webp-lossy-q100', 'webp-lossy-fast',
    'webp-lossy-best', 'webp-lossy-odd', 'webp-lossy-1x1', 'webp-lossy-3x2', 'webp-lossy-large', 'webp-lossy-alpha',
    'webp-lossy-alpha-q30', 'webp-alpha-filter-0', 'webp-alpha-filter-1', 'webp-alpha-filter-2',
    'webp-alpha-filter-3', 'webp-alpha-lossless-0', 'webp-alpha-lossless-1', 'webp-alpha-lossless-2',
    'webp-alpha-lossless-3');

  { Made with libwebp through ctypes: left out when it could not be
    loaded. }
  LibwebpFixtures: array[0..7] of string = (
    'webp-libwebp-simple-filter', 'webp-libwebp-sharp', 'webp-libwebp-soft', 'webp-libwebp-partitions',
    'webp-libwebp-no-filter', 'webp-libwebp-one-segment', 'webp-libwebp-alpha-raw', 'webp-libwebp-alpha-best');

function LoadFixture(const Name: string): TImage;
begin
  try
    Result := LoadImage(FixtureBytes(Name));
  except
    on Error: Exception do
    begin
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
      Result := nil;
    end;
  end;
end;

function LoadAnimation(const Name: string): TAnimatedImage;
var
  Image: TImage;
begin
  Result := nil;
  Image := LoadFixture(Name);
  if Image is TAnimatedImage then
    Result := TAnimatedImage(Image)
  else
  begin
    if Image <> nil then
      Note(Name + ': not an animation');
    Image.Free;
  end;
end;

procedure CheckStill(const Name: string; Tolerance: LongInt; MeanTolerance: Double; const Compression: string);
var
  Image: TImage;
begin
  Image := LoadFixture(Name + '.webp');
  try
    CheckImageMatchesReference('webp ' + Name, Image, Name + '.rgba', Tolerance, MeanTolerance);
    if Image <> nil then
      Check((Image.SourceFormatName = 'WebP') and (Image.Metadata.GetValue(MetadataKeyCompression) = Compression),
        'webp ' + Name + ': format and compression');
  finally
    Image.Free;
  end;
end;

procedure TestStills;
var
  Index: LongInt;
  Image: TImage;
begin
  Check(DetectFileFormat(FixtureBytes('webp-lossless-photo.webp')) = ImageFormatWebp, 'a WebP is recognised');
  Check(ImageFormatFromName('webp') = ImageFormatWebp, 'the name webp is WebP');
  for Index := 0 to High(LosslessFixtures) do
    CheckStill(LosslessFixtures[Index], 0, -1, WebPCompressionLossless);
  for Index := 0 to High(LossyFixtures) do
    CheckStill(LossyFixtures[Index], LossyTolerance, LossyMeanTolerance, WebPCompressionLossy);
  for Index := 0 to High(LibwebpFixtures) do
    if FileExists(FixturePath(LibwebpFixtures[Index] + '.webp')) then
      CheckStill(LibwebpFixtures[Index], LossyTolerance, LossyMeanTolerance, WebPCompressionLossy)
    else
      Note(LibwebpFixtures[Index] + ': not made (no libwebp for ctypes)');
  Image := LoadFixture('webp-lossy-alpha.webp');
  try
    Check((Image <> nil) and Image.SourceHasAlpha and (Image.SourceBitsPerPixel = 32), 'lossy WebP with ALPH has alpha');
  finally
    Image.Free;
  end;
  Image := LoadFixture('webp-lossy-q75.webp');
  try
    Check((Image <> nil) and not Image.SourceHasAlpha and (Image.SourceBitsPerPixel = 24), 'lossy WebP is opaque');
  finally
    Image.Free;
  end;
end;

function BytesText(const Bytes: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], Result[1], Length(Bytes));
end;

procedure TestMetadata;
var
  Image: TImage;
  Profile: TBytes;
begin
  Image := LoadFixture('webp-metadata.webp');
  if Image = nil then
  begin
    Check(False, 'webp-metadata.webp loads');
    Exit;
  end;
  try
    Profile := FixtureBytes('webp-metadata.icc');
    Check((Length(Image.IccProfile) = Length(Profile)) and (Length(Profile) > 0) and
      CompareMem(@Image.IccProfile[0], @Profile[0], Length(Profile)), 'webp ICCP chunk as the profile');
    Check(Image.Orientation = OrientationRotate90, 'webp EXIF orientation 6');
    Check(Image.Metadata.GetValue(MetadataKeyXmp) = BytesText(FixtureBytes('webp-metadata.xmp')), 'webp XMP chunk');
  finally
    Image.Free;
  end;
end;

{ --- Animations ------------------------------------------------------- }

{ Image against a reference by premultiplied colour: no channel times
  its alpha further than Tolerance (in steps of 255), alpha no further
  than 2. }
procedure CheckPremultipliedMatch(const Name: string; Image: TImage; const ReferenceName: string; Tolerance: LongInt);
var
  Reference: TBytes;
  X: LongInt;
  Y: LongInt;
  Offset: PtrInt;
  Pixel: LongWord;
  Alpha: LongInt;
  ReferenceAlpha: LongInt;
  Shift: LongInt;
  Channel: LongInt;
  Largest: LongInt;
  Difference: LongInt;
begin
  if Image = nil then
  begin
    Check(False, Name + ' (no image)');
    Exit;
  end;
  Reference := FixtureBytes(ReferenceName);
  if (Length(Reference) <> 8 + PtrInt(Image.Width) * Image.Height * 4) or
    (PLongInt(@Reference[0])^ <> Image.Width) or (PLongInt(@Reference[4])^ <> Image.Height) then
  begin
    Check(False, Name + ' (reference of another size)');
    Exit;
  end;
  Largest := 0;
  for Y := 0 to Image.Height - 1 do
    for X := 0 to Image.Width - 1 do
    begin
      Offset := 8 + (PtrInt(Y) * Image.Width + X) * 4;
      Pixel := Image.Line(Y)[X];
      Alpha := Pixel shr 24;
      ReferenceAlpha := Reference[Offset + 3];
      if Abs(Alpha - ReferenceAlpha) > 2 then
        Largest := High(LongInt);
      for Channel := 0 to 2 do
      begin
        Shift := 16 - 8 * Channel;
        Difference := Abs(LongInt((Pixel shr Shift) and $FF) * Alpha -
          LongInt(Reference[Offset + Channel]) * ReferenceAlpha) div 255;
        if Difference > Largest then
          Largest := Difference;
      end;
    end;
  Check(Largest <= Tolerance, Name);
  if Largest > 0 then
    Note(Format('largest premultiplied difference %d', [Largest]));
end;

procedure CheckCanvases(const Name: string; Animation: TAnimatedImage; const ReferenceBase: string;
  Tolerance: LongInt);
var
  Canvases: TImageList;
  Index: LongInt;
begin
  CheckImageMatchesReference(Name + ': the first frame as the image', Animation, ReferenceBase + '.rgba', Tolerance);
  Canvases := CompositeFrames(Animation);
  try
    for Index := 0 to Canvases.Count - 1 do
      CheckImageMatchesReference(Name + ': frame ' + IntToStr(Index) + ' as seen', Canvases[Index],
        ReferenceBase + '-frame' + IntToStr(Index) + '.rgba', Tolerance);
  finally
    Canvases.Free;
  end;
end;

procedure TestFlagsAnimation;
const
  Delays: array[0..4] of LongInt = (100, 200, 50, 0, 300);
  Lefts: array[0..4] of LongInt = (0, 4, 10, 24, 0);
  Tops: array[0..4] of LongInt = (0, 6, 14, 2, 0);
  Disposals: array[0..4] of TFrameDisposal = (FrameDisposalNone, FrameDisposalBackground, FrameDisposalNone,
    FrameDisposalBackground, FrameDisposalNone);
  Blends: array[0..4] of TFrameBlend = (FrameBlendSource, FrameBlendOver, FrameBlendSource, FrameBlendOver,
    FrameBlendOver);
var
  Animation: TAnimatedImage;
  Index: LongInt;
  AllMatch: Boolean;
begin
  Animation := LoadAnimation('webp-anim-flags.webp');
  if Animation = nil then
  begin
    Check(False, 'an animated WebP loads as an animation');
    Exit;
  end;
  try
    Check((Animation.FrameCount = 5) and (Animation.LoopCount = 3) and (Animation.BackgroundColor = $FF336699),
      'webp ANIM: five frames, three plays, the background colour');
    Check((Animation.Width = 40) and (Animation.Height = 30) and (Animation.SourceFormatName = 'WebP'),
      'webp canvas size');
    if Animation.FrameCount <> 5 then
      Exit;
    AllMatch := True;
    for Index := 0 to 4 do
      AllMatch := AllMatch and (Animation.Frames[Index].Delay = Delays[Index]) and
        (Animation.Frames[Index].Left = Lefts[Index]) and (Animation.Frames[Index].Top = Tops[Index]) and
        (Animation.Frames[Index].Disposal = Disposals[Index]) and (Animation.Frames[Index].Blend = Blends[Index]);
    Check(AllMatch, 'webp ANMF: durations, offsets, dispose and blend flags');
    CheckCanvases('webp-anim-flags', Animation, 'webp-anim-flags', 0);
  finally
    Animation.Free;
  end;
end;

procedure TestOtherAnimations;
var
  Animation: TAnimatedImage;
  Canvases: TImageList;
  Index: LongInt;
begin
  Animation := LoadAnimation('webp-anim-translucent.webp');
  if Animation <> nil then
    try
      Check(Animation.FrameCount = 4, 'translucent webp animation: four frames');
      Canvases := CompositeFrames(Animation);
      try
        for Index := 0 to Canvases.Count - 1 do
          CheckPremultipliedMatch('webp-anim-translucent: frame ' + IntToStr(Index) + ' as seen', Canvases[Index],
            'webp-anim-translucent-frame' + IntToStr(Index) + '.rgba', TranslucentTolerance);
      finally
        Canvases.Free;
      end;
    finally
      Animation.Free;
    end
  else
    Check(False, 'webp-anim-translucent.webp loads');

  Animation := LoadAnimation('webp-anim-mixed.webp');
  if Animation <> nil then
    try
      Check((Animation.FrameCount = 3) and (Animation.LoopCount = 1) and
        (Animation.Metadata.GetValue(MetadataKeyCompression) = WebPCompressionMixed),
        'webp animation of lossy and lossless frames');
      CheckCanvases('webp-anim-mixed', Animation, 'webp-anim-mixed', LossyTolerance);
    finally
      Animation.Free;
    end
  else
    Check(False, 'webp-anim-mixed.webp loads');

  Animation := LoadAnimation('webp-anim-pillow-lossless.webp');
  if Animation <> nil then
    try
      Check((Animation.FrameCount = 4) and (Animation.LoopCount = 2) and (Animation.Frames[0].Delay = 70) and
        (Animation.Frames[3].Delay = 280), 'Pillow''s lossless webp animation: frames, loops, durations');
      CheckCanvases('webp-anim-pillow-lossless', Animation, 'webp-anim-pillow-lossless', 0);
    finally
      Animation.Free;
    end
  else
    Check(False, 'webp-anim-pillow-lossless.webp loads');

  Animation := LoadAnimation('webp-anim-pillow-lossy.webp');
  if Animation <> nil then
    try
      Check(Animation.FrameCount = 4, 'Pillow''s lossy webp animation: four frames');
      CheckCanvases('webp-anim-pillow-lossy', Animation, 'webp-anim-pillow-lossy', LossyTolerance);
    finally
      Animation.Free;
    end
  else
    Check(False, 'webp-anim-pillow-lossy.webp loads');

  Animation := LoadAnimation('webp-anim-truncated.webp');
  if Animation <> nil then
    try
      Check(Animation.FrameCount = 3, 'a webp animation cut in its fourth frame keeps three');
      Canvases := CompositeFrames(Animation);
      try
        for Index := 0 to Canvases.Count - 1 do
          CheckImageMatchesReference('the cut animation''s frame ' + IntToStr(Index), Canvases[Index],
            'webp-anim-flags-frame' + IntToStr(Index) + '.rgba', 0);
      finally
        Canvases.Free;
      end;
    finally
      Animation.Free;
    end
  else
    Check(False, 'webp-anim-truncated.webp loads');
end;

{ --- Writing ------------------------------------------------------------ }

type
  TPatternAlpha = (PatternOpaque, PatternBinary, PatternTranslucent);

function PatternImage(Width, Height, Seed: LongInt; AlphaKind: TPatternAlpha): TImage;
var
  X: LongInt;
  Y: LongInt;
  Alpha: LongWord;
  State: LongWord;
begin
  Result := TImage.Create(Width, Height);
  State := LongWord((QWord(Seed) * 2654435761) and $FFFFFFFF);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      State := LongWord((QWord(State) * 1103515245 + 12345) and $FFFFFFFF);
      Alpha := 255;
      if (AlphaKind <> PatternOpaque) and ((X + Y + Seed) mod 5 = 0) then
        Alpha := 0
      else if (AlphaKind = PatternTranslucent) and ((X * Seed) mod 3 = 0) then
        Alpha := (X * 9 + Y) and $FF;
      { Gradients, a repeated pattern (for backward references) and a
        little noise; colours under transparent pixels kept as well. }
      Result.Line(Y)[X] := (Alpha shl 24) or (LongWord((X * 5 + Seed * 40) and $FF) shl 16) or
        (LongWord(((Y div 4) * 37 + (X div 8) * 11) and $FF) shl 8) or
        LongWord((X * Y + (State shr 28)) and $FF);
    end;
end;

procedure CheckRoundTrip(const Name: string; Image: TImage);
var
  Data: TBytes;
  Back: TImage;
begin
  Back := nil;
  try
    try
      Data := EncodeImage(Image, ImageFormatWebp);
      WriteForPillow(Name + '.webp', Data, Image);
      Back := LoadImage(Data);
      Check((Back.Width = Image.Width) and (Back.Height = Image.Height) and (LargestPixelDifference(Image, Back) = 0),
        'webp writing ' + Name + ': read back exactly');
      Check(Back.Metadata.GetValue(MetadataKeyCompression) = WebPCompressionLossless,
        'webp writing ' + Name + ': lossless');
    except
      on Error: Exception do
      begin
        Check(False, 'webp writing ' + Name);
        Note(Error.ClassName + ': ' + Error.Message);
      end;
    end;
  finally
    Back.Free;
    Image.Free;
  end;
end;

procedure TestWritingStills;
var
  Image: TImage;
  Back: TImage;
  Data: TBytes;
  Profile: TBytes;
  Index: LongInt;
begin
  CheckRoundTrip('written-webp-opaque', PatternImage(64, 40, 1, PatternOpaque));
  CheckRoundTrip('written-webp-alpha', PatternImage(51, 33, 2, PatternTranslucent));
  CheckRoundTrip('written-webp-1x1', PatternImage(1, 1, 3, PatternTranslucent));
  CheckRoundTrip('written-webp-row', PatternImage(97, 1, 4, PatternOpaque));
  CheckRoundTrip('written-webp-column', PatternImage(1, 77, 5, PatternTranslucent));
  CheckRoundTrip('written-webp-large', PatternImage(320, 240, 6, PatternTranslucent));
  Image := TImage.Create(19, 23);
  Image.Fill($FF204060);
  CheckRoundTrip('written-webp-flat', Image);

  Image := PatternImage(30, 20, 7, PatternOpaque);
  try
    Profile := nil;
    SetLength(Profile, 300);
    for Index := 0 to High(Profile) do
      Profile[Index] := Index and $FF;
    Image.IccProfile := Profile;
    Image.Orientation := OrientationRotate270;
    Image.Metadata.SetValue(MetadataKeyXmp, '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>');
    Data := EncodeImage(Image, ImageFormatWebp);
    WriteForPillow('written-webp-metadata.webp', Data, Image);
    Back := LoadImage(Data);
    try
      Check((LargestPixelDifference(Image, Back) = 0) and (Length(Back.IccProfile) = 300) and
        CompareMem(@Back.IccProfile[0], @Profile[0], 300) and (Back.Orientation = OrientationRotate270) and
        (Back.Metadata.GetValue(MetadataKeyXmp) = Image.Metadata.GetValue(MetadataKeyXmp)),
        'webp writing: profile, orientation and XMP read back');
    finally
      Back.Free;
    end;
  finally
    Image.Free;
  end;

  Image := TImage.Create(16385, 1);
  try
    try
      EncodeImage(Image, ImageFormatWebp);
      Check(False, 'webp writing refuses a picture wider than 16384');
    except
      on Error: EImageError do
        Check(Error.Reason = ImageErrorUnsupported, 'webp writing refuses a picture wider than 16384');
    end;
  finally
    Image.Free;
  end;
end;

function AddFrame(Animation: TAnimatedImage; Image: TImage; Left, Top, Delay: LongInt; Disposal: TFrameDisposal;
  Blend: TFrameBlend): TImageFrame;
begin
  Result := TImageFrame.Create(Image);
  Result.Left := Left;
  Result.Top := Top;
  Result.Delay := Delay;
  Result.Disposal := Disposal;
  Result.Blend := Blend;
  Animation.AddFrame(Result);
end;

procedure SetFirstFrameAsImage(Animation: TAnimatedImage);
var
  Canvases: TImageList;
begin
  Canvases := CompositeFrames(Animation);
  try
    Move(Canvases[0].Pixels^, Animation.Pixels^, PtrUInt(Animation.Width) * PtrUInt(Animation.Height) * 4);
  finally
    Canvases.Free;
  end;
end;

{ Writes Animation for Pillow with every frame as seen (its frames have
  no translucent pixels, so libwebp's blending gives the same). }
procedure WriteAnimationForPillow(const Name: string; const Data: TBytes; Animation: TAnimatedImage);
var
  Canvases: TImageList;
  Index: LongInt;
begin
  WriteForPillow(Name + '.webp', Data, Animation);
  Canvases := CompositeFrames(Animation);
  try
    for Index := 1 to Canvases.Count - 1 do
      WriteReferenceForPillow(Name + '-frame' + IntToStr(Index) + '.rgba', Canvases[Index]);
  finally
    Canvases.Free;
  end;
end;

function SameCanvases(First, Second: TAnimatedImage): Boolean;
var
  A: TImageList;
  B: TImageList;
  Index: LongInt;
begin
  Result := First.FrameCount = Second.FrameCount;
  if not Result then
    Exit;
  A := CompositeFrames(First);
  B := CompositeFrames(Second);
  try
    for Index := 0 to A.Count - 1 do
      Result := Result and (LargestPixelDifference(A[Index], B[Index]) = 0);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TestWritingAnimation(Flattened: Boolean; const Name: string);
var
  Animation: TAnimatedImage;
  Back: TImage;
  Data: TBytes;
  Index: LongInt;
  SameOps: Boolean;
begin
  Animation := TAnimatedImage.Create(30, 20);
  try
    Animation.LoopCount := 4;
    Animation.BackgroundColor := $FF102030;
    AddFrame(Animation, PatternImage(30, 20, 1, PatternOpaque), 0, 0, 120, FrameDisposalNone, FrameBlendSource);
    AddFrame(Animation, PatternImage(10, 8, 2, PatternBinary), 4, 6, 70, FrameDisposalBackground, FrameBlendOver);
    if Flattened then
      AddFrame(Animation, PatternImage(12, 12, 3, PatternBinary), 15, 7, 40, FrameDisposalPrevious, FrameBlendOver)
    else
      AddFrame(Animation, PatternImage(12, 12, 3, PatternBinary), 16, 8, 40, FrameDisposalNone, FrameBlendSource);
    AddFrame(Animation, PatternImage(8, 6, 4, PatternBinary), 2, 2, 0, FrameDisposalNone, FrameBlendOver);
    SetFirstFrameAsImage(Animation);
    Data := EncodeImage(Animation, ImageFormatWebp);
    WriteAnimationForPillow(Name, Data, Animation);
    Back := LoadImage(Data);
    try
      Check(Back is TAnimatedImage, Name + ': written and read back as an animation');
      if not (Back is TAnimatedImage) then
        Exit;
      Check((TAnimatedImage(Back).LoopCount = 4) and (TAnimatedImage(Back).BackgroundColor = $FF102030) and
        (TAnimatedImage(Back).FrameCount = 4) and (TAnimatedImage(Back).Frames[0].Delay = 120) and
        (TAnimatedImage(Back).Frames[3].Delay = 0), Name + ': loop count, background and durations');
      Check(SameCanvases(Animation, TAnimatedImage(Back)), Name + ': every frame as seen');
      Check(LargestPixelDifference(Animation, Back) = 0, Name + ': the first frame as the image');
      if not Flattened and (TAnimatedImage(Back).FrameCount = 4) then
      begin
        SameOps := True;
        for Index := 0 to 3 do
          SameOps := SameOps and (TAnimatedImage(Back).Frames[Index].Left = Animation.Frames[Index].Left) and
            (TAnimatedImage(Back).Frames[Index].Top = Animation.Frames[Index].Top) and
            (TAnimatedImage(Back).Frames[Index].Disposal = Animation.Frames[Index].Disposal) and
            (TAnimatedImage(Back).Frames[Index].Blend = Animation.Frames[Index].Blend) and
            (LargestPixelDifference(TAnimatedImage(Back).Frames[Index].Image, Animation.Frames[Index].Image) = 0);
        Check(SameOps, Name + ': frames, offsets, dispose and blend kept');
      end;
    finally
      Back.Free;
    end;
  finally
    Animation.Free;
  end;
end;

procedure TestWebP;
begin
  TestStills;
  TestMetadata;
  TestFlagsAnimation;
  TestOtherAnimations;
  TestWritingStills;
  TestWritingAnimation(False, 'written-webp-animation');
  TestWritingAnimation(True, 'written-webp-animation-flattened');
end;

end.

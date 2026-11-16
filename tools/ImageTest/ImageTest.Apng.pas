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
  APNG (make-png-fixtures.py): an animation whose default image is the
  first frame, with every dispose and blend op, frames at offsets and
  delays as fractions; one whose default image is not part of the
  animation; palette frames with tRNS; translucent frames blended over
  one another; a file cut in a frame's data keeping the frames before
  it. Each frame as seen is compared with the fixture script's
  compositor (and so with Pillow's). Then animations written as APNG
  and read back, frame by frame.
}
unit ImageTest.Apng;

{$mode objfpc}
{$H+}

interface

procedure TestApng;

implementation

uses
  SysUtils,
  Image.Model,
  Image.Frames,
  Image.Compositing,
  Image.Codecs,
  Image.Files,
  ImageTest.Checks;

function LoadAnimation(const Name: string): TAnimatedImage;
var
  Image: TImage;
begin
  Result := nil;
  try
    Image := LoadImage(FixtureBytes(Name));
    if Image is TAnimatedImage then
      Result := TAnimatedImage(Image)
    else
    begin
      Note(Name + ': not an animation');
      Image.Free;
    end;
  except
    on Error: Exception do
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
  end;
end;

procedure CheckCanvases(const Name: string; Animation: TAnimatedImage);
var
  Base: string;
  Canvases: TImageList;
  Index: LongInt;
begin
  Base := ChangeFileExt(Name, '');
  CheckImageMatchesReference(Name + ': the default image', Animation, Base + '-default.rgba', 0);
  Canvases := CompositeFrames(Animation);
  try
    for Index := 0 to Canvases.Count - 1 do
      CheckImageMatchesReference(Name + ': frame ' + IntToStr(Index) + ' as seen', Canvases[Index],
        Base + '-frame' + IntToStr(Index) + '.rgba', 0);
  finally
    Canvases.Free;
  end;
end;

procedure TestDefaultFrame;
const
  Delays: array[0..5] of LongInt = (100, 200, 10, 429, 0, 500);
  Disposals: array[0..5] of TFrameDisposal = (FrameDisposalBackground, FrameDisposalNone, FrameDisposalBackground,
    FrameDisposalPrevious, FrameDisposalPrevious, FrameDisposalNone);
  Blends: array[0..5] of TFrameBlend = (FrameBlendSource, FrameBlendOver, FrameBlendSource, FrameBlendOver,
    FrameBlendSource, FrameBlendOver);
var
  Animation: TAnimatedImage;
  Index: LongInt;
  AllMatch: Boolean;
begin
  Animation := LoadAnimation('apng-default-frame.png');
  if Animation = nil then
  begin
    Check(False, 'an APNG loads as an animation');
    Exit;
  end;
  try
    Check(Animation.FrameCount = 6, 'six frames, the default image the first');
    Check(Animation.LoopCount = 3, 'three plays');
    Check(Animation.SourceFormatName = 'PNG', 'format name PNG');
    if Animation.FrameCount <> 6 then
      Exit;
    AllMatch := True;
    for Index := 0 to 5 do
      AllMatch := AllMatch and (Animation.Frames[Index].Delay = Delays[Index]) and
        (Animation.Frames[Index].Disposal = Disposals[Index]) and (Animation.Frames[Index].Blend = Blends[Index]);
    Check(AllMatch, 'delays from fractions, dispose and blend ops (a first "previous" clears)');
    Check((Animation.Frames[1].Left = 5) and (Animation.Frames[1].Top = 4) and (Animation.Frames[1].Image.Width = 12),
      'frame offset and size');
    CheckCanvases('apng-default-frame.png', Animation);
  finally
    Animation.Free;
  end;
end;

procedure TestOthers;
var
  Animation: TAnimatedImage;
begin
  Animation := LoadAnimation('apng-default-separate.png');
  if Animation <> nil then
    try
      Check((Animation.FrameCount = 3) and (Animation.LoopCount = 0), 'a default image not part of the animation');
      if Animation.FrameCount = 3 then
        Check((Animation.Frames[0].Delay = 1000) and (Animation.Frames[1].Delay = 2000) and
          (Animation.Frames[2].Delay = 65535), 'delays of whole seconds');
      CheckCanvases('apng-default-separate.png', Animation);
    finally
      Animation.Free;
    end
  else
    Check(False, 'apng-default-separate.png loads');
  Animation := LoadAnimation('apng-palette.png');
  if Animation <> nil then
    try
      Check(Animation.FrameCount = 3, 'palette frames');
      CheckCanvases('apng-palette.png', Animation);
    finally
      Animation.Free;
    end
  else
    Check(False, 'apng-palette.png loads');
  Animation := LoadAnimation('apng-translucent.png');
  if Animation <> nil then
    try
      CheckCanvases('apng-translucent.png', Animation);
    finally
      Animation.Free;
    end
  else
    Check(False, 'apng-translucent.png loads');
  Animation := LoadAnimation('apng-truncated.png');
  if Animation <> nil then
    try
      Check(Animation.FrameCount = 1, 'an APNG cut in its second frame keeps the first');
      CheckImageMatchesReference('the frame kept', Animation, 'apng-default-frame-default.rgba', 0);
    finally
      Animation.Free;
    end
  else
    Check(False, 'apng-truncated.png loads');
end;

{ --- Writing --------------------------------------------------------- }

function PatternImage(Width, Height, Seed: LongInt): TImage;
var
  X: LongInt;
  Y: LongInt;
  Alpha: LongWord;
begin
  Result := TImage.Create(Width, Height);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      if (X + Y + Seed) mod 4 = 0 then
        Alpha := 0
      else if (X * Seed) mod 3 = 0 then
        Alpha := 128
      else
        Alpha := 255;
      if Alpha = 0 then
        Result.Line(Y)[X] := 0
      else
        Result.Line(Y)[X] := (Alpha shl 24) or (LongWord((X * 7 + Seed * 40) and $FF) shl 16) or
          (LongWord((Y * 11) and $FF) shl 8) or LongWord((X * Y + Seed) and $FF);
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

function MakeAnimation(DefaultIsFirst: Boolean): TAnimatedImage;
var
  First: TImage;
  Canvases: TImageList;
begin
  Result := TAnimatedImage.Create(30, 20);
  Result.LoopCount := 2;
  if DefaultIsFirst then
    First := PatternImage(30, 20, 1)
  else
    First := PatternImage(20, 10, 1);
  AddFrame(Result, First, 0, 0, 120, FrameDisposalNone, FrameBlendSource);
  AddFrame(Result, PatternImage(10, 8, 2), 3, 4, 70000, FrameDisposalBackground, FrameBlendOver);
  AddFrame(Result, PatternImage(12, 12, 3), 15, 6, 40, FrameDisposalPrevious, FrameBlendOver);
  AddFrame(Result, PatternImage(30, 20, 4), 0, 0, 0, FrameDisposalNone, FrameBlendOver);
  if DefaultIsFirst then
    Move(First.Pixels^, Result.Pixels^, 30 * 20 * SizeOf(LongWord))
  else
  begin
    Canvases := CompositeFrames(Result);
    try
      { Something else for viewers that do not animate. }
      Move(Canvases[3].Pixels^, Result.Pixels^, 30 * 20 * SizeOf(LongWord));
      Result.Line(0)[0] := $FF123456;
    finally
      Canvases.Free;
    end;
  end;
end;

function SameFrames(First, Second: TAnimatedImage): Boolean;
var
  Index: LongInt;
  A: TImageFrame;
  B: TImageFrame;
begin
  Result := First.FrameCount = Second.FrameCount;
  if not Result then
    Exit;
  for Index := 0 to First.FrameCount - 1 do
  begin
    A := First.Frames[Index];
    B := Second.Frames[Index];
    Result := Result and (A.Left = B.Left) and (A.Top = B.Top) and (A.Disposal = B.Disposal) and
      (A.Blend = B.Blend) and (LargestPixelDifference(A.Image, B.Image) = 0);
  end;
end;

procedure TestWritingAnimation(DefaultIsFirst: Boolean; const Name: string);
var
  Animation: TAnimatedImage;
  Data: TBytes;
  Back: TImage;
begin
  Animation := MakeAnimation(DefaultIsFirst);
  try
    Data := EncodeImage(Animation, ImageFormatPng);
    WriteForPillow(Name, Data, Animation);
    Back := LoadImage(Data);
    try
      Check(Back is TAnimatedImage, Name + ': written and read back as an animation');
      if not (Back is TAnimatedImage) then
        Exit;
      Check(SameFrames(Animation, TAnimatedImage(Back)), Name + ': the same frames, offsets and ops');
      Check(LargestPixelDifference(Animation, Back) = 0, Name + ': the same default image');
      Check((TAnimatedImage(Back).LoopCount = 2) and (TAnimatedImage(Back).Frames[0].Delay = 120) and
        (TAnimatedImage(Back).Frames[1].Delay = 70000) and (TAnimatedImage(Back).Frames[3].Delay = 0),
        Name + ': loop count and delays');
    finally
      Back.Free;
    end;
  finally
    Animation.Free;
  end;
end;

procedure TestApng;
begin
  TestDefaultFrame;
  TestOthers;
  TestWritingAnimation(True, 'written-apng-default-frame.png');
  TestWritingAnimation(False, 'written-apng-default-separate.png');
end;

end.

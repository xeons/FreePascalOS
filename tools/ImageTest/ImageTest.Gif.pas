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
  GIF (make-fixtures.py): an animation of five frames with every
  disposal, transparency, a local palette, interlacing and a frame
  reaching outside the canvas, composited frame by frame and compared
  with the canvases a player shows; delays, loop count and comment; a
  256-colour picture whose code table fills and starts again; two
  colours in GIF87a; a file with only local palettes and a screen of
  0 x 0; Pillow's own GIF; a file cut short keeping its frames; writing
  a frame and reading it back; malformed files.
}
unit ImageTest.Gif;

{$mode objfpc}
{$H+}

interface

procedure TestGif;

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

procedure TestAnimation;
const
  ExpectedDelays: array[0..4] of LongInt = (100, 200, 50, 0, 70);
  ExpectedDisposals: array[0..4] of TFrameDisposal = (FrameDisposalNone, FrameDisposalBackground,
    FrameDisposalPrevious, FrameDisposalNone, FrameDisposalNone);
var
  Animation: TAnimatedImage;
  Canvases: TImageList;
  Compositor: TFrameCompositor;
  Index: LongInt;
  DelaysMatch: Boolean;
begin
  Animation := LoadAnimation('anim.gif');
  if Animation = nil then
  begin
    Check(False, 'animation loads');
    Exit;
  end;
  try
    Check(Animation.FrameCount = 5, 'animation of five frames');
    Check((Animation.Width = 40) and (Animation.Height = 30), 'canvas 40 x 30');
    Check(Animation.LoopCount = 3, 'loop count 3');
    Check(Animation.Metadata.GetValue(MetadataKeyComment) = 'FreePascalOS test animation', 'comment');
    Check(Animation.SourceFormatName = 'GIF', 'format name GIF');
    if Animation.FrameCount <> 5 then
      Exit;
    DelaysMatch := True;
    for Index := 0 to 4 do
      DelaysMatch := DelaysMatch and (Animation.Frames[Index].Delay = ExpectedDelays[Index]) and
        (Animation.Frames[Index].Disposal = ExpectedDisposals[Index]);
    Check(DelaysMatch, 'delays and disposals');
    Check((Animation.Frames[2].Left = 20) and (Animation.Frames[2].Top = 10) and
      (Animation.Frames[2].Image.Width = 12), 'frame offset and size');
    Check(Animation.TotalDuration = 420, 'total duration');
    CheckImageMatchesReference('animation pixels are its first frame', Animation, 'anim-0.rgba', 0);
    Canvases := CompositeFrames(Animation);
    try
      for Index := 0 to Canvases.Count - 1 do
        CheckImageMatchesReference('composited frame ' + IntToStr(Index), Canvases[Index],
          'anim-' + IntToStr(Index) + '.rgba', 0);
    finally
      Canvases.Free;
    end;
    { Playing on: after the last frame the first again; jumping back. }
    Compositor := TFrameCompositor.Create(Animation);
    try
      for Index := 0 to 5 do
        Compositor.NextFrame;
      CheckImageMatchesReference('playing wraps round to the first frame', Compositor.Canvas, 'anim-0.rgba', 0);
      Compositor.RenderFrame(3);
      Compositor.RenderFrame(1);
      CheckImageMatchesReference('going back to frame 1', Compositor.Canvas, 'anim-1.rgba', 0);
      Compositor.RenderFrame(4);
      CheckImageMatchesReference('going on to frame 4', Compositor.Canvas, 'anim-4.rgba', 0);
    finally
      Compositor.Free;
    end;
  finally
    Animation.Free;
  end;
end;

procedure CheckStill(const Name: string; const ReferenceName: string);
var
  Animation: TAnimatedImage;
begin
  Animation := LoadAnimation(Name);
  try
    if Animation <> nil then
      Check(Animation.FrameCount = 1, Name + ' has one frame');
    CheckImageMatchesReference(Name + ' pixels', Animation, ReferenceName, 0);
  finally
    Animation.Free;
  end;
end;

procedure TestStills;
var
  Animation: TAnimatedImage;
begin
  CheckStill('noise.gif', 'noise.rgba');
  CheckStill('bilevel.gif', 'bilevel.rgba');
  CheckStill('local-only.gif', 'local-only.rgba');
  CheckStill('pillow.gif', 'pillow.rgba');
  Animation := LoadAnimation('bilevel.gif');
  try
    if Animation <> nil then
      Check(Animation.LoopCount = 1, 'without NETSCAPE2.0 an animation plays once');
  finally
    Animation.Free;
  end;
end;

procedure TestTruncated;
var
  Animation: TAnimatedImage;
  Canvases: TImageList;
  Index: LongInt;
begin
  Animation := LoadAnimation('anim-truncated.gif');
  if Animation = nil then
  begin
    Check(False, 'a GIF cut short still loads');
    Exit;
  end;
  try
    Check(Animation.FrameCount >= 3, 'a GIF cut short keeps its frames (' + IntToStr(Animation.FrameCount) + ')');
    Canvases := CompositeFrames(Animation);
    try
      for Index := 0 to 2 do
        if Index < Canvases.Count then
          CheckImageMatchesReference('cut short: frame ' + IntToStr(Index), Canvases[Index],
            'anim-' + IntToStr(Index) + '.rgba', 0);
    finally
      Canvases.Free;
    end;
  finally
    Animation.Free;
  end;
end;

procedure TestWriting;
var
  Source: TImage;
  Back: TImage;
  Data: TBytes;
  X: LongInt;
  Y: LongInt;
  Photo: TImage;
begin
  { Few colours and transparency: exact. }
  Source := TImage.Create(33, 17);
  try
    for Y := 0 to Source.Height - 1 do
      for X := 0 to Source.Width - 1 do
        if (X * Y) mod 7 = 0 then
          Source.SetPixel(X, Y, 0)
        else
          Source.SetPixel(X, Y, $FF000000 or LongWord(((X mod 10) * 25) shl 16) or LongWord((Y mod 9) * 30));
    Data := EncodeImage(Source, ImageFormatGif);
    Back := LoadImage(Data);
    try
      Check(LargestPixelDifference(Source, Back) = 0, 'GIF of few colours written and read back exactly');
    finally
      Back.Free;
    end;
  finally
    Source.Free;
  end;
  { A large picture of one colour: long strings, the table filling. }
  Source := TImage.Create(300, 200);
  try
    Source.Fill($FF336699);
    Back := LoadImage(EncodeImage(Source, ImageFormatGif));
    try
      Check(LargestPixelDifference(Source, Back) = 0, 'GIF of one colour written and read back');
    finally
      Back.Free;
    end;
  finally
    Source.Free;
  end;
  { Thousands of colours: the fixed palette, near. }
  Photo := LoadImage(FixtureBytes('bmp24.bmp'));
  try
    Back := LoadImage(EncodeImage(Photo, ImageFormatGif));
    try
      X := LargestPixelDifference(Photo, Back);
      Check((X >= 0) and (X <= 26), 'GIF of many colours near the picture (' + IntToStr(X) + ')');
    finally
      Back.Free;
    end;
  finally
    Photo.Free;
  end;
end;

procedure CheckRefused(const Name: string; Expected: TImageErrorReason);
var
  Image: TImage;
  Reason: TImageErrorReason;
begin
  Image := nil;
  try
    if TryLoadImage(FixtureBytes(Name), Image, Reason) then
      Check(False, Name + ' refused (it was read)')
    else
      Check(Reason = Expected, Name + ' refused: ' + ImageErrorReasonText(Reason));
  except
    on Error: Exception do
      Check(False, Name + ' refused (' + Error.ClassName + ')');
  end;
  Image.Free;
end;

procedure TestMalformed;
var
  Image: TImage;
  Reason: TImageErrorReason;
begin
  CheckRefused('bad-gif-signature.gif', ImageErrorUnknownFormat);
  CheckRefused('bad-gif-header-only.gif', ImageErrorTruncated);
  CheckRefused('bad-gif-no-frames.gif', ImageErrorMalformed);
  CheckRefused('bad-gif-code-size.gif', ImageErrorMalformed);
  Image := nil;
  try
    Check(TryLoadImage(FixtureBytes('bad-gif-garbage.gif'), Image, Reason) or (Reason <> ImageErrorNone),
      'damaged LZW data gives a picture or a reason');
  except
    on Error: Exception do
      Check(False, 'damaged LZW data (' + Error.ClassName + ')');
  end;
  Image.Free;
end;

procedure TestGif;
begin
  TestAnimation;
  TestStills;
  TestTruncated;
  TestWriting;
  TestMalformed;
end;

end.

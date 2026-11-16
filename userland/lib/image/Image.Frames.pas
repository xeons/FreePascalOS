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
  Animation: a TAnimatedImage is an image (its pixels are the first
  frame as it is seen, so whoever wants a still picture just uses it as
  a TImage) with frames as the file has them and how often to play
  them.

  A frame (TImageFrame) is a picture of its own, usually smaller than
  the canvas, drawn at an offset (Left, Top) for Delay milliseconds.
  Blend says whether it replaces what is under it or is drawn over it by
  its alpha; Disposal what becomes of its area before the next frame:
  left as it is, cleared to transparent, or put back as it was before
  the frame was drawn. These are GIF's and APNG's rules alike;
  Image.Compositing turns frames into whole canvases.

  LoopCount is how many times the animation plays: 0 for ever.
}
unit Image.Frames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  fgl,
  Drawing.Colors,
  Image.Model;

type
  TFrameDisposal = (
    FrameDisposalNone,        { left as it is }
    FrameDisposalBackground,  { its area cleared to transparent }
    FrameDisposalPrevious     { the canvas put back as before the frame }
  );

  TFrameBlend = (
    FrameBlendSource,  { the frame's pixels replace the canvas's }
    FrameBlendOver     { the frame is drawn over the canvas by its alpha }
  );

  TImageFrame = class
  private
    FImage: TImage;
  public
    Left: LongInt;
    Top: LongInt;
    { Milliseconds the frame is shown. }
    Delay: LongInt;
    Disposal: TFrameDisposal;
    Blend: TFrameBlend;
    { The frame takes Image as its own. }
    constructor Create(Image: TImage);
    destructor Destroy; override;
    property Image: TImage read FImage;
  end;

  TImageFrameList = specialize TFPGObjectList<TImageFrame>;

  TAnimatedImage = class(TImage)
  private
    FFrames: TImageFrameList;
    function GetFrameCount: LongInt;
    function GetFrame(Index: LongInt): TImageFrame;
  public
    { A canvas Width x Height, transparent, with no frames yet. }
    constructor Create(CanvasWidth, CanvasHeight: LongInt);
    destructor Destroy; override;
    { Adds a frame (the animation takes it as its own). }
    procedure AddFrame(Frame: TImageFrame);
    { The total of the frames' delays, in milliseconds. }
    function TotalDuration: Int64;
    property FrameCount: LongInt read GetFrameCount;
    property Frames[Index: LongInt]: TImageFrame read GetFrame;
  public
    LoopCount: LongInt;
    { The colour the file says is behind the picture (informational:
      disposal clears to transparent). }
    BackgroundColor: TColor;
  end;

implementation

constructor TImageFrame.Create(Image: TImage);
begin
  inherited Create;
  FImage := Image;
  Blend := FrameBlendOver;
  Disposal := FrameDisposalNone;
end;

destructor TImageFrame.Destroy;
begin
  FImage.Free;
  inherited Destroy;
end;

constructor TAnimatedImage.Create(CanvasWidth, CanvasHeight: LongInt);
begin
  FFrames := TImageFrameList.Create(True);
  inherited Create(CanvasWidth, CanvasHeight);
end;

destructor TAnimatedImage.Destroy;
begin
  FFrames.Free;
  inherited Destroy;
end;

procedure TAnimatedImage.AddFrame(Frame: TImageFrame);
begin
  FFrames.Add(Frame);
end;

function TAnimatedImage.TotalDuration: Int64;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to FFrames.Count - 1 do
    Result := Result + FFrames[Index].Delay;
end;

function TAnimatedImage.GetFrameCount: LongInt;
begin
  Result := FFrames.Count;
end;

function TAnimatedImage.GetFrame(Index: LongInt): TImageFrame;
begin
  Result := FFrames[Index];
end;

end.

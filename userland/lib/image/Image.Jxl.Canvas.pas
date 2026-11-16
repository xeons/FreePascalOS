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
  Laying a JPEG XL frame onto the image's canvas (ISO/IEC 18181-1
  annex F.4): the canvas starts as the reference frame the frame's
  blending names (each extra channel may name its own; an empty slot
  is zeros), and the frame, at its offset and cropped to the image, is
  blended over it. The result is what the frame shows and what may be
  saved for later frames.
}
unit Image.Jxl.Canvas;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.Headers,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.Blending,
  Image.Jxl.FrameDecoder;

{ The canvas (Width x Height, every channel) after Frame (a regular or
  skip-progressive frame, colour transformed). }
function BlendJxlFrameOntoCanvas(const Frame: TJxlDecodedFrame; const Context: TJxlDecodingContext;
  Width, Height: LongInt; const ExtraChannels: array of TJxlExtraChannelInfo): TJxlPlaneSet;

implementation

function StartingPlane(const Context: TJxlDecodingContext; Source: LongWord; Channel, Width, Height: LongInt): TJxlPlane;
var
  Reference: TJxlPlaneSet;
begin
  Reference := Context.References[Source and 3];
  if Length(Reference) = 0 then
    Exit(TJxlPlane.Create(Width, Height));
  if Context.ReferenceBeforeColorTransform[Source and 3] then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL: blending onto a frame saved before its colour transform');
  if (Channel >= Length(Reference)) or (Reference[Channel].Width < Width) or (Reference[Channel].Height < Height) then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL: blending onto a cropped frame');
  if (Reference[Channel].Width = Width) and (Reference[Channel].Height = Height) then
    Exit(Reference[Channel].Clone);
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: blending onto a frame of another size');
  Result := nil;
end;

function BlendJxlFrameOntoCanvas(const Frame: TJxlDecodedFrame; const Context: TJxlDecodingContext;
  Width, Height: LongInt; const ExtraChannels: array of TJxlExtraChannelInfo): TJxlPlaneSet;
var
  Header: TJxlFrameHeader;
  ChannelCount: LongInt;
  Channel: LongInt;
  Source: LongWord;
  ColorBlending: TJxlPatchBlending;
  ExtraBlendings: TJxlPatchBlendings;
  Index: LongInt;
  Left: LongInt;
  Right: LongInt;
  Y: LongInt;
  CanvasY: LongInt;
  Background: TJxlRowPointers;
  Foreground: TJxlRowPointers;
begin
  Header := Frame.Header;
  ChannelCount := Length(Frame.Planes);
  SetLength(Result, ChannelCount);
  try
    for Channel := 0 to ChannelCount - 1 do
    begin
      if Channel < 3 then
        Source := Header.Blending.Source
      else
        Source := Header.ExtraChannelBlending[Channel - 3].Source;
      Result[Channel] := StartingPlane(Context, Source, Channel, Width, Height);
    end;
    ColorBlending := Default(TJxlPatchBlending);
    ColorBlending.Mode := JxlFrameBlendToPatchMode(Header.Blending.Mode);
    ColorBlending.AlphaChannel := Header.Blending.AlphaChannel;
    ColorBlending.Clamp := Header.Blending.Clamp;
    SetLength(ExtraBlendings, ChannelCount - 3);
    for Index := 0 to ChannelCount - 4 do
    begin
      ExtraBlendings[Index].Mode := JxlFrameBlendToPatchMode(Header.ExtraChannelBlending[Index].Mode);
      ExtraBlendings[Index].AlphaChannel := Header.ExtraChannelBlending[Index].AlphaChannel;
      ExtraBlendings[Index].Clamp := Header.ExtraChannelBlending[Index].Clamp;
    end;
    Left := Header.X0;
    if Left < 0 then
      Left := 0;
    Right := Header.X0 + Frame.Planes[0].Width;
    if Right > Width then
      Right := Width;
    if Right <= Left then
      Exit;
    SetLength(Background, ChannelCount);
    SetLength(Foreground, ChannelCount);
    for Y := 0 to Frame.Planes[0].Height - 1 do
    begin
      CanvasY := Header.Y0 + Y;
      if (CanvasY < 0) or (CanvasY >= Height) then
        Continue;
      for Channel := 0 to ChannelCount - 1 do
      begin
        if (Frame.Planes[Channel].Width <> Frame.Planes[0].Width) or
          (Frame.Planes[Channel].Height <> Frame.Planes[0].Height) then
          RaiseImageError(ImageErrorMalformed, 'JPEG XL: channels of different sizes');
        Background[Channel] := Result[Channel].Row(CanvasY) + Left;
        Foreground[Channel] := Frame.Planes[Channel].Row(Y) + (Left - Header.X0);
      end;
      JxlPerformBlending(Background, Foreground, Background, Right - Left, ColorBlending, ExtraBlendings,
        ExtraChannels);
    end;
  except
    FreeJxlPlanes(Result);
    raise;
  end;
end;

end.

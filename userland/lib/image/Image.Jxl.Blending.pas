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
  JPEG XL's blending (ISO/IEC 18181-1 annex F.4 and K.3): how a frame
  is laid over the frame below it, and how a patch is laid over the
  frame it is in. Colour (three channels) and each extra channel have
  a mode of their own: replace, add, multiply, alpha blending ("over",
  with the new layer above or below, with straight or premultiplied
  alpha), alpha weighted add, or nothing. A frame's blend modes map to
  the patch modes with the new frame above.

  The arithmetic is libjxl's (PerformBlending and its helpers).
}
unit Image.Jxl.Blending;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.Headers;

const
  JxlPatchBlendNone = 0;
  JxlPatchBlendReplace = 1;
  JxlPatchBlendAdd = 2;
  JxlPatchBlendMultiply = 3;
  JxlPatchBlendAbove = 4;
  JxlPatchBlendBelow = 5;
  JxlPatchBlendAlphaWeightedAddAbove = 6;
  JxlPatchBlendAlphaWeightedAddBelow = 7;
  JxlPatchBlendModeCount = 8;

type
  TJxlPatchBlending = record
    Mode: LongWord;
    AlphaChannel: LongWord;
    Clamp: Boolean;
  end;

  TJxlPatchBlendings = array of TJxlPatchBlending;

  { One pointer per channel: three colour channels, then the extra
    channels. }
  TJxlRowPointers = array of PSingle;

{ Blends Count samples: Output := Foreground over Background (Output
  may be either). }
procedure JxlPerformBlending(const Background, Foreground, Output: TJxlRowPointers; Count: LongInt;
  const ColorBlending: TJxlPatchBlending; const ExtraBlending: TJxlPatchBlendings;
  const ExtraChannels: array of TJxlExtraChannelInfo);
{ The patch mode of a frame blend mode (JxlBlend...). }
function JxlFrameBlendToPatchMode(Mode: LongWord): LongWord;

implementation

uses
  Image.Jxl.FrameHeader;

function JxlFrameBlendToPatchMode(Mode: LongWord): LongWord;
begin
  case Mode of
    JxlBlendAdd: Result := JxlPatchBlendAdd;
    JxlBlendMultiply: Result := JxlPatchBlendMultiply;
    JxlBlendBlend: Result := JxlPatchBlendAbove;
    JxlBlendAlphaWeightedAdd: Result := JxlPatchBlendAlphaWeightedAddAbove;
  else
    Result := JxlPatchBlendReplace;
  end;
end;

function ClampUnit(Value: Single): Single; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 1 then
    Result := 1
  else
    Result := Value;
end;

{ Over: one channel (or the alpha channel itself when Value and Alpha
  are the same). }
procedure AlphaBlendChannel(Background, BackgroundAlpha, Foreground, ForegroundAlpha, Output: PSingle;
  Count: LongInt; Premultiplied, Clamp: Boolean);
var
  X: LongInt;
  Alpha: Single;
  NewAlpha: Single;
  Reciprocal: Single;
begin
  if (Background = BackgroundAlpha) and (Foreground = ForegroundAlpha) then
  begin
    for X := 0 to Count - 1 do
    begin
      Alpha := ForegroundAlpha[X];
      if Clamp then
        Alpha := ClampUnit(Alpha);
      Output[X] := 1 - (1 - Alpha) * (1 - BackgroundAlpha[X]);
    end;
    Exit;
  end;
  for X := 0 to Count - 1 do
  begin
    Alpha := ForegroundAlpha[X];
    if Clamp then
      Alpha := ClampUnit(Alpha);
    if Premultiplied then
      Output[X] := Foreground[X] + Background[X] * (1 - Alpha)
    else
    begin
      NewAlpha := 1 - (1 - Alpha) * (1 - BackgroundAlpha[X]);
      if NewAlpha > 0 then
        Reciprocal := 1 / NewAlpha
      else
        Reciprocal := 0;
      Output[X] := (Foreground[X] * Alpha + Background[X] * BackgroundAlpha[X] * (1 - Alpha)) * Reciprocal;
    end;
  end;
end;

procedure AlphaWeightedAdd(Background, Foreground, ForegroundAlpha, Output: PSingle; Count: LongInt; Clamp: Boolean);
var
  X: LongInt;
begin
  if Foreground = ForegroundAlpha then
  begin
    for X := 0 to Count - 1 do
      Output[X] := Background[X];
    Exit;
  end;
  for X := 0 to Count - 1 do
    if Clamp then
      Output[X] := Background[X] + Foreground[X] * ClampUnit(ForegroundAlpha[X])
    else
      Output[X] := Background[X] + Foreground[X] * ForegroundAlpha[X];
end;

procedure MultiplyChannel(Background, Foreground, Output: PSingle; Count: LongInt; Clamp: Boolean);
var
  X: LongInt;
begin
  for X := 0 to Count - 1 do
    if Clamp then
      Output[X] := Background[X] * ClampUnit(Foreground[X])
    else
      Output[X] := Background[X] * Foreground[X];
end;

procedure CopyChannel(Source, Output: PSingle; Count: LongInt);
begin
  if Count > 0 then
    Move(Source^, Output^, SizeOf(Single) * Count);
end;

procedure JxlPerformBlending(const Background, Foreground, Output: TJxlRowPointers; Count: LongInt;
  const ColorBlending: TJxlPatchBlending; const ExtraBlending: TJxlPatchBlendings;
  const ExtraChannels: array of TJxlExtraChannelInfo);
var
  ExtraCount: LongInt;
  Temporary: array of array of Single;
  Rows: TJxlRowPointers;
  Channel: LongInt;
  Index: LongInt;
  Alpha: LongInt;
  HasAlpha: Boolean;
  Premultiplied: Boolean;
  Blending: TJxlPatchBlending;
  X: LongInt;
  Bottom: TJxlRowPointers;
  Top: TJxlRowPointers;
begin
  if Count <= 0 then
    Exit;
  ExtraCount := Length(ExtraChannels);
  HasAlpha := False;
  for Index := 0 to ExtraCount - 1 do
    if ExtraChannels[Index].ChannelType = JxlExtraChannelAlpha then
      HasAlpha := True;
  SetLength(Temporary, 3 + ExtraCount, Count);
  SetLength(Rows, 3 + ExtraCount);
  for Channel := 0 to 2 + ExtraCount do
    Rows[Channel] := @Temporary[Channel][0];
  for Index := 0 to ExtraCount - 1 do
  begin
    Channel := 3 + Index;
    Blending := ExtraBlending[Index];
    Alpha := 3 + LongInt(Blending.AlphaChannel);
    case Blending.Mode of
      JxlPatchBlendAdd:
        for X := 0 to Count - 1 do
          Rows[Channel][X] := Background[Channel][X] + Foreground[Channel][X];
      JxlPatchBlendAbove:
        AlphaBlendChannel(Background[Channel], Background[Alpha], Foreground[Channel], Foreground[Alpha],
          Rows[Channel], Count, ExtraChannels[Blending.AlphaChannel].AlphaAssociated, Blending.Clamp);
      JxlPatchBlendBelow:
        AlphaBlendChannel(Foreground[Channel], Foreground[Alpha], Background[Channel], Background[Alpha],
          Rows[Channel], Count, ExtraChannels[Blending.AlphaChannel].AlphaAssociated, Blending.Clamp);
      JxlPatchBlendAlphaWeightedAddAbove:
        AlphaWeightedAdd(Background[Channel], Foreground[Channel], Foreground[Alpha], Rows[Channel], Count,
          Blending.Clamp);
      JxlPatchBlendAlphaWeightedAddBelow:
        AlphaWeightedAdd(Foreground[Channel], Background[Channel], Background[Alpha], Rows[Channel], Count,
          Blending.Clamp);
      JxlPatchBlendMultiply:
        MultiplyChannel(Background[Channel], Foreground[Channel], Rows[Channel], Count, Blending.Clamp);
      JxlPatchBlendReplace:
        CopyChannel(Foreground[Channel], Rows[Channel], Count);
    else
      CopyChannel(Background[Channel], Rows[Channel], Count);
    end;
  end;
  Alpha := 3 + LongInt(ColorBlending.AlphaChannel);
  case ColorBlending.Mode of
    JxlPatchBlendAdd:
      for Channel := 0 to 2 do
        for X := 0 to Count - 1 do
          Rows[Channel][X] := Background[Channel][X] + Foreground[Channel][X];
    JxlPatchBlendAlphaWeightedAddAbove, JxlPatchBlendAlphaWeightedAddBelow:
      for Channel := 0 to 2 do
        if not HasAlpha then
          for X := 0 to Count - 1 do
            Rows[Channel][X] := Background[Channel][X] + Foreground[Channel][X]
        else if ColorBlending.Mode = JxlPatchBlendAlphaWeightedAddAbove then
          AlphaWeightedAdd(Background[Channel], Foreground[Channel], Foreground[Alpha], Rows[Channel], Count,
            ColorBlending.Clamp)
        else
          AlphaWeightedAdd(Foreground[Channel], Background[Channel], Background[Alpha], Rows[Channel], Count,
            ColorBlending.Clamp);
    JxlPatchBlendAbove, JxlPatchBlendBelow:
      if not HasAlpha then
        for Channel := 0 to 2 do
          CopyChannel(Foreground[Channel], Rows[Channel], Count)
      else
      begin
        if ColorBlending.Mode = JxlPatchBlendAbove then
        begin
          Bottom := Background;
          Top := Foreground;
        end
        else
        begin
          Bottom := Foreground;
          Top := Background;
        end;
        Premultiplied := ExtraChannels[ColorBlending.AlphaChannel].AlphaAssociated;
        for Channel := 0 to 2 do
          AlphaBlendChannel(Bottom[Channel], Bottom[Alpha], Top[Channel], Top[Alpha], Rows[Channel], Count,
            Premultiplied, ColorBlending.Clamp);
        AlphaBlendChannel(Bottom[Alpha], Bottom[Alpha], Top[Alpha], Top[Alpha], Rows[Alpha], Count,
          Premultiplied, ColorBlending.Clamp);
      end;
    JxlPatchBlendMultiply:
      for Channel := 0 to 2 do
        MultiplyChannel(Background[Channel], Foreground[Channel], Rows[Channel], Count, ColorBlending.Clamp);
    JxlPatchBlendReplace:
      for Channel := 0 to 2 do
        CopyChannel(Foreground[Channel], Rows[Channel], Count);
  else
    for Channel := 0 to 2 do
      CopyChannel(Background[Channel], Rows[Channel], Count);
  end;
  for Channel := 0 to 2 + ExtraCount do
    CopyChannel(Rows[Channel], Output[Channel], Count);
end;

end.

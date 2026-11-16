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
  JPEG XL's squeeze transform (ISO/IEC 18181-1 annex I.3.4): a
  channel is halved, horizontally or vertically, into averages and
  residuals (stored in a channel of their own, after the squeezed ones
  or at the end of the list); the residuals are relative to a "smooth
  tendency" of the averages. Repeated squeezes make a pyramid that is
  decoded coarse first. With no parameters given the default sequence
  squeezes chroma first (as 4:2:0 would) and then everything down to
  8 x 8.
}
unit Image.Jxl.Modular.Squeeze;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Modular.Channels;

type
  TJxlSqueezeParameters = record
    Horizontal: Boolean;
    InPlace: Boolean;
    BeginChannel: LongWord;
    ChannelCount: LongWord;
  end;

  TJxlSqueezeList = array of TJxlSqueezeParameters;

function ReadJxlSqueezeParameters(Reader: TJxlBitReader): TJxlSqueezeParameters;
{ Changes the channel list as the squeezes do (filling in the default
  squeezes when there are none). }
procedure ApplyJxlSqueezeToChannels(Image: TJxlModularImage; var Squeezes: TJxlSqueezeList);
{ Undoes the squeezes. }
procedure InvertJxlSqueeze(Image: TJxlModularImage; const Squeezes: TJxlSqueezeList);

implementation

const
  MaximumFirstPreviewSize = 8;

procedure RaiseBadSqueeze(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL squeeze: ' + Detail);
end;

function ReadJxlSqueezeParameters(Reader: TJxlBitReader): TJxlSqueezeParameters;
begin
  Result.Horizontal := Reader.ReadBool;
  Result.InPlace := Reader.ReadBool;
  Result.BeginChannel := Reader.ReadU32(JxlBits(3), JxlBitsOffset(6, 8), JxlBitsOffset(10, 72),
    JxlBitsOffset(13, 1096));
  Result.ChannelCount := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(3), JxlBitsOffset(4, 4));
end;

procedure AddSqueeze(var Squeezes: TJxlSqueezeList; const Parameters: TJxlSqueezeParameters);
begin
  SetLength(Squeezes, Length(Squeezes) + 1);
  Squeezes[High(Squeezes)] := Parameters;
end;

procedure DefaultSqueezes(Image: TJxlModularImage; var Squeezes: TJxlSqueezeList);
var
  ChannelCount: LongInt;
  Width: Int64;
  Height: Int64;
  Wide: Boolean;
  Parameters: TJxlSqueezeParameters;
  First: LongInt;
begin
  Squeezes := nil;
  First := Image.MetaChannelCount;
  ChannelCount := Image.ChannelCount - First;
  if ChannelCount <= 0 then
    RaiseBadSqueeze('no channels');
  Width := Image[First].Width;
  Height := Image[First].Height;
  Wide := Width > Height;
  if (ChannelCount > 2) and (Image[First + 1].Width = Width) and (Image[First + 1].Height = Height) then
  begin
    Parameters.Horizontal := True;
    Parameters.InPlace := False;
    Parameters.BeginChannel := First + 1;
    Parameters.ChannelCount := 2;
    AddSqueeze(Squeezes, Parameters);
    Parameters.Horizontal := False;
    AddSqueeze(Squeezes, Parameters);
  end;
  Parameters.BeginChannel := First;
  Parameters.ChannelCount := ChannelCount;
  Parameters.InPlace := True;
  if (not Wide) and (Height > MaximumFirstPreviewSize) then
  begin
    Parameters.Horizontal := False;
    AddSqueeze(Squeezes, Parameters);
    Height := (Height + 1) div 2;
  end;
  while (Width > MaximumFirstPreviewSize) or (Height > MaximumFirstPreviewSize) do
  begin
    if Width > MaximumFirstPreviewSize then
    begin
      Parameters.Horizontal := True;
      AddSqueeze(Squeezes, Parameters);
      Width := (Width + 1) div 2;
    end;
    if Height > MaximumFirstPreviewSize then
    begin
      Parameters.Horizontal := False;
      AddSqueeze(Squeezes, Parameters);
      Height := (Height + 1) div 2;
    end;
  end;
end;

procedure CheckSqueezeParameters(const Parameters: TJxlSqueezeParameters; ChannelCount: LongInt);
begin
  if (Parameters.ChannelCount = 0) or (QWord(Parameters.BeginChannel) + Parameters.ChannelCount > QWord(ChannelCount))
  then
    RaiseBadSqueeze('bad channel range');
end;

procedure ApplyJxlSqueezeToChannels(Image: TJxlModularImage; var Squeezes: TJxlSqueezeList);
var
  Index: LongInt;
  Parameters: TJxlSqueezeParameters;
  BeginChannel: LongInt;
  EndChannel: LongInt;
  Offset: LongInt;
  Channel: LongInt;
  Width: LongInt;
  Height: LongInt;
  Squeezed: TJxlChannel;
  Placeholder: TJxlChannel;
begin
  if Length(Squeezes) = 0 then
    DefaultSqueezes(Image, Squeezes);
  for Index := 0 to High(Squeezes) do
  begin
    Parameters := Squeezes[Index];
    CheckSqueezeParameters(Parameters, Image.ChannelCount);
    BeginChannel := Parameters.BeginChannel;
    EndChannel := BeginChannel + LongInt(Parameters.ChannelCount) - 1;
    if BeginChannel < Image.MetaChannelCount then
    begin
      if EndChannel >= Image.MetaChannelCount then
        RaiseBadSqueeze('meta and other channels mixed');
      if not Parameters.InPlace then
        RaiseBadSqueeze('meta channels squeezed out of place');
      Inc(Image.MetaChannelCount, Parameters.ChannelCount);
    end;
    if Parameters.InPlace then
      Offset := EndChannel + 1
    else
      Offset := Image.ChannelCount;
    for Channel := BeginChannel to EndChannel do
    begin
      Squeezed := Image[Channel];
      if (Squeezed.HorizontalShift > 30) or (Squeezed.VerticalShift > 30) then
        RaiseBadSqueeze('too many squeezes');
      Width := Squeezed.Width;
      Height := Squeezed.Height;
      if (Width = 0) or (Height = 0) then
        RaiseBadSqueeze('empty channel');
      if Parameters.Horizontal then
      begin
        Squeezed.Resize((Width + 1) div 2, Height);
        if Squeezed.HorizontalShift >= 0 then
          Inc(Squeezed.HorizontalShift);
        Width := Width - (Width + 1) div 2;
      end
      else
      begin
        Squeezed.Resize(Width, (Height + 1) div 2);
        if Squeezed.VerticalShift >= 0 then
          Inc(Squeezed.VerticalShift);
        Height := Height - (Height + 1) div 2;
      end;
      Placeholder := TJxlChannel.Create(Width, Height, Squeezed.HorizontalShift, Squeezed.VerticalShift);
      Image.InsertChannel(Offset + (Channel - BeginChannel), Placeholder);
    end;
  end;
end;

function SmoothTendency(B, A, N: Int64): Int64; inline;
begin
  Result := 0;
  if (B >= A) and (A >= N) then
  begin
    Result := (4 * B - 3 * N - A + 6) div 12;
    if Result - (Result and 1) > 2 * (B - A) then
      Result := 2 * (B - A) + 1;
    if Result + (Result and 1) > 2 * (A - N) then
      Result := 2 * (A - N);
  end
  else if (B <= A) and (A <= N) then
  begin
    Result := (4 * B - 3 * N - A - 6) div 12;
    if Result + (Result and 1) < 2 * (B - A) then
      Result := 2 * (B - A) - 1;
    if Result - (Result and 1) < 2 * (A - N) then
      Result := 2 * (A - N);
  end;
end;

procedure InvertHorizontal(Image: TJxlModularImage; ChannelIndex, ResidualIndex: LongInt);
var
  Averages: TJxlChannel;
  Residuals: TJxlChannel;
  Output: TJxlChannel;
  Y: LongInt;
  X: LongInt;
  AverageLine: PLongInt;
  ResidualLine: PLongInt;
  OutputLine: PLongInt;
  Average: Int64;
  NextAverage: Int64;
  Left: Int64;
  Difference: Int64;
  First: Int64;
begin
  Averages := Image[ChannelIndex];
  Residuals := Image[ResidualIndex];
  if (Averages.Width <> (Averages.Width + Residuals.Width + 1) div 2) or (Averages.Height <> Residuals.Height) then
    RaiseBadSqueeze('bad residual size');
  if Residuals.Width = 0 then
  begin
    Dec(Averages.HorizontalShift);
    Exit;
  end;
  Output := TJxlChannel.Create(Averages.Width + Residuals.Width, Averages.Height, Averages.HorizontalShift - 1,
    Averages.VerticalShift);
  try
    for Y := 0 to Averages.Height - 1 do
    begin
      AverageLine := Averages.Row(Y);
      ResidualLine := Residuals.Row(Y);
      OutputLine := Output.Row(Y);
      for X := 0 to Residuals.Width - 1 do
      begin
        Average := AverageLine[X];
        if X + 1 < Averages.Width then
          NextAverage := AverageLine[X + 1]
        else
          NextAverage := Average;
        if X > 0 then
          Left := OutputLine[2 * X - 1]
        else
          Left := Average;
        Difference := ResidualLine[X] + SmoothTendency(Left, Average, NextAverage);
        First := Average + Difference div 2;
        OutputLine[2 * X] := LongInt(First);
        OutputLine[2 * X + 1] := LongInt(First - Difference);
      end;
      if (Output.Width and 1) <> 0 then
        OutputLine[Output.Width - 1] := AverageLine[Averages.Width - 1];
    end;
  except
    Output.Free;
    raise;
  end;
  Image.ReplaceChannel(ChannelIndex, Output);
end;

procedure InvertVertical(Image: TJxlModularImage; ChannelIndex, ResidualIndex: LongInt);
var
  Averages: TJxlChannel;
  Residuals: TJxlChannel;
  Output: TJxlChannel;
  Y: LongInt;
  X: LongInt;
  AverageLine: PLongInt;
  NextAverageLine: PLongInt;
  ResidualLine: PLongInt;
  OutputLine: PLongInt;
  NextOutputLine: PLongInt;
  PreviousOutputLine: PLongInt;
  Average: Int64;
  Difference: Int64;
  First: Int64;
begin
  Averages := Image[ChannelIndex];
  Residuals := Image[ResidualIndex];
  if (Averages.Height <> (Averages.Height + Residuals.Height + 1) div 2) or (Averages.Width <> Residuals.Width) then
    RaiseBadSqueeze('bad residual size');
  if Residuals.Height = 0 then
  begin
    Dec(Averages.VerticalShift);
    Exit;
  end;
  Output := TJxlChannel.Create(Averages.Width, Averages.Height + Residuals.Height, Averages.HorizontalShift,
    Averages.VerticalShift - 1);
  try
    if Residuals.Width > 0 then
      for Y := 0 to Residuals.Height - 1 do
      begin
        ResidualLine := Residuals.Row(Y);
        AverageLine := Averages.Row(Y);
        if Y + 1 < Averages.Height then
          NextAverageLine := Averages.Row(Y + 1)
        else
          NextAverageLine := AverageLine;
        OutputLine := Output.Row(2 * Y);
        NextOutputLine := Output.Row(2 * Y + 1);
        if Y > 0 then
          PreviousOutputLine := Output.Row(2 * Y - 1)
        else
          PreviousOutputLine := AverageLine;
        for X := 0 to Averages.Width - 1 do
        begin
          Average := AverageLine[X];
          Difference := ResidualLine[X] + SmoothTendency(PreviousOutputLine[X], Average, NextAverageLine[X]);
          First := Average + Difference div 2;
          OutputLine[X] := LongInt(First);
          NextOutputLine[X] := LongInt(First - Difference);
        end;
      end;
    if (Residuals.Width > 0) and ((Output.Height and 1) <> 0) then
      Move(Averages.Row(Averages.Height - 1)^, Output.Row(Output.Height - 1)^, SizeOf(LongInt) * Averages.Width);
  except
    Output.Free;
    raise;
  end;
  Image.ReplaceChannel(ChannelIndex, Output);
end;

procedure InvertJxlSqueeze(Image: TJxlModularImage; const Squeezes: TJxlSqueezeList);
var
  Index: LongInt;
  Parameters: TJxlSqueezeParameters;
  BeginChannel: LongInt;
  EndChannel: LongInt;
  Offset: LongInt;
  Channel: LongInt;
  ResidualChannel: LongInt;
begin
  for Index := High(Squeezes) downto 0 do
  begin
    Parameters := Squeezes[Index];
    CheckSqueezeParameters(Parameters, Image.ChannelCount);
    BeginChannel := Parameters.BeginChannel;
    EndChannel := BeginChannel + LongInt(Parameters.ChannelCount) - 1;
    if Parameters.InPlace then
      Offset := EndChannel + 1
    else
      Offset := Image.ChannelCount + BeginChannel - EndChannel - 1;
    if BeginChannel < Image.MetaChannelCount then
    begin
      if Image.MetaChannelCount <= LongInt(Parameters.ChannelCount) then
        RaiseBadSqueeze('bad meta channels');
      Dec(Image.MetaChannelCount, Parameters.ChannelCount);
    end;
    for Channel := BeginChannel to EndChannel do
    begin
      ResidualChannel := Offset + Channel - BeginChannel;
      if (ResidualChannel >= Image.ChannelCount) or (Offset < 0) then
        RaiseBadSqueeze('bad channel range');
      if (Image[Channel].Width < Image[ResidualChannel].Width) or
        (Image[Channel].Height < Image[ResidualChannel].Height) then
        RaiseBadSqueeze('corrupted');
      if Parameters.Horizontal then
        InvertHorizontal(Image, Channel, ResidualChannel)
      else
        InvertVertical(Image, Channel, ResidualChannel);
    end;
    Image.DeleteChannels(Offset, EndChannel - BeginChannel + 1);
  end;
end;

end.

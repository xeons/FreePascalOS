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
  A JPEG XL modular image: a list of integer channels, each with its
  own size and its shifts (how many times it was halved horizontally
  and vertically against the image; -1 for a meta channel such as a
  palette, which is not a picture). The first MetaChannelCount
  channels are meta channels. Transforms (Image.Jxl.Modular.Transforms)
  change the list as it is read and back when they are undone.
}
unit Image.Jxl.Modular.Channels;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  fgl,
  Image.Errors;

type
  TJxlChannel = class
  public
    Width: LongInt;
    Height: LongInt;
    HorizontalShift: LongInt;
    VerticalShift: LongInt;
    Pixels: array of LongInt;
    { A Width x Height channel of zeros. }
    constructor Create(ChannelWidth, ChannelHeight: LongInt; HShift: LongInt = 0; VShift: LongInt = 0);
    { The first sample of line Y. }
    function Row(Y: LongInt): PLongInt; inline;
    { Gives the channel a new size (its samples are lost). }
    procedure Resize(NewWidth, NewHeight: LongInt);
    function Clone: TJxlChannel;
  end;

  TJxlChannelList = specialize TFPGObjectList<TJxlChannel>;

  TJxlModularImage = class
  private
    FChannels: TJxlChannelList;
    function GetChannel(Index: LongInt): TJxlChannel;
    function GetChannelCount: LongInt;
  public
    MetaChannelCount: LongInt;
    BitDepth: LongInt;
    constructor Create;
    destructor Destroy; override;
    procedure AddChannel(Channel: TJxlChannel);
    procedure InsertChannel(Index: LongInt; Channel: TJxlChannel);
    procedure DeleteChannels(Index, Count: LongInt);
    { Replaces channel Index (freeing the old one). }
    procedure ReplaceChannel(Index: LongInt; Channel: TJxlChannel);
    { Swaps the channel objects at two positions. }
    procedure ExchangeChannels(First, Second: LongInt);
    property Channels[Index: LongInt]: TJxlChannel read GetChannel; default;
    property ChannelCount: LongInt read GetChannelCount;
  end;

{ Raises ImageErrorTooLarge for a channel that cannot be allocated. }
procedure CheckJxlChannelSize(Width, Height: Int64);

implementation

const
  MaximumChannelSamples = Int64(256) * 1024 * 1024;

procedure CheckJxlChannelSize(Width, Height: Int64);
begin
  if (Width < 0) or (Height < 0) or (Width * Height > MaximumChannelSamples) then
    RaiseImageError(ImageErrorTooLarge, 'JPEG XL channel ' + IntToStr(Width) + ' x ' + IntToStr(Height));
end;

constructor TJxlChannel.Create(ChannelWidth, ChannelHeight: LongInt; HShift: LongInt; VShift: LongInt);
begin
  inherited Create;
  HorizontalShift := HShift;
  VerticalShift := VShift;
  Resize(ChannelWidth, ChannelHeight);
end;

function TJxlChannel.Row(Y: LongInt): PLongInt;
begin
  Result := PLongInt(@Pixels[0]) + PtrInt(Y) * Width;
end;

procedure TJxlChannel.Resize(NewWidth, NewHeight: LongInt);
begin
  CheckJxlChannelSize(NewWidth, NewHeight);
  Width := NewWidth;
  Height := NewHeight;
  Pixels := nil;
  SetLength(Pixels, Int64(NewWidth) * NewHeight + 1);
end;

function TJxlChannel.Clone: TJxlChannel;
begin
  Result := TJxlChannel.Create(0, 0, HorizontalShift, VerticalShift);
  Result.Width := Width;
  Result.Height := Height;
  Result.Pixels := Copy(Pixels);
end;

constructor TJxlModularImage.Create;
begin
  inherited Create;
  FChannels := TJxlChannelList.Create(True);
end;

destructor TJxlModularImage.Destroy;
begin
  FChannels.Free;
  inherited Destroy;
end;

function TJxlModularImage.GetChannel(Index: LongInt): TJxlChannel;
begin
  Result := FChannels[Index];
end;

function TJxlModularImage.GetChannelCount: LongInt;
begin
  Result := FChannels.Count;
end;

procedure TJxlModularImage.AddChannel(Channel: TJxlChannel);
begin
  FChannels.Add(Channel);
end;

procedure TJxlModularImage.InsertChannel(Index: LongInt; Channel: TJxlChannel);
begin
  FChannels.Insert(Index, Channel);
end;

procedure TJxlModularImage.DeleteChannels(Index, Count: LongInt);
begin
  while Count > 0 do
  begin
    FChannels.Delete(Index);
    Dec(Count);
  end;
end;

procedure TJxlModularImage.ReplaceChannel(Index: LongInt; Channel: TJxlChannel);
begin
  FChannels[Index] := Channel;
end;

procedure TJxlModularImage.ExchangeChannels(First, Second: LongInt);
begin
  FChannels.Exchange(First, Second);
end;

end.

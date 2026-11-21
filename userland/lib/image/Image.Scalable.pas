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
  Scalable images: pictures described by shapes rather than pixels
  (SVG), which can be drawn again crisply at any size.

  A TScalableImage is a TImage whose own pixels are a rendering at its
  natural size, so everything that takes images (codecs' callers,
  picture boxes, the web engine) can show it as it is. Those who know
  about scaling ask for a rendering at the size they need
  (RenderedAt), which is made the first time and kept until another
  size is asked for (a few sizes are kept, the least recently used
  going first), so a page painted again at the same zoom draws the
  same pixels without rendering them again.

  The natural size may be missing (an SVG with only a viewBox has a
  ratio but no size, one with neither has nothing): the pixels are then
  a rendering at the size CSS's default sizing gives it (the ratio
  within 300 x 150, or 300 x 150).

  Subclasses implement Render, which may be called from any thread
  (renderings are made under a lock).
}
unit Image.Scalable;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model;

const
  DefaultObjectWidth = 300;
  DefaultObjectHeight = 150;
  ScalableCacheSize = 3;

type
  TScalableImage = class(TImage)
  private
    FLock: TRTLCriticalSection;
    FCache: array[0..ScalableCacheSize - 1] of TImage;
    FCacheUse: array[0..ScalableCacheSize - 1] of QWord;
    FUseCounter: QWord;
  protected
    FHasNaturalWidth: Boolean;
    FHasNaturalHeight: Boolean;
    FNaturalWidth: Double;
    FNaturalHeight: Double;
    { Width / height, 0 when there is none. }
    FNaturalRatio: Double;
    { The own pixels hold their rendering (a subclass that leaves them
      to be drawn when first asked for clears it and implements
      RenderBase). }
    FBaseRendered: Boolean;
    procedure RenderBase; virtual;
  public
    constructor Create(ImageWidth, ImageHeight: LongInt);
    destructor Destroy; override;
    { A new rendering at Width x Height pixels (the caller owns it). }
    function Render(RenderWidth, RenderHeight: LongInt): TImage; virtual; abstract;
    { A rendering at that size the image keeps (do not free it); the
      image's own pixels when the size is its own (drawn then if they
      were left for later). nil if the size is refused. }
    function RenderedAt(RenderWidth, RenderHeight: LongInt): TImage;
    { Forget the kept renderings (what the image draws changed). }
    procedure ClearRenderings;
    property HasNaturalWidth: Boolean read FHasNaturalWidth;
    property HasNaturalHeight: Boolean read FHasNaturalHeight;
    { CSS pixels; meaningful when the matching Has... is set. }
    property NaturalWidth: Double read FNaturalWidth;
    property NaturalHeight: Double read FNaturalHeight;
    property NaturalRatio: Double read FNaturalRatio;
  end;

{ The size CSS's default sizing algorithm gives an object with these
  natural dimensions (any of them missing) for a default object size of
  300 x 150. }
procedure DefaultConcreteSize(HasWidth, HasHeight: Boolean; Width, Height, Ratio: Double;
  out ConcreteWidth, ConcreteHeight: Double);

implementation

procedure DefaultConcreteSize(HasWidth, HasHeight: Boolean; Width, Height, Ratio: Double;
  out ConcreteWidth, ConcreteHeight: Double);
begin
  if HasWidth and HasHeight then
  begin
    ConcreteWidth := Width;
    ConcreteHeight := Height;
  end
  else if HasWidth then
  begin
    ConcreteWidth := Width;
    if Ratio > 0 then
      ConcreteHeight := Width / Ratio
    else
      ConcreteHeight := DefaultObjectHeight;
  end
  else if HasHeight then
  begin
    ConcreteHeight := Height;
    if Ratio > 0 then
      ConcreteWidth := Height * Ratio
    else
      ConcreteWidth := DefaultObjectWidth;
  end
  else if Ratio > 0 then
  begin
    { Contained within the default object size. }
    ConcreteWidth := DefaultObjectWidth;
    ConcreteHeight := DefaultObjectWidth / Ratio;
    if ConcreteHeight > DefaultObjectHeight then
    begin
      ConcreteHeight := DefaultObjectHeight;
      ConcreteWidth := DefaultObjectHeight * Ratio;
    end;
  end
  else
  begin
    ConcreteWidth := DefaultObjectWidth;
    ConcreteHeight := DefaultObjectHeight;
  end;
end;

constructor TScalableImage.Create(ImageWidth, ImageHeight: LongInt);
begin
  inherited Create(ImageWidth, ImageHeight);
  InitCriticalSection(FLock);
  FBaseRendered := True;
end;

procedure TScalableImage.RenderBase;
begin
end;

destructor TScalableImage.Destroy;
begin
  ClearRenderings;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TScalableImage.ClearRenderings;
var
  Index: LongInt;
begin
  EnterCriticalSection(FLock);
  try
    for Index := 0 to ScalableCacheSize - 1 do
      FreeAndNil(FCache[Index]);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TScalableImage.RenderedAt(RenderWidth, RenderHeight: LongInt): TImage;
var
  Index: LongInt;
  Oldest: LongInt;
begin
  Result := nil;
  if (RenderWidth = Width) and (RenderHeight = Height) then
  begin
    if not FBaseRendered then
    begin
      EnterCriticalSection(FLock);
      try
        if not FBaseRendered then
        begin
          FBaseRendered := True;
          RenderBase;
        end;
      finally
        LeaveCriticalSection(FLock);
      end;
    end;
    Exit(Self);
  end;
  if not ImageSizeAllowed(RenderWidth, RenderHeight) then
    Exit;
  EnterCriticalSection(FLock);
  try
    Inc(FUseCounter);
    for Index := 0 to ScalableCacheSize - 1 do
      if (FCache[Index] <> nil) and (FCache[Index].Width = RenderWidth) and (FCache[Index].Height = RenderHeight) then
      begin
        FCacheUse[Index] := FUseCounter;
        Exit(FCache[Index]);
      end;
    Oldest := 0;
    for Index := 0 to ScalableCacheSize - 1 do
    begin
      if FCache[Index] = nil then
      begin
        Oldest := Index;
        Break;
      end;
      if FCacheUse[Index] < FCacheUse[Oldest] then
        Oldest := Index;
    end;
    try
      Result := Render(RenderWidth, RenderHeight);
    except
      Result := nil;
    end;
    if Result = nil then
      Exit;
    FreeAndNil(FCache[Oldest]);
    FCache[Oldest] := Result;
    FCacheUse[Oldest] := FUseCounter;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.

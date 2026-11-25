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
  The browser's side of a content process's frames, apart from the
  control (so a host test can play the renderer): the surface the
  renderer paints into (a shared section, replaced with every new size),
  the view's own copy of the last frame, and the async scrolling that
  moves that copy while the renderer is busy. Nothing the renderer says
  is trusted: a frame of a surface that was replaced, a frame larger
  than its surface, damage outside it, a viewport or document of any
  size are refused or clipped, so a hostile or confused renderer can
  make the view show nonsense but never read or write outside a
  surface.
}
unit WebView.RemoteFrames;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces,
  Drawing.Rectangles,
  Drawing.Canvas,
  WebIpc.ViewMessages;

type
  TRemoteFrames = class
  private
    FSource: TSurface;
    FSourceOwner: TObject;
    FSourceId: LongWord;
    FFrame: TSurface;
    FHasFrame: Boolean;
    FInfo: TIpcFrameInfo;
    FScrollShift: Double;
    FShiftUntilInput: LongWord;
    function ShiftPixels: LongInt;
  public
    destructor Destroy; override;
    { A new surface from the renderer (Owner, which keeps Surface's
      pixels, is the frames' to free; nil Owner: no surface). }
    procedure TakeSurface(SurfaceId: LongWord; Owner: TObject; constref Surface: TSurface);
    { A frame presented: what changed copied into the view's own picture.
      False when it was not taken (not of the current surface, larger
      than it, no memory); the renderer is told either way. Damage is
      what to show again, in view pixels. }
    function TakeFrame(constref Info: TIpcFrameInfo; out Damage: TRectangle): Boolean;
    { The renderer handled input up to Sequence. }
    procedure InputHandled(Sequence: LongWord);
    { The last frame moved by Pixels (down the page for positive) while
      the renderer is busy, within the document as the last frame
      measured it; until the renderer handled InputSequence. True when
      it moved. }
    function Shift(Pixels: Double; InputSequence: LongWord): Boolean;
    { A new renderer: the old one's frame stays shown until it paints. }
    procedure Restart;
    { The last frame on Canvas, Width x Height view pixels, moved by the
      shift (the scroll bars stay), white where nothing is known. }
    procedure Paint(var Canvas: TCanvas; Width, Height: LongInt);
    property HasFrame: Boolean read FHasFrame;
    property Info: TIpcFrameInfo read FInfo;
    property ScrollShift: Double read FScrollShift;
    property SourceId: LongWord read FSourceId;
  end;

implementation

uses
  Math,
  Drawing.Colors;

const
  { Farther than any document goes (device pixels): a renderer's sizes
    are kept within it before they are used in arithmetic. }
  LargestDistance = 1.0e9;

function Bounded(Value: Double): Double;
begin
  if IsNan(Value) then
    Exit(0);
  Result := EnsureRange(Value, -LargestDistance, LargestDistance);
end;

destructor TRemoteFrames.Destroy;
begin
  FSourceOwner.Free;
  FreeSurface(FFrame);
  inherited Destroy;
end;

procedure TRemoteFrames.TakeSurface(SurfaceId: LongWord; Owner: TObject; constref Surface: TSurface);
begin
  FSourceOwner.Free;
  FSourceOwner := Owner;
  if Owner <> nil then
  begin
    FSource := Surface;
    FSourceId := SurfaceId;
  end
  else
  begin
    FSource := Default(TSurface);
    FSourceId := 0;
  end;
end;

function TRemoteFrames.TakeFrame(constref Info: TIpcFrameInfo; out Damage: TRectangle): Boolean;
var
  Canvas: TCanvas;
begin
  Damage := MakeRectangle(0, 0, 0, 0);
  if (FSourceOwner = nil) or (FSource.Pixels = nil) or (Info.SurfaceId <> FSourceId) or (Info.Width <= 0) or
     (Info.Height <= 0) or (Info.Width > FSource.Width) or (Info.Height > FSource.Height) then
    Exit(False);
  if (FFrame.Pixels = nil) or (FFrame.Width <> Info.Width) or (FFrame.Height <> Info.Height) then
  begin
    FreeSurface(FFrame);
    if not CreateSurface(FFrame, Info.Width, Info.Height, ColorWhite) then
    begin
      FFrame := Default(TSurface);
      FHasFrame := False;
      Exit(False);
    end;
    Damage := MakeRectangle(0, 0, Info.Width, Info.Height);
  end
  else
    Damage := MakeRectangle(Max(0, Info.DamageLeft), Max(0, Info.DamageTop),
      Min(Info.Width, Info.DamageRight) - Max(0, Info.DamageLeft),
      Min(Info.Height, Info.DamageBottom) - Max(0, Info.DamageTop));
  if (RectangleWidth(Damage) > 0) and (RectangleHeight(Damage) > 0) then
  begin
    BeginCanvas(Canvas, FFrame);
    DrawSurface(Canvas, FSource, Damage, Damage.Left, Damage.Top, False, 255);
  end
  else
    Damage := MakeRectangle(0, 0, 0, 0);
  FInfo := Info;
  FInfo.ScrollX := Bounded(Info.ScrollX);
  FInfo.ScrollY := Bounded(Info.ScrollY);
  FInfo.DocumentWidth := Bounded(Info.DocumentWidth);
  FInfo.DocumentHeight := Bounded(Info.DocumentHeight);
  FInfo.ViewportWidth := EnsureRange(Info.ViewportWidth, 0, Info.Width);
  FInfo.ViewportHeight := EnsureRange(Info.ViewportHeight, 0, Info.Height);
  FHasFrame := True;
  { The renderer caught up with the scrolling shown meanwhile. }
  if (FShiftUntilInput = 0) or (Info.InputHandled >= FShiftUntilInput) then
  begin
    if FScrollShift <> 0 then
      Damage := MakeRectangle(0, 0, Info.Width, Info.Height);
    FScrollShift := 0;
    FShiftUntilInput := 0;
  end;
  Result := True;
end;

procedure TRemoteFrames.InputHandled(Sequence: LongWord);
begin
  FInfo.InputHandled := Sequence;
  if Sequence >= FShiftUntilInput then
    FShiftUntilInput := 0;
end;

function TRemoteFrames.Shift(Pixels: Double; InputSequence: LongWord): Boolean;
var
  Lowest, Highest, Moved: Double;
begin
  Result := False;
  if not FHasFrame then
    Exit;
  Lowest := -FInfo.ScrollY;
  Highest := Max(0, FInfo.DocumentHeight - FInfo.ViewportHeight - FInfo.ScrollY);
  if Lowest > 0 then
    Lowest := 0;
  Moved := EnsureRange(FScrollShift + Bounded(Pixels), Lowest, Highest);
  if Moved = FScrollShift then
    Exit;
  FScrollShift := Moved;
  FShiftUntilInput := InputSequence;
  Result := True;
end;

procedure TRemoteFrames.Restart;
begin
  FInfo := Default(TIpcFrameInfo);
  FScrollShift := 0;
  FShiftUntilInput := 0;
end;

{ The shift in whole pixels, no more than the viewport (past that the
  whole viewport is unknown anyway). }
function TRemoteFrames.ShiftPixels: LongInt;
begin
  Result := Round(EnsureRange(FScrollShift, -FInfo.ViewportHeight, FInfo.ViewportHeight));
end;

procedure TRemoteFrames.Paint(var Canvas: TCanvas; Width, Height: LongInt);
var
  Moved, Shown: LongInt;
  Source: TRectangle;
begin
  if not FHasFrame or (FFrame.Pixels = nil) then
  begin
    FillRectangle(Canvas, MakeRectangle(0, 0, Width, Height), ColorWhite);
    Exit;
  end;
  Moved := ShiftPixels;
  if Moved = 0 then
    DrawSurface(Canvas, FFrame, MakeRectangle(0, 0, FFrame.Width, FFrame.Height), 0, 0, False, 255)
  else
  begin
    { The viewport part moved by the shift; the scroll bars stay. }
    Shown := Min(FInfo.ViewportWidth, FFrame.Width);
    if Moved > 0 then
    begin
      Source := MakeRectangle(0, Moved, Shown, Max(0, FInfo.ViewportHeight - Moved));
      DrawSurface(Canvas, FFrame, Source, 0, 0, False, 255);
      FillRectangle(Canvas, MakeRectangle(0, RectangleHeight(Source), Shown, Moved), ColorWhite);
    end
    else
    begin
      Source := MakeRectangle(0, 0, Shown, Max(0, FInfo.ViewportHeight + Moved));
      DrawSurface(Canvas, FFrame, Source, 0, -Moved, False, 255);
      FillRectangle(Canvas, MakeRectangle(0, 0, Shown, -Moved), ColorWhite);
    end;
    if FFrame.Width > Shown then
      DrawSurface(Canvas, FFrame, MakeRectangle(Shown, 0, FFrame.Width - Shown, FFrame.Height), Shown, 0,
        False, 255);
  end;
  if FFrame.Width < Width then
    FillRectangle(Canvas, MakeRectangle(FFrame.Width, 0, Width - FFrame.Width, Height), ColorWhite);
  if FFrame.Height < Height then
    FillRectangle(Canvas, MakeRectangle(0, FFrame.Height, Width, Height - FFrame.Height), ColorWhite);
end;

end.

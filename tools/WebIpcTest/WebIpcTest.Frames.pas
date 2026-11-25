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
  WebIpcTest: the browser's side of a renderer's frames
  (WebView.RemoteFrames) against a fake renderer. The renderer replaces
  its surface (a new size, or the same size again), presents frames of
  the current and of replaced surfaces, frames larger than their surface,
  damage and viewports of any size and document sizes that are not
  numbers, while the browser side scrolls the last frame (async
  scrolling) and paints it at changing sizes. A replaced surface is
  poisoned when the frames let it go (its memory kept), so a frame read
  from it after that shows up in the view's picture.
}
unit WebIpcTest.Frames;

{$mode objfpc}
{$H+}

interface

procedure RunFrameChecks;

implementation

uses
  SysUtils,
  Math,
  TestChecks,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  WebIpc.ViewMessages,
  WebView.RemoteFrames;

const
  Poison = TColor($FFFF00FF);
  TestRed = TColor($FFCC0000);
  TestBlue = TColor($FF0000CC);

type
  { A renderer's shared section: when the frames free it, its pixels are
    poisoned, not freed (the test frees them at the end). }
  TFakeSection = class
  public
    Surface: TSurface;
    Released: Boolean;
    destructor Destroy; override;
  end;

var
  Sections: array of TSurface;

destructor TFakeSection.Destroy;
var
  Canvas: TCanvas;
begin
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, MakeRectangle(0, 0, Surface.Width, Surface.Height), Poison);
  inherited Destroy;
end;

function NewSection(Width, Height: LongInt; Color: TColor; out Section: TFakeSection): Boolean;
var
  Canvas: TCanvas;
begin
  Section := TFakeSection.Create;
  Result := CreateSurface(Section.Surface, Width, Height, Color);
  if not Result then
  begin
    Section.Released := True;
    FreeAndNil(Section);
    Exit;
  end;
  SetLength(Sections, Length(Sections) + 1);
  Sections[High(Sections)] := Section.Surface;
  BeginCanvas(Canvas, Section.Surface);
  FillRectangle(Canvas, MakeRectangle(0, 0, Width, Height), Color);
end;

function FrameOf(SurfaceId: LongWord; Width, Height: LongInt): TIpcFrameInfo;
begin
  Result := Default(TIpcFrameInfo);
  Result.SurfaceId := SurfaceId;
  Result.Width := Width;
  Result.Height := Height;
  Result.DamageRight := Width;
  Result.DamageBottom := Height;
  Result.ViewportWidth := Width - 10;
  Result.ViewportHeight := Height;
  Result.DocumentWidth := Width - 10;
  Result.DocumentHeight := Height * 10;
end;

function SurfaceHas(const Surface: TSurface; Color: TColor): Boolean;
var
  X, Y: LongInt;
begin
  Result := False;
  for Y := 0 to Surface.Height - 1 do
    for X := 0 to Surface.Width - 1 do
      if SurfaceLine(Surface, Y)[X] = Color then
        Exit(True);
end;

procedure CheckReplacedSurfaces;
var
  Frames: TRemoteFrames;
  First, Second: TFakeSection;
  Info: TIpcFrameInfo;
  Damage: TRectangle;
  View: TSurface;
  Canvas: TCanvas;
begin
  Frames := TRemoteFrames.Create;
  try
    Check(NewSection(200, 100, TestRed, First), 'frames: a section');
    Frames.TakeSurface(1, First, First.Surface);
    Info := FrameOf(1, 200, 100);
    Check(Frames.TakeFrame(Info, Damage), 'frames: a frame of the surface is taken');
    Check((RectangleWidth(Damage) = 200) and (RectangleHeight(Damage) = 100), 'frames: a new picture is damaged whole');
    Check(not Frames.TakeFrame(FrameOf(2, 200, 100), Damage), 'frames: a frame of another surface is refused');
    Check(not Frames.TakeFrame(FrameOf(1, 201, 100), Damage), 'frames: a frame wider than its surface is refused');
    Check(not Frames.TakeFrame(FrameOf(1, 200, 0), Damage), 'frames: an empty frame is refused');
    { The renderer resizes: the old section goes, its frames are refused. }
    Check(NewSection(300, 150, TestBlue, Second), 'frames: a second section');
    Frames.TakeSurface(2, Second, Second.Surface);
    Check(not Frames.TakeFrame(Info, Damage), 'frames: a frame of the replaced surface is refused');
    Check(Frames.TakeFrame(FrameOf(2, 300, 150), Damage), 'frames: the new surface''s frame is taken');
    Check(CreateSurface(View, 320, 160, ColorBlack), 'frames: a view');
    BeginCanvas(Canvas, View);
    Frames.Paint(Canvas, 320, 160);
    Check(not SurfaceHas(View, Poison), 'frames: nothing of the replaced section is shown');
    Check((SurfaceLine(View, 10)[10] = TestBlue) and (SurfaceLine(View, 155)[10] = ColorWhite) and
      (SurfaceLine(View, 10)[310] = ColorWhite), 'frames: the frame, white around it');
    { The renderer ends: no surface; the last frame stays shown. }
    Frames.TakeSurface(0, nil, Default(TSurface));
    Check(not Frames.TakeFrame(FrameOf(2, 300, 150), Damage), 'frames: no surface, no frame');
    Check(Frames.HasFrame, 'frames: the last frame stays');
    FreeSurface(View);
  finally
    Frames.Free;
  end;
end;

procedure CheckAsyncScrolling;
var
  Frames: TRemoteFrames;
  Section: TFakeSection;
  Info: TIpcFrameInfo;
  Damage: TRectangle;
  View: TSurface;
  Canvas: TCanvas;
  Paint: TCanvas;
  Y: LongInt;
begin
  Frames := TRemoteFrames.Create;
  try
    Check(NewSection(100, 100, ColorWhite, Section), 'scrolling: a section');
    { Rows of the renderer's picture told apart by their colour. }
    BeginCanvas(Paint, Section.Surface);
    for Y := 0 to 99 do
      FillRectangle(Paint, MakeRectangle(0, Y, 100, 1), TColor($FF000000 or LongWord(Y)));
    Frames.TakeSurface(1, Section, Section.Surface);
    Info := FrameOf(1, 100, 100);
    Info.ViewportWidth := 90;
    Info.ScrollY := 50;
    Info.DocumentHeight := 400;
    Info.InputHandled := 3;
    Check(Frames.TakeFrame(Info, Damage), 'scrolling: a frame');
    Check(Frames.Shift(-80, 4), 'scrolling: the last frame moves');
    Check(Frames.ScrollShift = -50, 'scrolling: the shift stops at the top (' + FloatToStr(Frames.ScrollShift) + ')');
    Frames.Shift(1000, 5);
    Check(Frames.ScrollShift = 250, 'scrolling: the shift stops at the end of the document');
    Frames.Shift(-230, 6);
    Check(Frames.ScrollShift = 20, 'scrolling: down by 20');
    Check(CreateSurface(View, 100, 100, ColorBlack), 'scrolling: a view');
    BeginCanvas(Canvas, View);
    Frames.Paint(Canvas, 100, 100);
    Check(SurfaceLine(View, 0)[5] = TColor($FF000000 or 20), 'scrolling: the frame moved up by the shift');
    Check(SurfaceLine(View, 85)[5] = ColorWhite, 'scrolling: white where nothing is known yet');
    Check(SurfaceLine(View, 0)[95] = TColor($FF000000), 'scrolling: the scroll bar stays');
    { A frame that had not handled the input that scrolled keeps the shift. }
    Info.InputHandled := 5;
    Frames.TakeFrame(Info, Damage);
    Check(Frames.ScrollShift = 20, 'scrolling: an older frame keeps the shift');
    Info.InputHandled := 6;
    Frames.TakeFrame(Info, Damage);
    Check(Frames.ScrollShift = 0, 'scrolling: the frame that handled the input takes over');
    Check(RectangleHeight(Damage) = 100, 'scrolling: and is shown whole');
    { Lies about the document and the viewport. }
    Info.DocumentHeight := Infinity;
    Info.ScrollY := NaN;
    Info.ViewportHeight := MaxInt;
    Info.ViewportWidth := -5;
    Frames.TakeFrame(Info, Damage);
    Frames.Shift(1.0e300, 7);
    Frames.Paint(Canvas, 100, 100);
    Frames.Shift(-1.0e300, 8);
    Frames.Paint(Canvas, 100, 100);
    Check(True, 'scrolling: sizes that are not numbers do no harm');
    FreeSurface(View);
  finally
    Frames.Free;
  end;
end;

{ The renderer replaces and resizes its surface at random while the
  browser side scrolls, takes frames and paints. }
procedure FuzzFrames;
var
  Frames: TRemoteFrames;
  Section: TFakeSection;
  CurrentId, NextId: LongWord;
  CurrentWidth, CurrentHeight: LongInt;
  Info: TIpcFrameInfo;
  Damage: TRectangle;
  View: TSurface;
  Canvas: TCanvas;
  Step, Choice, ViewWidth, ViewHeight, Sequence, Taken: LongInt;
  Clean: Boolean;
begin
  RandSeed := 20261124;
  Frames := TRemoteFrames.Create;
  View := Default(TSurface);
  CurrentId := 0;
  NextId := 1;
  CurrentWidth := 0;
  CurrentHeight := 0;
  Sequence := 0;
  Taken := 0;
  Clean := True;
  try
    for Step := 1 to 20000 do
    begin
      Choice := Random(100);
      if Choice < 8 then
      begin
        { A new size (or the same again): a new section. }
        CurrentWidth := 1 + Random(300);
        CurrentHeight := 1 + Random(200);
        if NewSection(CurrentWidth, CurrentHeight, TColor($FF000000 or LongWord(Random($FFFFFF))) and
          not TColor($00010000), Section) then
        begin
          CurrentId := NextId;
          Inc(NextId);
          Frames.TakeSurface(CurrentId, Section, Section.Surface);
        end;
      end
      else if Choice < 10 then
      begin
        Frames.TakeSurface(0, nil, Default(TSurface));
        CurrentId := 0;
      end
      else if Choice < 50 then
      begin
        { A frame: mostly of the current surface, sometimes of an old
          one, too large, or with damage and sizes anywhere. }
        Info := FrameOf(CurrentId, CurrentWidth, CurrentHeight);
        case Random(6) of
          0: Info.SurfaceId := LongWord(Random(NextId + 2));
          1: begin
               Info.Width := CurrentWidth + Random(3) - 1;
               Info.Height := CurrentHeight + Random(3) - 1;
             end;
          2: begin
               Info.DamageLeft := Random(1000) - 500;
               Info.DamageTop := Random(1000) - 500;
               Info.DamageRight := Random(1000) - 500;
               Info.DamageBottom := Random(1000) - 500;
             end;
          3: begin
               Info.ViewportWidth := Random(2000) - 1000;
               Info.ViewportHeight := Random(2000) - 1000;
               Info.ScrollY := (Random(2000) - 1000) * 1000.0;
               Info.DocumentHeight := (Random(2000) - 1000) * 1000.0;
             end;
        end;
        Info.InputHandled := LongWord(Max(0, Sequence - Random(3)));
        if Frames.TakeFrame(Info, Damage) then
          Inc(Taken);
      end
      else if Choice < 75 then
      begin
        Inc(Sequence);
        Frames.Shift((Random(2000) - 1000) * 1.0, LongWord(Sequence));
      end
      else if Choice < 80 then
        Frames.InputHandled(LongWord(Max(0, Sequence - Random(2))))
      else if Choice < 82 then
        Frames.Restart
      else
      begin
        { The view painted, at a size of its own (a resize on the way). }
        if (View.Pixels = nil) or (Random(10) = 0) then
        begin
          FreeSurface(View);
          ViewWidth := 1 + Random(320);
          ViewHeight := 1 + Random(220);
          CreateSurface(View, ViewWidth, ViewHeight, ColorBlack);
        end;
        BeginCanvas(Canvas, View);
        Frames.Paint(Canvas, View.Width, View.Height);
        if Clean and SurfaceHas(View, Poison) then
        begin
          Clean := False;
          Check(False, 'frames fuzz: a replaced section was shown at step ' + IntToStr(Step));
        end;
      end;
    end;
    Check(Clean, 'frames fuzz: replaced sections are never read');
    Check(Taken > 1000, 'frames fuzz: frames were taken (' + IntToStr(Taken) + ')');
  finally
    FreeSurface(View);
    Frames.Free;
  end;
end;

procedure FreeSections;
var
  Index: Integer;
begin
  for Index := 0 to High(Sections) do
    FreeSurface(Sections[Index]);
  Sections := nil;
end;

procedure RunFrameChecks;
begin
  CheckReplacedSurfaces;
  CheckAsyncScrolling;
  FuzzFrames;
  FreeSections;
end;

end.

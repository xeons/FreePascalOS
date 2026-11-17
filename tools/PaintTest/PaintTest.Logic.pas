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
  Paint's plain logic: the zoom's levels and mapping, the geometry of
  dragging (corners, Shift's constraints, extents), the file formats by
  name, and the undo history and document (versions, the memory
  budget, saved or changed).
}
unit PaintTest.Logic;

{$mode objfpc}
{$H+}

interface

procedure TestPaintLogic;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model,
  Image.Codecs,
  Paint.ZoomMapping,
  Paint.ShapeGeometry,
  Paint.FileFormats,
  Paint.UndoHistory,
  Paint.Document,
  PaintTest.Checks;

procedure TestZoomLevels;
begin
  CheckNumber('zoom in from 100%', ZoomedIn(1000), 2000);
  CheckNumber('zoom out from 100%', ZoomedOut(1000), 667);
  CheckNumber('zoom in stops at 800%', ZoomedIn(8000), 8000);
  CheckNumber('zoom out stops at 12.5%', ZoomedOut(125), 125);
  CheckNumber('zoom in from between levels', ZoomedIn(1500), 2000);
  CheckNumber('zoom kept within the range', ClampZoom(20000), LargestZoom);
  CheckText('zoom text 12.5%', ZoomText(125), '12.5%');
  CheckText('zoom text 100%', ZoomText(1000), '100%');
  CheckText('zoom text 33.3%', ZoomText(333), '33.3%');
  Check('grid from 400%', GridShows(4000) and not GridShows(3000));
end;

procedure TestZoomMapping;
var
  Mapping: TViewMapping;
begin
  { 400%, the picture 10 pixels into the view, scrolled by 20. }
  Mapping := MakeViewMapping(4000, 10, 10, 20, 0);
  CheckNumber('400%: image pixel 5 starts at view 10 + 20 - 20', PixelStartX(Mapping, 5), 10);
  CheckNumber('400%: view pixel 10 shows image pixel 5', ImageColumnAt(Mapping, 10), 5);
  CheckNumber('400%: view pixel 13 still image pixel 5', ImageColumnAt(Mapping, 13), 5);
  CheckNumber('400%: view pixel 14 shows image pixel 6', ImageColumnAt(Mapping, 14), 6);
  CheckNumber('400%: left of the picture is a negative pixel', ImageColumnAt(Mapping, -11), -1);
  Check('400%: view to image and back', Abs(ImageToViewX(Mapping, ViewToImageX(Mapping, 37)) - 37) < 1E-9);
  Check('400%: view 12 is image 5.5', Abs(ViewToImageX(Mapping, 12) - 5.5) < 1E-9);
  { 12.5%: a view pixel stands for eight image pixels. }
  Mapping := MakeViewMapping(125, 0, 0, 0, 0);
  CheckNumber('12.5%: view pixel 3 shows image pixel 24', ImageColumnAt(Mapping, 3), 24);
  CheckNumber('12.5%: image pixel 24 starts at view 3', PixelStartX(Mapping, 24), 3);
  CheckNumber('12.5%: a 100-pixel picture is 12 view pixels', ZoomedLength(100, 125), 12);
  CheckNumber('12.5%: a 1-pixel picture is still 1', ZoomedLength(1, 125), 1);
  { 66.7%: columns increase one at a time or skip, never go back. }
  Mapping := MakeViewMapping(667, 0, 0, 0, 0);
  CheckNumber('66.7%: view 2 shows image 2', ImageColumnAt(Mapping, 2), 2);
  Check('66.7%: each column starts where the mapping says',
    PixelStartX(Mapping, ImageColumnAt(Mapping, 2)) <= 2);
  CheckNumber('zooming at the pointer keeps the point', ScrollKeepingPoint(50, 100, 0, 2000), 0);
  CheckNumber('zooming at the pointer, 400%', ScrollKeepingPoint(50, 100, 0, 4000), 100);
  CheckNumber('scroll kept within the content', ClampScroll(500, 800, 400), 400);
  CheckNumber('no scroll when it fits', ClampScroll(30, 300, 400), 0);
  CheckNumber('no negative scroll', ClampScroll(-5, 800, 400), 0);
end;

procedure TestGeometry;
var
  Corner: TPoint;
  Points: array[0..1] of TPoint;
begin
  CheckRectangle('corners either way round', RectangleFromCorners(10, 20, 4, 2), MakeRectangle(4, 2, 7, 19));
  CheckRectangle('one pixel', RectangleFromCorners(3, 3, 3, 3), MakeRectangle(3, 3, 1, 1));
  Corner := SquareCorner(0, 0, 10, -4);
  Check('square: the longer side wins, up and right', (Corner.X = 10) and (Corner.Y = -10));
  Corner := SquareCorner(5, 5, 2, 9);
  Check('square: left and down', (Corner.X = 1) and (Corner.Y = 9));
  Corner := LineAtSnappedAngle(0, 0, 100, 20);
  Check('line nearly level is level', (Corner.X = 100) and (Corner.Y = 0));
  Corner := LineAtSnappedAngle(0, 0, 10, -100);
  Check('line nearly upright is upright', (Corner.X = 0) and (Corner.Y = -100));
  Corner := LineAtSnappedAngle(0, 0, 50, 40);
  Check('line near 45 degrees is diagonal', (Corner.X = 45) and (Corner.Y = 45));
  Corner := LineAtSnappedAngle(10, 10, -30, 50);
  Check('diagonal down and left', (Corner.X = -30) and (Corner.Y = 50));
  Points[0] := MakePoint(10, 10);
  Points[1] := MakePoint(30, 20);
  CheckRectangle('stroke 1 wide reaches a pixel round', StrokeExtent(Points, 1), MakeRectangle(9, 9, 23, 13));
  CheckRectangle('stroke 6 wide reaches 4 round', StrokeExtent(Points, 6), MakeRectangle(6, 6, 29, 19));
  Check('no points, no extent', RectangleIsEmpty(StrokeExtent([], 5)));
  Check('near within reach', IsNear(10, 12, 12, 10, 2) and not IsNear(10, 13, 12, 10, 2));
end;

procedure TestFileFormats;
begin
  Check('png by name', SaveFormatForPath('/tmp/a.png') = ImageFormatPng);
  Check('JPEG by either extension, any case', (SaveFormatForPath('x.JPG') = ImageFormatJpeg) and
    (SaveFormatForPath('x.jpeg') = ImageFormatJpeg));
  Check('tiff and webp and gif and bmp', (SaveFormatForPath('a.tif') = ImageFormatTiff) and
    (SaveFormatForPath('a.webp') = ImageFormatWebp) and (SaveFormatForPath('a.gif') = ImageFormatGif) and
    (SaveFormatForPath('a.bmp') = ImageFormatBmp));
  Check('an unknown extension', SaveFormatForPath('a.txt') = ImageFormatUnknown);
  CheckText('no extension gets .png', PathWithDefaultExtension('/tmp/picture'), '/tmp/picture.png');
  CheckText('a dot in a folder is no extension', PathWithDefaultExtension('/tmp/my.folder/pic'),
    '/tmp/my.folder/pic.png');
  CheckText('a hidden name has no extension', PathWithDefaultExtension('/tmp/.hidden'), '/tmp/.hidden.png');
  CheckText('an extension is kept', PathWithDefaultExtension('/tmp/a.bmp'), '/tmp/a.bmp');
  Check('only JPEG is lossy', FormatIsLossy(ImageFormatJpeg) and not FormatIsLossy(ImageFormatPng));
end;

function SolidImage(Width, Height: LongInt; Color: TColor): TImage;
begin
  Result := TImage.Create(Width, Height);
  Result.Fill(Color);
end;

procedure TestUndoHistory;
var
  Document: TPaintDocument;
  Before: TImage;
  Area: TRectangle;
  Replacement: TImage;
begin
  Document := TPaintDocument.Create(SolidImage(20, 10, ColorWhite));
  try
    Check('a new document has no changes', not Document.Modified and not Document.CanUndo);
    Before := Document.Image.Clone;
    Document.Image.SetPixel(3, 4, ColorBlack);
    Document.Image.SetPixel(5, 6, ColorBlack);
    Document.RecordAreaChange(Before, MakeRectangle(3, 4, 3, 3), 'Pencil');
    Before.Free;
    Check('an edit makes changes', Document.Modified and Document.CanUndo and not Document.CanRedo);
    CheckNumber('the step keeps only its area, before and after', Document.History.BytesKept, 2 * 9 * 4);
    Check('undo', Document.Undo(Area));
    CheckRectangle('undo says what changed', Area, MakeRectangle(3, 4, 3, 3));
    CheckColor('undo puts the pixel back', Document.Image.GetPixel(3, 4), ColorWhite);
    Check('undone to the start: no changes', not Document.Modified and Document.CanRedo);
    Check('redo', Document.Redo(Area));
    CheckColor('redo paints it again', Document.Image.GetPixel(5, 6), ColorBlack);
    Document.MarkSaved;
    Check('saved: no changes', not Document.Modified);
    Document.Undo(Area);
    Check('undone past the save: changes', Document.Modified);
    Document.Redo(Area);
    Check('redone to the save: no changes', not Document.Modified);
    { A whole new picture (another size). }
    Replacement := SolidImage(5, 7, ColorBlack);
    Document.ReplaceImage(Replacement, 'Crop');
    Check('replaced: the new size', (Document.Image.Width = 5) and (Document.Image.Height = 7));
    Document.Undo(Area);
    Check('undoing a crop: the old size back, the area empty (all of it)',
      (Document.Image.Width = 20) and (Document.Image.Height = 10) and RectangleIsEmpty(Area));
    Document.Redo(Area);
    Check('redoing the crop', (Document.Image.Width = 5) and (Document.Image.Height = 7));
    { A new edit after an undo forgets the redo. }
    Document.Undo(Area);
    Before := Document.Image.Clone;
    Document.Image.SetPixel(0, 0, ColorBlack);
    Document.RecordAreaChange(Before, MakeRectangle(0, 0, 1, 1), 'Pencil');
    Before.Free;
    Check('a new edit forgets what could be redone', not Document.CanRedo);
    { An area outside the picture records nothing. }
    Before := Document.Image.Clone;
    Document.RecordAreaChange(Before, MakeRectangle(50, 50, 4, 4), 'Nothing');
    Before.Free;
    CheckNumber('nothing recorded for an area off the picture', Document.History.UndoCount, 2);
  finally
    Document.Free;
  end;
end;

procedure TestUndoBudget;
var
  Document: TPaintDocument;
  Before: TImage;
  Step: LongInt;
  Area: TRectangle;
begin
  Document := TPaintDocument.Create(SolidImage(100, 100, ColorWhite));
  try
    { Each step of the whole picture keeps 2 x 40000 bytes: a budget of
      200000 keeps two. }
    Document.History.LimitBytes := 200000;
    for Step := 1 to 5 do
    begin
      Before := Document.Image.Clone;
      Document.Image.Fill(RgbColor(Step, 0, 0));
      Document.RecordAreaChange(Before, MakeRectangle(0, 0, 100, 100), 'Fill');
      Before.Free;
    end;
    CheckNumber('the budget keeps the newest steps', Document.History.UndoCount, 2);
    Check('within the budget', Document.History.BytesKept <= 200000);
    Document.Undo(Area);
    Document.Undo(Area);
    Check('no more to undo', not Document.CanUndo);
    CheckColor('the oldest kept step undone', Document.Image.GetPixel(0, 0), RgbColor(3, 0, 0));
    Check('steps forgotten: still changed from the start', Document.Modified);
    { One step larger than the budget is still kept. }
    Document.History.LimitBytes := 1000;
    Before := Document.Image.Clone;
    Document.Image.Fill(ColorBlack);
    Document.RecordAreaChange(Before, MakeRectangle(0, 0, 100, 100), 'Fill');
    Before.Free;
    CheckNumber('the newest step is kept however large', Document.History.UndoCount, 1);
    Document.Reset(SolidImage(4, 4, ColorWhite));
    Check('reset: no history, no changes', not Document.CanUndo and not Document.CanRedo and
      not Document.Modified and (Document.History.BytesKept = 0));
  finally
    Document.Free;
  end;
end;

procedure TestPaintLogic;
begin
  TestZoomLevels;
  TestZoomMapping;
  TestGeometry;
  TestFileFormats;
  TestUndoHistory;
  TestUndoBudget;
end;

end.

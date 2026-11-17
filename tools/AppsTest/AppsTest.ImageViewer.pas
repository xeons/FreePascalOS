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
  AppsTest: the image viewer's zoom and pan arithmetic, its turns and
  the folder's next and previous images.
}
unit AppsTest.ImageViewer;

{$mode objfpc}
{$H+}

interface

procedure TestImageViewer;

implementation

uses
  SysUtils,
  Classes,
  AppsTest.Checks,
  ImageViewer.ViewGeometry,
  ImageViewer.Orientations,
  ImageViewer.FolderImages;

procedure TestZoom;
begin
  CheckNear('zoom in from 100%', ZoomedIn(1), 1.5, 1e-9);
  CheckNear('zoom out from 100%', ZoomedOut(1), 0.666666666666667, 1e-9);
  CheckNear('zoom in from between steps', ZoomedIn(0.7), 1, 1e-9);
  CheckNear('zoom out from between steps', ZoomedOut(0.7), 0.666666666666667, 1e-9);
  CheckNear('no zoom beyond the largest', ZoomedIn(32), 32, 1e-9);
  CheckNear('no zoom below the smallest', ZoomedOut(0.05), 0.05, 1e-9);
  CheckNear('a picture larger than the view fits by its width', FitZoom(2000, 1000, 500, 500, False), 0.25, 1e-9);
  CheckNear('or by its height', FitZoom(1000, 2000, 500, 500, False), 0.25, 1e-9);
  CheckNear('a small picture is not enlarged to fit', FitZoom(100, 50, 500, 500, False), 1, 1e-9);
  CheckNear('unless enlarging is allowed', FitZoom(100, 50, 500, 500, True), 5, 1e-9);
  CheckNear('an empty view fits at 100%', FitZoom(100, 50, 0, 0, False), 1, 1e-9);
  CheckNumber('the zoomed extent', ZoomedExtent(300, 1.5), 450);
  CheckNumber('a zoomed extent is never 0', ZoomedExtent(3, 0.05), 1);
  CheckText('percent: whole', ZoomPercentText(1), '100%');
  CheckText('percent: a fraction', ZoomPercentText(0.125), '12.5%');
  CheckText('percent: large', ZoomPercentText(32), '3200%');
end;

procedure TestPanning;
begin
  CheckNumber('centred while smaller than the view', CentringOffset(200, 500), 150);
  CheckNumber('not centred when larger', CentringOffset(800, 500), 0);
  CheckNumber('scroll kept within the content', ClampScroll(400, 800, 500), 300);
  CheckNumber('no scroll below 0', ClampScroll(-20, 800, 500), 0);
  CheckNumber('no scroll when the content fits', ClampScroll(50, 300, 500), 0);
  { 1000 wide at 100% in a 500 view scrolled to 250: the spot under the
    view's middle (500) doubles to 1000 at 200%, and stays at 250. }
  CheckNumber('zooming in about the middle keeps the middle', ScrollKeepingPoint(250, 250, 1000, 2000, 500), 750);
  CheckNumber('zooming in about the left edge keeps it', ScrollKeepingPoint(0, 0, 1000, 2000, 500), 0);
  { From centred (200 in 500, offset 150) to 1000: the pointer at 250 was
    at content 100 of 200 (the middle), now 500 of 1000. }
  CheckNumber('zooming in from centred', ScrollKeepingPoint(0, 250, 200, 1000, 500), 250);
  CheckNumber('zooming out to smaller than the view scrolls to 0', ScrollKeepingPoint(300, 100, 1000, 300, 500), 0);
  CheckNumber('dragging left scrolls right', DraggedScroll(100, 300, 250, 1000, 500), 150);
  CheckNumber('dragging stops at the edge', DraggedScroll(100, 300, 600, 1000, 500), 0);
  CheckNumber('dragging stops at the far edge', DraggedScroll(400, 300, 100, 1000, 500), 500);
end;

procedure TestTurns;
var
  Turn: TViewTurn;
  Index: LongInt;
  Value: LongInt;
  AllBack: Boolean;
begin
  Turn := NoTurn;
  CheckNumber('no turn is EXIF 1', ExifOrientationOf(Turn), 1);
  Turn := TurnedClockwise(Turn);
  CheckNumber('a clockwise turn is EXIF 6', ExifOrientationOf(Turn), 6);
  Check('a quarter turn swaps the sides', TurnSwapsSides(Turn));
  Turn := TurnedClockwise(Turn);
  CheckNumber('two turns are EXIF 3', ExifOrientationOf(Turn), 3);
  Turn := TurnedAnticlockwise(TurnedAnticlockwise(TurnedAnticlockwise(NoTurn)));
  CheckNumber('three anticlockwise turns are one clockwise', ExifOrientationOf(Turn), 6);
  CheckNumber('an anticlockwise turn is EXIF 8', ExifOrientationOf(TurnedAnticlockwise(NoTurn)), 8);
  CheckNumber('a horizontal flip is EXIF 2', ExifOrientationOf(FlippedHorizontally(NoTurn)), 2);
  CheckNumber('a vertical flip is EXIF 4', ExifOrientationOf(FlippedVertically(NoTurn)), 4);
  Turn := FlippedVertically(FlippedHorizontally(NoTurn));
  CheckNumber('both flips are a half turn', ExifOrientationOf(Turn), 3);
  { Turned clockwise, then mirrored as seen: EXIF 5 (transpose) - the
    top left corner goes to the top left, the picture flipped across
    that diagonal. }
  CheckNumber('a turn then a flip', ExifOrientationOf(FlippedHorizontally(TurnedClockwise(NoTurn))), 5);
  CheckNumber('a flip then a turn', ExifOrientationOf(TurnedClockwise(FlippedHorizontally(NoTurn))), 7);
  CheckNumber('flipping twice undoes it',
    ExifOrientationOf(FlippedHorizontally(FlippedHorizontally(TurnedClockwise(NoTurn)))), 6);
  Check('four turns are none', IsNoTurn(TurnedClockwise(TurnedClockwise(TurnedClockwise(TurnedClockwise(NoTurn))))));
  AllBack := True;
  for Index := 1 to 8 do
  begin
    Value := ExifOrientationOf(TurnOfExif(Index));
    if Value <> Index then
      AllBack := False;
  end;
  Check('each EXIF orientation is a turn and back', AllBack);
end;

procedure TestFolderImages;
var
  Names: TStringList;
begin
  Check('a PNG is an image', HasImageExtension('photo.PNG'));
  Check('a JPEG XL is an image', HasImageExtension('a.jxl'));
  Check('a text file is not', not HasImageExtension('notes.txt'));
  Check('no extension is not', not HasImageExtension('README'));
  Check('numbers compare as numbers', CompareImageNames('img2.png', 'img10.png') < 0);
  Check('case does not matter', CompareImageNames('B.png', 'a.png') > 0);
  Names := TStringList.Create;
  try
    Names.CommaText := 'img10.png,notes.txt,img2.png,Img1.jpg,cat.gif';
    KeepImageNames(Names);
    CheckText('images kept and sorted', Names.CommaText, 'cat.gif,Img1.jpg,img2.png,img10.png');
    CheckText('the next image', NeighbourName(Names, 'img2.png', 1), 'img10.png');
    CheckText('the previous image', NeighbourName(Names, 'img2.png', -1), 'Img1.jpg');
    CheckText('after the last comes the first', NeighbourName(Names, 'img10.png', 1), 'cat.gif');
    CheckText('before the first comes the last', NeighbourName(Names, 'cat.gif', -1), 'img10.png');
    CheckText('a name not in the folder: the next after it', NeighbourName(Names, 'dog.png', 1), 'Img1.jpg');
    CheckText('a name not in the folder: the one before it', NeighbourName(Names, 'dog.png', -1), 'cat.gif');
    Names.Clear;
    CheckText('no images: nothing', NeighbourName(Names, 'a.png', 1), '');
  finally
    Names.Free;
  end;
end;

procedure TestImageViewer;
begin
  TestZoom;
  TestPanning;
  TestTurns;
  TestFolderImages;
end;

end.

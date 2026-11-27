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
  The Image menu's commands on the whole picture, each one edit for
  undo: turning it a quarter or half turn, mirroring it, inverting its
  colours, stretching and skewing it, giving it another canvas size
  (the new part in the secondary colour, or cut off) and clearing it to
  the secondary colour. Anything floating is put down first, and the
  selection forgotten, as the picture's size may change under it.
}
unit Paint.ImageCommands;

{$mode objfpc}
{$H+}

interface

uses
  Paint.Session;

type
  TTurn = (TurnClockwise, TurnAnticlockwise, TurnHalf);

procedure TurnPicture(Session: TPaintSession; Turn: TTurn);
procedure FlipPicture(Session: TPaintSession; Horizontally: Boolean);
procedure InvertPicture(Session: TPaintSession);
procedure ResizePicture(Session: TPaintSession; NewWidth, NewHeight, SkewHorizontal, SkewVertical: LongInt);
procedure ChangeCanvasSize(Session: TPaintSession; NewWidth, NewHeight: LongInt);
procedure ClearPicture(Session: TPaintSession);

implementation

uses
  Drawing.Rectangles,
  Image.Model,
  Image.Areas,
  Image.Scaling,
  Image.Transforms;

procedure PutDownSelection(Session: TPaintSession);
begin
  Session.Editor.Deselect;
end;

{ An edit made in place on the whole picture, by Change. }
type
  TPictureChange = procedure(Image: TImage);

procedure ChangeInPlace(Session: TPaintSession; Change: TPictureChange; const Description: string);
var
  Before: TImage;
begin
  PutDownSelection(Session);
  Before := Session.Document.Image.Clone;
  try
    Change(Session.Document.Image);
    Session.Document.RecordAreaChange(Before, ImageBounds(Session.Document.Image), Description);
  finally
    Before.Free;
  end;
  Session.WholeImageChanged;
end;

procedure Replace(Session: TPaintSession; NewImage: TImage; const Description: string);
begin
  Session.Document.ReplaceImage(NewImage, Description);
  Session.WholeImageChanged;
end;

procedure TurnPicture(Session: TPaintSession; Turn: TTurn);
var
  Image: TImage;
begin
  PutDownSelection(Session);
  Image := Session.Document.Image;
  case Turn of
    TurnClockwise: Replace(Session, RotateImageClockwise(Image), 'Rotate');
    TurnAnticlockwise: Replace(Session, RotateImageAnticlockwise(Image), 'Rotate');
  else
    Replace(Session, RotateImageHalfTurn(Image), 'Rotate');
  end;
end;

procedure FlipAcross(Image: TImage);
begin
  FlipImageHorizontally(Image);
end;

procedure FlipUpDown(Image: TImage);
begin
  FlipImageVertically(Image);
end;

procedure Invert(Image: TImage);
begin
  InvertImageColors(Image);
end;

procedure FlipPicture(Session: TPaintSession; Horizontally: Boolean);
begin
  if Horizontally then
    ChangeInPlace(Session, @FlipAcross, 'Flip')
  else
    ChangeInPlace(Session, @FlipUpDown, 'Flip');
end;

procedure InvertPicture(Session: TPaintSession);
begin
  ChangeInPlace(Session, @Invert, 'Invert colours');
end;

procedure ResizePicture(Session: TPaintSession; NewWidth, NewHeight, SkewHorizontal, SkewVertical: LongInt);
var
  Image: TImage;
  Resized: TImage;
  Skewed: TImage;
begin
  PutDownSelection(Session);
  Image := Session.Document.Image;
  if (NewWidth = Image.Width) and (NewHeight = Image.Height) then
    Resized := Image.Clone
  else
  begin
    Resized := ScaleImage(Image, NewWidth, NewHeight);
    Resized.CopyPropertiesFrom(Image);
  end;
  if (SkewHorizontal <> 0) or (SkewVertical <> 0) then
  begin
    try
      Skewed := SkewImage(Resized, SkewHorizontal, SkewVertical, Session.SecondaryColor);
    finally
      Resized.Free;
    end;
    Resized := Skewed;
  end;
  Replace(Session, Resized, 'Resize');
end;

procedure ChangeCanvasSize(Session: TPaintSession; NewWidth, NewHeight: LongInt);
var
  Image: TImage;
  Canvas: TImage;
begin
  PutDownSelection(Session);
  Image := Session.Document.Image;
  if (NewWidth = Image.Width) and (NewHeight = Image.Height) then
    Exit;
  Canvas := TImage.Create(NewWidth, NewHeight);
  Canvas.Fill(Session.SecondaryColor);
  Canvas.CopyPropertiesFrom(Image);
  PutImage(Canvas, Image, 0, 0);
  Replace(Session, Canvas, 'Canvas size');
end;

procedure ClearPicture(Session: TPaintSession);
var
  Before: TImage;
begin
  PutDownSelection(Session);
  Before := Session.Document.Image.Clone;
  try
    Session.Document.Image.Fill(Session.SecondaryColor);
    Session.Document.RecordAreaChange(Before, ImageBounds(Session.Document.Image), 'Clear');
  finally
    Before.Free;
  end;
  Session.WholeImageChanged;
end;

end.

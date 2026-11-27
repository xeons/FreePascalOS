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
  What is done with the selection: moving its pixels, copying, cutting,
  pasting, deleting and cropping to it.

  To move the selected pixels they are lifted off the picture into a
  floating image (the selection's shape: transparent outside a free-form
  mask), and where they were is filled with the background colour,
  unless they are being copied (Ctrl held), when the picture keeps them.
  The floating pixels then go wherever the selection is moved (the view
  draws them over the picture) until they are put down: drawn over the
  picture by their alpha where the selection is. Pasting floats the
  pasted image in the same way, as does text just typed.

  Lifting and putting down are one edit for undo: a copy of the picture
  is taken when the pixels float, and when they are put down the step
  records everything between (where they were lifted from and where
  they landed).
}
unit Paint.SelectionEditing;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model,
  Paint.Document,
  Paint.Selection,
  Paint.ShapeGeometry;

type
  TSelectionEditor = class
  private
    FDocument: TPaintDocument;
    FSelection: TSelection;
    FFloating: TImage;
    FBefore: TImage;
    { What the floating pixels changed so far (where they were lifted). }
    FDirty: TRectangle;
    procedure StartFloating;
  public
    constructor Create(ADocument: TPaintDocument);
    destructor Destroy; override;
    { The selection becomes Area (or a free-form shape, or the whole
      picture), any floating pixels put down first. }
    procedure SelectRectangle(const Area: TRectangle);
    procedure SelectFreeForm(const Points: array of TPoint);
    procedure SelectAll;
    { Lifts the selected pixels to float (nothing if they float already);
      KeepCopy leaves them on the picture too, else their place takes
      FillColor. }
    procedure Lift(KeepCopy: Boolean; FillColor: TColor);
    procedure MoveBy(DeltaX, DeltaY: LongInt);
    { Puts floating pixels down (the selection stays, not floating). }
    procedure PutDown;
    { Puts floating pixels down and selects nothing. }
    procedure Deselect;
    { Image (taken) floats at (X, Y), selected. }
    procedure PasteImage(Image: TImage; X, Y: LongInt);
    { A copy of the selected pixels (transparent outside a free-form
      selection's mask and outside the picture); nil if nothing is
      selected. }
    function CopySelected: TImage;
    { Clears the selected pixels to FillColor (floating ones are just
      dropped) and selects nothing. }
    procedure DeleteSelected(FillColor: TColor);
    { The picture becomes the selected pixels. False if nothing is
      selected. }
    function CropToSelection: Boolean;
    { Forgets the selection and any floating pixels without recording
      anything (the picture was replaced, or an undo is coming: put
      down first if that matters). }
    procedure Forget;
    function IsFloating: Boolean;
    { The area of the picture the floating pixels or selection cover. }
    function Area: TRectangle;
    property Selection: TSelection read FSelection;
    property Floating: TImage read FFloating;
  end;

{ The pixels of Area of Image, as an image the size of Area (what lies
  outside Image transparent), with those where Mask is 0 transparent. }
function CopyMaskedArea(Image: TImage; const Area: TRectangle; const Mask: array of Byte): TImage;

implementation

uses
  Image.Areas;

function CopyMaskedArea(Image: TImage; const Area: TRectangle; const Mask: array of Byte): TImage;
var
  Inside: TImage;
  Index: LongInt;
  HasMask: Boolean;
  Part: TRectangle;
begin
  Result := TImage.Create(RectangleWidth(Area), RectangleHeight(Area));
  Part := ClipToImage(Image, Area);
  Inside := CopyImageArea(Image, Part);
  if Inside <> nil then
  begin
    PutImage(Result, Inside, Part.Left - Area.Left, Part.Top - Area.Top);
    Inside.Free;
  end;
  HasMask := Length(Mask) = Result.Width * Result.Height;
  if HasMask then
    for Index := 0 to High(Mask) do
      if Mask[Index] = 0 then
        Result.Pixels[Index] := ColorTransparent;
end;

constructor TSelectionEditor.Create(ADocument: TPaintDocument);
begin
  inherited Create;
  FDocument := ADocument;
  FSelection := TSelection.Create;
end;

destructor TSelectionEditor.Destroy;
begin
  FFloating.Free;
  FBefore.Free;
  FSelection.Free;
  inherited Destroy;
end;

function TSelectionEditor.IsFloating: Boolean;
begin
  Result := FFloating <> nil;
end;

function TSelectionEditor.Area: TRectangle;
begin
  Result := FSelection.Bounds;
end;

procedure TSelectionEditor.StartFloating;
begin
  FBefore.Free;
  FBefore := FDocument.Image.Clone;
  FDirty := MakeRectangle(0, 0, 0, 0);
end;

procedure TSelectionEditor.SelectRectangle(const Area: TRectangle);
var
  Inside: TRectangle;
begin
  Deselect;
  Inside := ClipToImage(FDocument.Image, Area);
  FSelection.SetRectangle(Inside);
end;

procedure TSelectionEditor.SelectFreeForm(const Points: array of TPoint);
begin
  Deselect;
  FSelection.SetFreeForm(Points);
end;

procedure TSelectionEditor.SelectAll;
begin
  SelectRectangle(ImageBounds(FDocument.Image));
end;

procedure TSelectionEditor.Lift(KeepCopy: Boolean; FillColor: TColor);
begin
  if not FSelection.Active or IsFloating then
    Exit;
  StartFloating;
  FFloating := CopyMaskedArea(FDocument.Image, FSelection.Bounds, FSelection.Mask);
  if not KeepCopy then
  begin
    FillImageArea(FDocument.Image, FSelection.Bounds, FillColor, FSelection.Mask);
    FDirty := ClipToImage(FDocument.Image, FSelection.Bounds);
  end;
end;

procedure TSelectionEditor.MoveBy(DeltaX, DeltaY: LongInt);
begin
  if FSelection.Active then
    FSelection.MoveBy(DeltaX, DeltaY);
end;

procedure TSelectionEditor.PutDown;
begin
  if not IsFloating then
    Exit;
  DrawImageOver(FDocument.Image, FFloating, FSelection.Bounds.Left, FSelection.Bounds.Top, FSelection.Mask);
  FDirty := BoundingRectangle(FDirty, ClipToImage(FDocument.Image, FSelection.Bounds));
  FDocument.RecordAreaChange(FBefore, FDirty, 'Move selection');
  FFloating.Free;
  FFloating := nil;
  FBefore.Free;
  FBefore := nil;
end;

procedure TSelectionEditor.Deselect;
begin
  PutDown;
  FSelection.Clear;
end;

procedure TSelectionEditor.PasteImage(Image: TImage; X, Y: LongInt);
begin
  Deselect;
  StartFloating;
  FFloating := Image;
  FSelection.SetRectangle(MakeRectangle(X, Y, Image.Width, Image.Height));
end;

function TSelectionEditor.CopySelected: TImage;
begin
  if not FSelection.Active then
    Exit(nil);
  if IsFloating then
    Exit(FFloating.Clone);
  Result := CopyMaskedArea(FDocument.Image, FSelection.Bounds, FSelection.Mask);
end;

procedure TSelectionEditor.DeleteSelected(FillColor: TColor);
var
  Before: TImage;
begin
  if not FSelection.Active then
    Exit;
  if IsFloating then
  begin
    { The lifted pixels are dropped: what was done before they floated
      (the hole they left) is the edit. }
    FDocument.RecordAreaChange(FBefore, FDirty, 'Delete selection');
    FFloating.Free;
    FFloating := nil;
    FBefore.Free;
    FBefore := nil;
  end
  else
  begin
    Before := FDocument.Image.Clone;
    try
      FillImageArea(FDocument.Image, FSelection.Bounds, FillColor, FSelection.Mask);
      FDocument.RecordAreaChange(Before, FSelection.Bounds, 'Delete selection');
    finally
      Before.Free;
    end;
  end;
  FSelection.Clear;
end;

function TSelectionEditor.CropToSelection: Boolean;
var
  Cropped: TImage;
begin
  if not FSelection.Active then
    Exit(False);
  PutDown;
  Cropped := CopyMaskedArea(FDocument.Image, FSelection.Bounds, FSelection.Mask);
  Cropped.CopyPropertiesFrom(FDocument.Image);
  FSelection.Clear;
  FDocument.ReplaceImage(Cropped, 'Crop');
  Result := True;
end;

procedure TSelectionEditor.Forget;
begin
  FFloating.Free;
  FFloating := nil;
  FBefore.Free;
  FBefore := nil;
  FSelection.Clear;
end;

end.

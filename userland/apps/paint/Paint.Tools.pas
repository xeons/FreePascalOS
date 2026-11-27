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
  What every tool is: it hears the pointer over the picture (in image
  coordinates, continuous: pixel P is [P, P + 1)), the button (left
  paints with the primary colour, right with the secondary) and the
  keys held (Shift constrains, Ctrl copies), and a few keys (Enter
  finishes a shape being made, Escape abandons it).

  An edit is made straight on the picture: BeginEdit keeps a copy of
  it as it was, a tool showing a shape while it is dragged puts the
  part it drew last back from that copy before drawing again
  (RestoreArea), every part touched is remembered (Touch, which also
  tells the window to paint it again), and CommitEdit records the whole
  edit as one undo step of the parts touched; CancelEdit puts them all
  back. Finish commits whatever a tool still has under way (before the
  tool changes, a save, an undo); a tool may draw what is not the
  picture's over the view (DrawOverlay: a free-form selection's line
  as it is drawn).
}
unit Paint.Tools;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Image.Model,
  Paint.ZoomMapping,
  Paint.Session;

type
  TPaintTool = class
  private
    FBefore: TImage;
    FDirty: TRectangle;
  protected
    FSession: TPaintSession;
    procedure BeginEdit;
    function Editing: Boolean;
    procedure Touch(const Area: TRectangle);
    procedure RestoreArea(const Area: TRectangle);
    procedure CommitEdit(const Description: string);
    procedure CancelEdit;
    { A canvas on the picture. }
    function ImageCanvas: TCanvas;
    { The colour Button paints with, and the other one. }
    function ColorFor(Button: LongWord): TColor;
    function OtherColorFor(Button: LongWord): TColor;
    function Image: TImage;
  public
    constructor Create(ASession: TPaintSession); virtual;
    destructor Destroy; override;
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); virtual;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); virtual;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); virtual;
    { True if the key was used. }
    function KeyDown(Code, Modifiers: LongWord): Boolean; virtual;
    procedure Finish; virtual;
    procedure Cancel; virtual;
    { Something under way (a drag, a polygon's corners). }
    function Busy: Boolean; virtual;
    procedure DrawOverlay(const Canvas: TCanvas; const Mapping: TViewMapping); virtual;
  end;

  TPaintToolClass = class of TPaintTool;

{ The pixel a continuous coordinate falls in. }
function PixelOf(Coordinate: Double): LongInt;

implementation

uses
  Math,
  Abi.SystemCalls,
  Image.Areas,
  Image.Surfaces,
  Controls.Keys;

function PixelOf(Coordinate: Double): LongInt;
begin
  Result := Floor(Coordinate);
end;

constructor TPaintTool.Create(ASession: TPaintSession);
begin
  inherited Create;
  FSession := ASession;
end;

destructor TPaintTool.Destroy;
begin
  FBefore.Free;
  inherited Destroy;
end;

function TPaintTool.Image: TImage;
begin
  Result := FSession.Document.Image;
end;

procedure TPaintTool.BeginEdit;
begin
  FBefore.Free;
  FBefore := Image.Clone;
  FDirty := MakeRectangle(0, 0, 0, 0);
end;

function TPaintTool.Editing: Boolean;
begin
  Result := FBefore <> nil;
end;

procedure TPaintTool.Touch(const Area: TRectangle);
var
  Inside: TRectangle;
begin
  Inside := ClipToImage(Image, Area);
  if RectangleIsEmpty(Inside) then
    Exit;
  FDirty := BoundingRectangle(FDirty, Inside);
  FSession.ImageChanged(Inside);
end;

procedure TPaintTool.RestoreArea(const Area: TRectangle);
var
  Inside: TRectangle;
  Part: TImage;
begin
  if FBefore = nil then
    Exit;
  Inside := ClipToImage(Image, Area);
  if RectangleIsEmpty(Inside) then
    Exit;
  Part := CopyImageArea(FBefore, Inside);
  try
    PutImage(Image, Part, Inside.Left, Inside.Top);
  finally
    Part.Free;
  end;
  FSession.ImageChanged(Inside);
end;

procedure TPaintTool.CommitEdit(const Description: string);
begin
  if FBefore = nil then
    Exit;
  FSession.Document.RecordAreaChange(FBefore, FDirty, Description);
  FBefore.Free;
  FBefore := nil;
  FDirty := MakeRectangle(0, 0, 0, 0);
end;

procedure TPaintTool.CancelEdit;
begin
  if FBefore = nil then
    Exit;
  RestoreArea(FDirty);
  FBefore.Free;
  FBefore := nil;
  FDirty := MakeRectangle(0, 0, 0, 0);
end;

function TPaintTool.ImageCanvas: TCanvas;
begin
  BeginCanvas(Result, ImageSurface(Image));
end;

function TPaintTool.ColorFor(Button: LongWord): TColor;
begin
  if Button = ButtonRight then
    Result := FSession.SecondaryColor
  else
    Result := FSession.PrimaryColor;
end;

function TPaintTool.OtherColorFor(Button: LongWord): TColor;
begin
  if Button = ButtonRight then
    Result := FSession.PrimaryColor
  else
    Result := FSession.SecondaryColor;
end;

procedure TPaintTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
begin
end;

procedure TPaintTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
end;

procedure TPaintTool.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
begin
end;

function TPaintTool.KeyDown(Code, Modifiers: LongWord): Boolean;
begin
  Result := False;
  if (Code = KeyEscape) and Busy then
  begin
    Cancel;
    Result := True;
  end
  else if IsEnterKey(Code) and Busy then
  begin
    Finish;
    Result := True;
  end;
end;

procedure TPaintTool.Finish;
begin
  CommitEdit('Draw');
end;

procedure TPaintTool.Cancel;
begin
  CancelEdit;
end;

function TPaintTool.Busy: Boolean;
begin
  Result := Editing;
end;

procedure TPaintTool.DrawOverlay(const Canvas: TCanvas; const Mapping: TViewMapping);
begin
end;

end.

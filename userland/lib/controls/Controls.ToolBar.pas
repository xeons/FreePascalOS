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
  Toolbars: a strip of flat buttons along the top of a window.

  A tool button shows its picture from the toolbar's image list
  (Images, ImageIndex) and its text beside it (either may be left out,
  or OnPaint may draw it); a hint (Hint) says what it does. It looks
  raised while the pointer is over it, pressed while held, and clicks
  when let go on it, or on Alt and its mnemonic ("&Bold"). A toggle
  button stays down until clicked again (Down). Separators are gaps
  with an etched line.
}
unit Controls.ToolBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList;

type
  TToolButton = class(TControl)
  private
    FHovered: Boolean;
    FHeld: Boolean;
    FIsToggle: Boolean;
    FDown: Boolean;
    FIsSeparator: Boolean;
    FImageIndex: LongInt;
    procedure SetDown(Value: Boolean);
    procedure SetImageIndex(Value: LongInt);
    function Images: TImageList;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    property IsToggle: Boolean read FIsToggle write FIsToggle;
    property Down: Boolean read FDown write SetDown;
    property IsSeparator: Boolean read FIsSeparator;
    { Its picture in the toolbar's Images (-1, the default: none). }
    property ImageIndex: LongInt read FImageIndex write SetImageIndex;
  end;

  TToolBar = class(TControl)
  private
    FNextLeft: LongInt;
    FImages: TImageList;
    procedure SetImages(Value: TImageList);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { A button of Width logical units after the last. }
    function AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent = nil): TToolButton;
    { The same with picture ImageIndex of Images, and a hint. }
    function AddImageButton(ImageIndex: LongInt; const AText, AHint: string; Width: LongInt;
      AOnClick: TControlEvent = nil): TToolButton;
    procedure AddSeparator;
    { The buttons' pictures (shared: the toolbar does not own it). }
    property Images: TImageList read FImages write SetImages;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Icons,
  Controls.Text;

const
  ToolBarHeight = 26;
  ButtonHeight = 22;
  SeparatorWidth = 8;

procedure TToolButton.SetDown(Value: Boolean);
begin
  if FDown = Value then
    Exit;
  FDown := Value;
  Invalidate;
  Changed;
end;

constructor TToolButton.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FImageIndex := -1;
end;

procedure TToolButton.SetImageIndex(Value: LongInt);
begin
  FImageIndex := Value;
  Invalidate;
end;

function TToolButton.Images: TImageList;
begin
  Result := nil;
  if Parent is TToolBar then
    Result := TToolBar(Parent).Images;
  if (Result <> nil) and not Result.ValidIndex(FImageIndex) then
    Result := nil;
end;

procedure TToolButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Shift: LongInt;
  Pictures: TImageList;
  ImageBox: TRectangle;
  ImageSize: LongInt;
  State: TImageDrawState;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FIsSeparator then
  begin
    DrawVerticalLine(Canvas, RectangleWidth(Box) div 2 - 1, 2, RectangleHeight(Box) - 2, Theme.Shadow);
    DrawVerticalLine(Canvas, RectangleWidth(Box) div 2, 2, RectangleHeight(Box) - 2, Theme.Highlight);
    Exit;
  end;
  Shift := 0;
  if (FHeld and FHovered) or FDown then
  begin
    if FDown and not FHeld then
      FillRectangle(Canvas, Box, Theme.Light);
    DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
    Shift := 1;
  end
  else if FHovered and Enabled then
    DrawEdge(Canvas, Box, Theme.Highlight, Theme.Shadow);
  Pictures := Images;
  if Pictures <> nil then
  begin
    { The picture at the left (in the middle without a text), the text
      in what is left. }
    ImageSize := Scaled(SmallIconSize);
    if Text = '' then
      ImageBox := MakeRectangle((RectangleWidth(Box) - ImageSize) div 2, (RectangleHeight(Box) - ImageSize) div 2,
        ImageSize, ImageSize)
    else
      ImageBox := MakeRectangle(Scaled(3), (RectangleHeight(Box) - ImageSize) div 2, ImageSize, ImageSize);
    State := ImageDrawNormal;
    if not Enabled then
      State := ImageDrawDisabled;
    Pictures.DrawInBox(Canvas, FImageIndex, OffsetRectangle(ImageBox, Shift, Shift), State);
    Box.Left := ImageBox.Right;
    if Text = '' then
      Exit;
  end;
  if Enabled then
    DrawMnemonicTextInBox(Canvas, ControlFace, Text, OffsetRectangle(InflateRectangle(Box, -Scaled(3)), Shift, Shift),
      AlignTextCenter, Theme.FaceText)
  else
    DrawDisabledMnemonicText(Canvas, ControlFace, Text, Box.Left + (RectangleWidth(Box) -
      MnemonicTextWidth(ControlFace, Text)) div 2, (RectangleHeight(Box) - TextHeight(ControlFace)) div 2);
end;

function TToolButton.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := not FIsSeparator and TextMatchesMnemonic(Character);
end;

procedure TToolButton.ActivateMnemonic(Character: LongWord);
begin
  if FIsToggle then
    Down := not FDown;
  Click;
end;

procedure TToolButton.PointerEnter;
begin
  FHovered := True;
  Invalidate;
end;

procedure TToolButton.PointerLeave;
begin
  FHovered := False;
  Invalidate;
end;

procedure TToolButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or FIsSeparator then
    Exit;
  FHeld := True;
  Invalidate;
end;

procedure TToolButton.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Inside: Boolean;
begin
  if not FHeld then
    Exit;
  FHeld := False;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  FHovered := Inside;
  Invalidate;
  if not Inside then
    Exit;
  if FIsToggle then
    Down := not FDown;
  Click;
end;

constructor TToolBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, 0, ToolBarHeight);
  Align := AlignTop;
  FNextLeft := 2;
end;

procedure TToolBar.SetImages(Value: TImageList);
var
  Index: LongInt;
begin
  FImages := Value;
  for Index := 0 to ChildCount - 1 do
    Children[Index].Invalidate;
end;

function TToolBar.AddImageButton(ImageIndex: LongInt; const AText, AHint: string; Width: LongInt;
  AOnClick: TControlEvent): TToolButton;
begin
  Result := AddButton(AText, Width, AOnClick);
  Result.ImageIndex := ImageIndex;
  Result.Hint := AHint;
end;

function TToolBar.AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent): TToolButton;
begin
  Result := TToolButton.Create(Self);
  Result.Text := AText;
  Result.OnClick := AOnClick;
  Result.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, Width, ButtonHeight);
  FNextLeft := FNextLeft + Width + 1;
end;

procedure TToolBar.AddSeparator;
var
  Separator: TToolButton;
begin
  Separator := TToolButton.Create(Self);
  Separator.FIsSeparator := True;
  Separator.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, SeparatorWidth, ButtonHeight);
  FNextLeft := FNextLeft + SeparatorWidth;
end;

procedure TToolBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2, Theme.Shadow);
  DrawHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 1, Theme.Highlight);
end;

end.

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
  The colour box along the bottom: the primary and secondary colours
  (the primary's square over the secondary's; a click swaps them), the
  palette (two rows of swatches in a table: a left click makes a
  swatch's colour the primary, a right click the secondary, a double
  click changes the swatch through the colour dialog), and a button
  that changes the primary colour through the colour dialog. They flow
  in a row (a flow layout panel), wrapping when the window is narrow.
}
unit Paint.ColorBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Controls.Base,
  Controls.Panels,
  Controls.FlowPanel,
  Controls.TablePanel,
  Controls.Buttons,
  Paint.Session;

const
  PaletteColumns = 14;
  PaletteRows = 2;
  PaletteSize = PaletteColumns * PaletteRows;
  DefaultPalette: array[0..PaletteSize - 1] of TColor = (
    $FF000000, $FF808080, $FF800000, $FF808000, $FF008000, $FF008080, $FF000080, $FF800080, $FF808040,
    $FF004040, $FF0080FF, $FF004080, $FF8000FF, $FF804000,
    $FFFFFFFF, $FFC0C0C0, $FFFF0000, $FFFFFF00, $FF00FF00, $FF00FFFF, $FF0000FF, $FFFF00FF, $FFFFFF80,
    $FF00FF80, $FF80FFFF, $FF8080FF, $FFFF0080, $FFFF8040);

type
  TPaletteSwatch = class;
  TSwatchEvent = procedure(Swatch: TPaletteSwatch; Button: LongWord) of object;

  TPaletteSwatch = class(TControl)
  private
    FColor: TColor;
    FLastClick: QWord;
    FOnPicked: TSwatchEvent;
    FOnEditWanted: TSwatchEvent;
    procedure SetColor(Value: TColor);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    property Color: TColor read FColor write SetColor;
    property OnPicked: TSwatchEvent read FOnPicked write FOnPicked;
    property OnEditWanted: TSwatchEvent read FOnEditWanted write FOnEditWanted;
  end;

  { The primary colour's square over the secondary's. }
  TCurrentColors = class(TControl)
  private
    FSession: TPaintSession;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  end;

  TColorBoxEvent = procedure of object;

  TColorBox = class(TPanel)
  private
    FSession: TPaintSession;
    FCurrent: TCurrentColors;
    FSwatches: array[0..PaletteSize - 1] of TPaletteSwatch;
    FEditButton: TButton;
    FOnEditPrimary: TColorBoxEvent;
    procedure SwatchPicked(Swatch: TPaletteSwatch; Button: LongWord);
    procedure SwatchEditWanted(Swatch: TPaletteSwatch; Button: LongWord);
    procedure EditClicked(Sender: TControl);
  public
    constructor Create(AParent: TControl); override;
    procedure AttachSession(ASession: TPaintSession);
    { The current colours changed. }
    procedure ShowColors;
    function Swatch(Index: LongInt): TPaletteSwatch;
    property OnEditPrimary: TColorBoxEvent read FOnEditPrimary write FOnEditPrimary;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Connection,
  Windowing.Theme,
  Controls.LayoutRules,
  Controls.TableArrangement,
  Controls.Timers,
  Controls.ColorDialog,
  Paint.ViewRendering;

const
  { Logical units. }
  SwatchSide = 16;
  CurrentSide = 34;
  DoubleClickMilliseconds = 500;

{ A colour in Box, over the checkerboard where it is not opaque. }
procedure FillColorBox(const Canvas: TCanvas; const Box: TRectangle; Color: TColor);
begin
  if AlphaOf(Color) = AlphaOpaque then
    FillRectangle(Canvas, Box, Color)
  else
  begin
    FillRectangle(Canvas, Box, CheckerLight);
    FillRectangle(Canvas, Box, Color);
  end;
end;

{ --- Swatches -------------------------------------------------------------------------------- }

procedure TPaletteSwatch.SetColor(Value: TColor);
begin
  FColor := Value;
  Invalidate;
end;

procedure TPaletteSwatch.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  FillColorBox(Canvas, InflateRectangle(Box, -2), FColor);
end;

procedure TPaletteSwatch.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Now: QWord;
begin
  if (X < 0) or (Y < 0) or (X >= RectangleWidth(PixelBounds)) or (Y >= RectangleHeight(PixelBounds)) then
    Exit;
  Now := TimerClock;
  if (Button = ButtonLeft) and (FLastClick <> 0) and (Now - FLastClick <= DoubleClickMilliseconds) then
  begin
    FLastClick := 0;
    if Assigned(FOnEditWanted) then
      FOnEditWanted(Self, Button);
    Exit;
  end;
  if Button = ButtonLeft then
    FLastClick := Now
  else
    FLastClick := 0;
  if Assigned(FOnPicked) then
    FOnPicked(Self, Button);
end;

{ --- The current colours -------------------------------------------------------------------- }

procedure TCurrentColors.Paint(var Canvas: TCanvas);
var
  Side: LongInt;
  Square: LongInt;
  Back: TRectangle;
  Front: TRectangle;
begin
  if FSession = nil then
    Exit;
  Side := RectangleWidth(PixelBounds);
  Square := Side * 2 div 3;
  Back := MakeRectangle(Side - Square, Side - Square, Square, Square);
  Front := MakeRectangle(0, 0, Square, Square);
  DrawBevel(Canvas, Back, RaisedThemeBevel);
  FillColorBox(Canvas, InflateRectangle(Back, -2), FSession.SecondaryColor);
  DrawBevel(Canvas, Front, RaisedThemeBevel);
  FillColorBox(Canvas, InflateRectangle(Front, -2), FSession.PrimaryColor);
end;

procedure TCurrentColors.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (FSession <> nil) and (Button = ButtonLeft) then
    FSession.SwapColors;
end;

{ --- The box --------------------------------------------------------------------------------- }

constructor TColorBox.Create(AParent: TControl);
var
  Flow: TFlowLayoutPanel;
  Palette: TTableLayoutPanel;
  Index: LongInt;
begin
  inherited Create(AParent);
  Flow := TFlowLayoutPanel.Create(Self);
  Flow.Align := AlignTop;
  Flow.AutoSize := True;
  Flow.ContentPadding := UniformSpacing(3);
  FCurrent := TCurrentColors.Create(Flow);
  FCurrent.SetBounds(0, 0, CurrentSide, CurrentSide);
  FCurrent.Margins := MakeSpacing(0, 0, 6, 0);
  FCurrent.Hint := 'The primary colour (left button) over the secondary (right button); click to swap them';
  Palette := TTableLayoutPanel.Create(Flow);
  Palette.AutoSize := True;
  Palette.Margins := MakeSpacing(0, 0, 6, 0);
  for Index := 1 to PaletteColumns do
    Palette.AddColumn(TrackAbsolute, SwatchSide);
  for Index := 1 to PaletteRows do
    Palette.AddRow(TrackAbsolute, SwatchSide + 1);
  for Index := 0 to PaletteSize - 1 do
  begin
    FSwatches[Index] := TPaletteSwatch.Create(Palette);
    FSwatches[Index].Align := AlignClient;
    FSwatches[Index].Color := DefaultPalette[Index];
    FSwatches[Index].Hint := 'Left click: primary colour, right click: secondary, double click: change it';
    FSwatches[Index].OnPicked := @SwatchPicked;
    FSwatches[Index].OnEditWanted := @SwatchEditWanted;
    Palette.SetCell(FSwatches[Index], Index mod PaletteColumns, Index div PaletteColumns);
  end;
  FEditButton := TButton.Create(Flow);
  FEditButton.Text := 'E&dit colours...';
  FEditButton.AutoSize := True;
  FEditButton.OnClick := @EditClicked;
end;

procedure TColorBox.AttachSession(ASession: TPaintSession);
begin
  FSession := ASession;
  FCurrent.FSession := ASession;
  ShowColors;
end;

procedure TColorBox.ShowColors;
begin
  FCurrent.Invalidate;
end;

function TColorBox.Swatch(Index: LongInt): TPaletteSwatch;
begin
  Result := FSwatches[Index];
end;

procedure TColorBox.SwatchPicked(Swatch: TPaletteSwatch; Button: LongWord);
begin
  if FSession = nil then
    Exit;
  if Button = ButtonRight then
    FSession.SecondaryColor := Swatch.Color
  else
    FSession.PrimaryColor := Swatch.Color;
end;

procedure TColorBox.SwatchEditWanted(Swatch: TPaletteSwatch; Button: LongWord);
var
  Color: TColor;
begin
  Color := Swatch.Color;
  if not ChooseColor(Color) then
    Exit;
  Swatch.Color := Color;
  if FSession <> nil then
    FSession.PrimaryColor := Color;
end;

procedure TColorBox.EditClicked(Sender: TControl);
begin
  if Assigned(FOnEditPrimary) then
    FOnEditPrimary();
end;

end.

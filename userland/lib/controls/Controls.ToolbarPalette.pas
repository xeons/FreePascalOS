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
  The palette a toolbox is customized with (Controls.CustomToolBars):
  a panel listing the items not on any toolbar - each a picture with
  its caption, then a separator, a space and a flexible space - which
  are dragged onto a toolbar to add them; an item dragged from a toolbar
  onto the palette is taken off. Along its bottom: how the buttons show
  (icons, icons and text, text), small icons, Restore Default Set and
  Done. The program shows it (docked under the toolbars, say) after
  TToolbox.BeginCustomize, and hears the choices through its events.
}
unit Controls.ToolbarPalette;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.DragData,
  Controls.Labels,
  Controls.Buttons,
  Controls.Toggles,
  Controls.ComboBox,
  Controls.CustomToolBars;

type
  TToolbarPalette = class(TControl)
  private
    FToolbox: TToolbox;
    FCaption: TLabel;
    FShowLabel: TLabel;
    FShowBox: TComboBox;
    FSmallIcons: TCheckBox;
    FRestore: TButton;
    FDone: TButton;
    FPressIndex: LongInt;
    FPressX, FPressY: LongInt;
    FDropHighlight: Boolean;
    FOnModeChanged: TControlEvent;
    FOnSmallIconsChanged: TControlEvent;
    FOnDone: TControlEvent;
    function TileBox(Index: LongInt): TRectangle;
    function TileAt(X, Y: LongInt): LongInt;
    function TileArea: TRectangle;
    procedure PaintTile(var Canvas: TCanvas; const Id: string; const Box: TRectangle);
    procedure ModeChosen(Sender: TControl);
    procedure SmallIconsClicked(Sender: TControl);
    procedure RestoreClicked(Sender: TControl);
    procedure DoneClicked(Sender: TControl);
    function GetMode: LongInt;
    procedure SetMode(Value: LongInt);
    function GetSmallIcons: Boolean;
    procedure SetSmallIcons(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
  public
    constructor CreateFor(AParent: TControl; AToolbox: TToolbox);
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    { 0 icons, 1 icons and text, 2 text. }
    property Mode: LongInt read GetMode write SetMode;
    property SmallIcons: Boolean read GetSmallIcons write SetSmallIcons;
    property Toolbox: TToolbox read FToolbox;
    property OnModeChanged: TControlEvent read FOnModeChanged write FOnModeChanged;
    property OnSmallIconsChanged: TControlEvent read FOnSmallIconsChanged write FOnSmallIconsChanged;
    { Done was pressed (the program ends customizing and hides it). }
    property OnDone: TControlEvent read FOnDone write FOnDone;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Math,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Painting,
  Controls.LayoutRules;

const
  TileWidth = 92;
  TileHeight = 58;
  TileGap = 4;
  TileIconSize = 24;
  CaptionHeight = 26;
  BottomRowHeight = 34;
  PaletteHeight = 200;
  DragThreshold = 4;

constructor TToolbarPalette.CreateFor(AParent: TControl; AToolbox: TToolbox);
begin
  inherited Create(AParent);
  FToolbox := AToolbox;
  FToolbox.Palette := Self;
  FPressIndex := -1;
  FCaption := TLabel.Create(Self);
  FCaption.Text := 'Drag items to or from the toolbars to arrange them as you like.';
  FCaption.SetBounds(8, 6, 600, 18);
  FShowLabel := TLabel.Create(Self);
  FShowLabel.Text := '&Show:';
  FShowLabel.SetBounds(8, PaletteHeight - BottomRowHeight + 9, 44, 18);
  FShowLabel.Anchors := [akLeft, akBottom];
  FShowBox := TComboBox.Create(Self);
  FShowBox.Items.Add('Icons');
  FShowBox.Items.Add('Icons and Text');
  FShowBox.Items.Add('Text');
  FShowBox.ItemIndex := 0;
  FShowBox.SetBounds(54, PaletteHeight - BottomRowHeight + 5, 140, 22);
  FShowBox.Anchors := [akLeft, akBottom];
  FShowBox.OnChange := @ModeChosen;
  FSmallIcons := TCheckBox.Create(Self);
  FSmallIcons.Text := 'Use Small &Icons';
  FSmallIcons.SetBounds(206, PaletteHeight - BottomRowHeight + 7, 150, 20);
  FSmallIcons.Anchors := [akLeft, akBottom];
  FSmallIcons.OnClick := @SmallIconsClicked;
  FDone := TButton.Create(Self);
  FDone.Text := '&Done';
  FDone.SetBounds(600 - 8 - 80, PaletteHeight - BottomRowHeight + 4, 80, 24);
  FDone.Anchors := [akRight, akBottom];
  FDone.OnClick := @DoneClicked;
  FRestore := TButton.Create(Self);
  FRestore.Text := '&Restore Default Set';
  FRestore.SetBounds(600 - 8 - 80 - 8 - 150, PaletteHeight - BottomRowHeight + 4, 150, 24);
  FRestore.Anchors := [akRight, akBottom];
  FRestore.OnClick := @RestoreClicked;
  SetBounds(0, 0, 600, PaletteHeight);
end;

destructor TToolbarPalette.Destroy;
begin
  if FToolbox.Palette = Self then
    FToolbox.Palette := nil;
  inherited Destroy;
end;

function TToolbarPalette.PreferredSize: TSize;
begin
  Result := MakeSize(600, PaletteHeight);
end;

function TToolbarPalette.GetMode: LongInt;
begin
  Result := Max(0, FShowBox.ItemIndex);
end;

procedure TToolbarPalette.SetMode(Value: LongInt);
begin
  FShowBox.ItemIndex := EnsureRange(Value, 0, 2);
end;

function TToolbarPalette.GetSmallIcons: Boolean;
begin
  Result := FSmallIcons.Checked;
end;

procedure TToolbarPalette.SetSmallIcons(Value: Boolean);
begin
  FSmallIcons.Checked := Value;
end;

procedure TToolbarPalette.ModeChosen(Sender: TControl);
begin
  if Assigned(FOnModeChanged) then
    FOnModeChanged(Self);
end;

procedure TToolbarPalette.SmallIconsClicked(Sender: TControl);
begin
  if Assigned(FOnSmallIconsChanged) then
    FOnSmallIconsChanged(Self);
end;

procedure TToolbarPalette.RestoreClicked(Sender: TControl);
begin
  FToolbox.RestoreDefaults;
  Invalidate;
end;

procedure TToolbarPalette.DoneClicked(Sender: TControl);
begin
  if Assigned(FOnDone) then
    FOnDone(Self);
end;

{ Pixels of this control. }
function TToolbarPalette.TileArea: TRectangle;
begin
  Result := MakeRectangle(Scaled(8), Scaled(CaptionHeight), RectangleWidth(PixelBounds) - Scaled(16),
    RectangleHeight(PixelBounds) - Scaled(CaptionHeight + BottomRowHeight));
end;

function TToolbarPalette.TileBox(Index: LongInt): TRectangle;
var
  Area: TRectangle;
  PerRow, Column, Row: LongInt;
begin
  Area := TileArea;
  PerRow := Max(1, RectangleWidth(Area) div Scaled(TileWidth + TileGap));
  Column := Index mod PerRow;
  Row := Index div PerRow;
  Result := MakeRectangle(Area.Left + Column * Scaled(TileWidth + TileGap), Area.Top + Row * Scaled(TileHeight +
    TileGap), Scaled(TileWidth), Scaled(TileHeight));
end;

function TToolbarPalette.TileAt(X, Y: LongInt): LongInt;
var
  Items: TStringArray;
  Index: LongInt;
begin
  Items := FToolbox.UnplacedItems;
  for Index := 0 to High(Items) do
    if RectangleContainsPoint(TileBox(Index), X, Y) then
      Exit(Index);
  Result := -1;
end;

procedure TToolbarPalette.PaintTile(var Canvas: TCanvas; const Id: string; const Box: TRectangle);
var
  Definition: TToolbarItemDefinition;
  Caption: string;
  Icon, TextBox: TRectangle;
  Size, Middle: LongInt;
begin
  Size := Scaled(TileIconSize);
  Icon := MakeRectangle(Box.Left + (RectangleWidth(Box) - Size) div 2, Box.Top + Scaled(6), Size, Size);
  Definition := FToolbox.Definition(Id);
  if Definition <> nil then
  begin
    Caption := Definition.Caption;
    if (FToolbox.Images <> nil) and FToolbox.Images.ValidIndex(Definition.ImageIndex) then
      FToolbox.Images.DrawInBox(Canvas, Definition.ImageIndex, Icon)
    else
    begin
      { An item without a picture (an address bar): a field. }
      FillRectangle(Canvas, MakeRectangle(Box.Left + Scaled(10), Icon.Top + Size div 4, RectangleWidth(Box) -
        Scaled(20), Size div 2), Theme.Field);
      DrawSunkenEdge(Canvas, MakeRectangle(Box.Left + Scaled(10), Icon.Top + Size div 4, RectangleWidth(Box) -
        Scaled(20), Size div 2));
    end;
  end
  else
  begin
    Caption := BuiltInItemCaption(Id);
    Middle := (Icon.Left + Icon.Right) div 2;
    if Id = ToolbarSeparatorId then
      DrawEtchedVerticalLine(Canvas, Middle, Icon.Top, Icon.Bottom)
    else
      DrawDottedOutline(Canvas, MakeRectangle(Box.Left + Scaled(14), Icon.Top + Size div 4, RectangleWidth(Box) -
        Scaled(28), Size div 2), Theme.Shadow);
  end;
  TextBox := MakeRectangle(Box.Left, Icon.Bottom + Scaled(4), RectangleWidth(Box), Box.Bottom - Icon.Bottom -
    Scaled(4));
  DrawTextInBox(Canvas, ControlFace, Caption, TextBox, AlignTextCenter, Theme.FaceText);
end;

procedure TToolbarPalette.Paint(var Canvas: TCanvas);
var
  Box, Area: TRectangle;
  Items: TStringArray;
  Index: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  Area := TileArea;
  FillRectangle(Canvas, Area, Theme.Field);
  DrawSunkenEdge(Canvas, Area);
  if FDropHighlight then
    DrawThickOutline(Canvas, Area, Max(2, Scaled(2)), Theme.Selection);
  Items := FToolbox.UnplacedItems;
  for Index := 0 to High(Items) do
    PaintTile(Canvas, Items[Index], TileBox(Index));
  DrawEtchedHorizontalLine(Canvas, 0, Box.Right, 0);
end;

procedure TToolbarPalette.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  FPressIndex := -1;
  if Button <> ButtonLeft then
    Exit;
  FPressIndex := TileAt(X, Y);
  FPressX := X;
  FPressY := Y;
end;

procedure TToolbarPalette.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Items: TStringArray;
  Index: LongInt;
begin
  inherited PointerMove(X, Y, Buttons);
  if (FPressIndex < 0) or ((Buttons and ButtonLeft) = 0) then
    Exit;
  if (Abs(X - FPressX) < Scaled(DragThreshold)) and (Abs(Y - FPressY) < Scaled(DragThreshold)) then
    Exit;
  Items := FToolbox.UnplacedItems;
  Index := FPressIndex;
  FPressIndex := -1;
  if Index > High(Items) then
    Exit;
  BeginDrag(TDragData.Create(DragFormatToolbarItem, EncodeToolbarDrag('', -1, Items[Index]), Self));
end;

procedure TToolbarPalette.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FPressIndex := -1;
end;

function TToolbarPalette.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Info: TToolbarDragInfo;
begin
  { Only items from a toolbar: they are taken off it here. }
  if (Data.Format = DragFormatToolbarItem) and DecodeToolbarDrag(Data.Text, Info) and (Info.ToolbarName <> '') then
  begin
    if not FDropHighlight then
    begin
      FDropHighlight := True;
      Invalidate;
    end;
    Exit(DropMove);
  end;
  Result := inherited DragOver(Data, X, Y, Modifiers);
end;

procedure TToolbarPalette.DragLeave;
begin
  if FDropHighlight then
  begin
    FDropHighlight := False;
    Invalidate;
  end;
  inherited DragLeave;
end;

procedure TToolbarPalette.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Info: TToolbarDragInfo;
  Source: TCustomToolBar;
begin
  FDropHighlight := False;
  Invalidate;
  if not ((Data.Format = DragFormatToolbarItem) and DecodeToolbarDrag(Data.Text, Info)) then
  begin
    inherited DragDrop(Data, X, Y, Effect);
    Exit;
  end;
  Source := FToolbox.ToolbarByName(Info.ToolbarName);
  if (Source = nil) or (Info.Index < 0) or (Info.Index >= Source.ItemCount) or (Source.ItemIds[Info.Index] <> Info.Id) then
    Exit;
  Source.RemoveItem(Info.Index);
  FToolbox.ArrangementChanged;
end;

end.

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
  Toolbars the user arranges: a toolbox (TToolbox) holds rows of
  customizable toolbars (TCustomToolBar), each a list of items by id in
  order ("back,forward,reload,location"). The program defines the items
  it has (DefineItem: a caption and a picture for the palette, whether it
  stretches to share the room left) and makes each one's control when a
  toolbar shows it (OnCreateItem); three items every toolbox has are a
  separator, a space and a flexible space ("spring").

  Items are laid out in a row: fixed ones at their size, flexible ones
  sharing what is left by weight (an address bar 4, a search box 1).

  While customizing (BeginCustomize) the items stop working: a cover
  over each toolbar outlines them and lets them be dragged, within a
  toolbar, to another one, or to the palette (Controls.ToolbarPalette:
  the items not shown, which are dragged onto a toolbar to add them).
  OnChanged tells the program the arrangement changed (to keep it).
}
unit Controls.CustomToolBars;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Drawing.Colors,
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.DragData,
  Controls.ImageList;

const
  DragFormatToolbarItem = 'toolbar-item';
  ToolbarSeparatorId = 'separator';
  ToolbarSpaceId = 'space';
  ToolbarSpringId = 'spring';

type
  TToolbox = class;
  TCustomToolBar = class;

  TToolbarItemDefinition = class
  public
    Id: string;
    Caption: string;
    { In the toolbox's Images (-1: none). }
    ImageIndex: LongInt;
    { Shares the room left over, by FlexWeight; never narrower than
      MinimumWidth (logical units). }
    Flexible: Boolean;
    FlexWeight: LongInt;
    MinimumWidth: LongInt;
  end;

  TCreateToolbarItemEvent = function(Toolbar: TCustomToolBar; const Id: string): TControl of object;

  { What dragging an item carries (TDragData.Text): where it comes from
    (a toolbar's name and the item's place there, or the palette) and
    its id. }
  TToolbarDragInfo = record
    ToolbarName: string;
    Index: LongInt;
    Id: string;
  end;

  TCustomToolBar = class(TControl)
  private
    FToolbox: TToolbox;
    FName: string;
    FDefaultItems: string;
    FIds: TStringList;
    FCover: TControl;
    FDropIndex: LongInt;
    function GetItemControl(Index: LongInt): TControl;
    function GetItemId(Index: LongInt): string;
    function CreateItemControl(const Id: string): TControl;
    function IsFlexible(Index: LongInt): Boolean;
    function WeightOf(Index: LongInt): LongInt;
    function MinimumOf(Index: LongInt): LongInt;
    procedure SetDropIndex(Value: LongInt);
    procedure UpdateCover;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PlaceChildren(const Area: TRectangle); override;
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
    function CountsInExtent(Child: TControl): Boolean; override;
  public
    constructor CreateIn(AToolbox: TToolbox; const AName, ADefaultItems: string);
    destructor Destroy; override;
    { The items, comma separated ids (unknown ones are left out). }
    procedure SetItems(const Ids: string);
    function Items: string;
    function ItemCount: LongInt;
    function IndexOfId(const Id: string): LongInt;
    function IndexOfControl(Control: TControl): LongInt;
    procedure InsertItem(const Id: string; Index: LongInt);
    procedure RemoveItem(Index: LongInt);
    { Makes every item's control again (the program's look changed). }
    procedure RebuildItems;
    { The item under X (own pixels), and where an item dropped at X goes. }
    function ItemAt(X: LongInt): LongInt;
    function DropIndexAt(X: LongInt): LongInt;
    function PreferredSize: TSize; override;
    property Toolbox: TToolbox read FToolbox;
    property Name: string read FName;
    property DefaultItems: string read FDefaultItems;
    property ItemIds[Index: LongInt]: string read GetItemId;
    property ItemControls[Index: LongInt]: TControl read GetItemControl;
    { Where a drag would put an item (-1: none), drawn while customizing. }
    property DropIndex: LongInt read FDropIndex write SetDropIndex;
  end;

  TToolbox = class(TControl)
  private
    FDefinitions: TList;
    FToolbars: TList;
    FCustomizing: Boolean;
    FImages: TImageList;
    FOnCreateItem: TCreateToolbarItemEvent;
    FOnChanged: TControlEvent;
    FPalette: TControl;
    function GetToolbar(Index: LongInt): TCustomToolBar;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure DefineItem(const Id, Caption: string; ImageIndex: LongInt; Flexible: Boolean = False;
      FlexWeight: LongInt = 1; MinimumWidth: LongInt = 0);
    function Definition(const Id: string): TToolbarItemDefinition;
    { A new toolbar at the bottom of the toolbox. }
    function AddToolbar(const Name, DefaultItems: string): TCustomToolBar;
    function ToolbarByName(const Name: string): TCustomToolBar;
    function ToolbarCount: LongInt;
    { Whether item Id is on a toolbar (separators and spaces never count). }
    function IsPlaced(const Id: string): Boolean;
    { What the palette offers: the items on no toolbar, then a separator,
      a space and a flexible space. }
    function UnplacedItems: TStringArray;
    procedure BeginCustomize;
    procedure EndCustomize;
    { Every toolbar's default items back. }
    procedure RestoreDefaults;
    procedure RebuildItems;
    { An item moved: lays out, repaints the palette, tells OnChanged. }
    procedure ArrangementChanged;
    function PreferredSize: TSize; override;
    property Toolbars[Index: LongInt]: TCustomToolBar read GetToolbar;
    property Customizing: Boolean read FCustomizing;
    { The items' pictures for the palette (shared, not owned). }
    property Images: TImageList read FImages write FImages;
    { The palette open while customizing (it sets this itself). }
    property Palette: TControl read FPalette write FPalette;
    property OnCreateItem: TCreateToolbarItemEvent read FOnCreateItem write FOnCreateItem;
    property OnChanged: TControlEvent read FOnChanged write FOnChanged;
  end;

{ The text a drag of an item carries, and reading it back. }
function EncodeToolbarDrag(const ToolbarName: string; Index: LongInt; const Id: string): string;
function DecodeToolbarDrag(const Text: string; out Info: TToolbarDragInfo): Boolean;
{ A caption for the three items every toolbox has ('' for others). }
function BuiltInItemCaption(const Id: string): string;
{ Whether Id is a separator, a space or a flexible space. }
function IsBuiltInItem(const Id: string): Boolean;
{ A dotted outline (customizing). }
procedure DrawDottedOutline(const Canvas: TCanvas; const Box: TRectangle; Color: TColor);

implementation

uses
  Controls.LayoutRules,
  Abi.SystemCalls,
  Math,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Painting;

const
  ToolbarPadding = 2;
  SpaceWidth = 12;
  SeparatorWidth = 8;
  SpringMinimumWidth = 12;
  DragThreshold = 4;

type
  { A separator, a space or a flexible space. }
  TToolbarSpacer = class(TControl)
  private
    FKind: string;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    function PreferredSize: TSize; override;
  end;

  { Over a toolbar while customizing: outlines the items, starts drags. }
  TCustomizeCover = class(TControl)
  private
    FToolbar: TCustomToolBar;
    FPressIndex: LongInt;
    FPressX, FPressY: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  end;

function EncodeToolbarDrag(const ToolbarName: string; Index: LongInt; const Id: string): string;
begin
  Result := ToolbarName + #9 + IntToStr(Index) + #9 + Id;
end;

function DecodeToolbarDrag(const Text: string; out Info: TToolbarDragInfo): Boolean;
var
  Fields: TStringArray;
begin
  Info := Default(TToolbarDragInfo);
  Fields := Text.Split([#9]);
  if Length(Fields) <> 3 then
    Exit(False);
  Info.ToolbarName := Fields[0];
  Info.Index := StrToIntDef(Fields[1], -1);
  Info.Id := Fields[2];
  Result := Info.Id <> '';
end;

function IsBuiltInItem(const Id: string): Boolean;
begin
  Result := (Id = ToolbarSeparatorId) or (Id = ToolbarSpaceId) or (Id = ToolbarSpringId);
end;

function BuiltInItemCaption(const Id: string): string;
begin
  if Id = ToolbarSeparatorId then
    Result := 'Separator'
  else if Id = ToolbarSpaceId then
    Result := 'Space'
  else if Id = ToolbarSpringId then
    Result := 'Flexible Space'
  else
    Result := '';
end;

procedure DrawDottedOutline(const Canvas: TCanvas; const Box: TRectangle; Color: TColor);
var
  Position: LongInt;
begin
  Position := Box.Left;
  while Position < Box.Right do
  begin
    FillRectangle(Canvas, MakeRectangle(Position, Box.Top, 1, 1), Color);
    FillRectangle(Canvas, MakeRectangle(Position, Box.Bottom - 1, 1, 1), Color);
    Inc(Position, 2);
  end;
  Position := Box.Top;
  while Position < Box.Bottom do
  begin
    FillRectangle(Canvas, MakeRectangle(Box.Left, Position, 1, 1), Color);
    FillRectangle(Canvas, MakeRectangle(Box.Right - 1, Position, 1, 1), Color);
    Inc(Position, 2);
  end;
end;

{ ---- spacers ---- }

function TToolbarSpacer.PreferredSize: TSize;
begin
  if FKind = ToolbarSeparatorId then
    Result := MakeSize(SeparatorWidth, 22)
  else if FKind = ToolbarSpaceId then
    Result := MakeSize(SpaceWidth, 22)
  else
    Result := MakeSize(SpringMinimumWidth, 22);
end;

procedure TToolbarSpacer.Paint(var Canvas: TCanvas);
var
  Width, Height: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  if FKind = ToolbarSeparatorId then
    DrawEtchedVerticalLine(Canvas, Width div 2 - BevelLine, Scaled(3), Height - Scaled(3));
end;

{ ---- the cover ---- }

procedure TCustomizeCover.Paint(var Canvas: TCanvas);
var
  Index, X: LongInt;
  Box, Own: TRectangle;
  Control: TControl;
begin
  Own := PixelBounds;
  for Index := 0 to FToolbar.ItemCount - 1 do
  begin
    Control := FToolbar.ItemControls[Index];
    Box := OffsetRectangle(Control.PixelBounds, -Own.Left, -Own.Top);
    FillRectangle(Canvas, Box, WithAlpha(Theme.Face, 90));
    DrawDottedOutline(Canvas, Box, Theme.Shadow);
  end;
  if FToolbar.DropIndex >= 0 then
  begin
    if FToolbar.DropIndex < FToolbar.ItemCount then
      X := FToolbar.ItemControls[FToolbar.DropIndex].PixelBounds.Left - Own.Left - Scaled(1)
    else if FToolbar.ItemCount > 0 then
      X := FToolbar.ItemControls[FToolbar.ItemCount - 1].PixelBounds.Right - Own.Left + Scaled(1)
    else
      X := Scaled(ToolbarPadding);
    FillRectangle(Canvas, MakeRectangle(X - Max(1, Scaled(1)), Scaled(2), Max(2, Scaled(2)),
      RectangleHeight(Own) - Scaled(4)), Theme.Selection);
  end;
end;

procedure TCustomizeCover.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  FPressIndex := -1;
  if Button <> ButtonLeft then
    Exit;
  FPressIndex := FToolbar.ItemAt(X);
  FPressX := X;
  FPressY := Y;
end;

procedure TCustomizeCover.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Index: LongInt;
begin
  inherited PointerMove(X, Y, Buttons);
  if (FPressIndex < 0) or ((Buttons and ButtonLeft) = 0) then
    Exit;
  if (Abs(X - FPressX) < Scaled(DragThreshold)) and (Abs(Y - FPressY) < Scaled(DragThreshold)) then
    Exit;
  Index := FPressIndex;
  FPressIndex := -1;
  BeginDrag(TDragData.Create(DragFormatToolbarItem, EncodeToolbarDrag(FToolbar.Name, Index,
    FToolbar.ItemIds[Index]), FToolbar));
end;

procedure TCustomizeCover.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FPressIndex := -1;
end;

{ ---- a toolbar ---- }

constructor TCustomToolBar.CreateIn(AToolbox: TToolbox; const AName, ADefaultItems: string);
begin
  inherited Create(AToolbox);
  FToolbox := AToolbox;
  FName := AName;
  FDefaultItems := ADefaultItems;
  FIds := TStringList.Create;
  FDropIndex := -1;
  Align := AlignTop;
  AutoSize := True;
end;

destructor TCustomToolBar.Destroy;
begin
  FIds.Free;
  inherited Destroy;
end;

function TCustomToolBar.GetItemControl(Index: LongInt): TControl;
begin
  Result := TControl(FIds.Objects[Index]);
end;

function TCustomToolBar.GetItemId(Index: LongInt): string;
begin
  Result := FIds[Index];
end;

function TCustomToolBar.ItemCount: LongInt;
begin
  Result := FIds.Count;
end;

function TCustomToolBar.IndexOfId(const Id: string): LongInt;
begin
  Result := FIds.IndexOf(Id);
end;

function TCustomToolBar.IndexOfControl(Control: TControl): LongInt;
begin
  Result := FIds.IndexOfObject(Control);
end;

function TCustomToolBar.CreateItemControl(const Id: string): TControl;
var
  Spacer: TToolbarSpacer;
begin
  if IsBuiltInItem(Id) then
  begin
    Spacer := TToolbarSpacer.Create(Self);
    Spacer.FKind := Id;
    Exit(Spacer);
  end;
  Result := nil;
  if (FToolbox.Definition(Id) <> nil) and Assigned(FToolbox.OnCreateItem) then
    Result := FToolbox.OnCreateItem(Self, Id);
end;

procedure TCustomToolBar.InsertItem(const Id: string; Index: LongInt);
var
  Control: TControl;
begin
  if not IsBuiltInItem(Id) and FToolbox.IsPlaced(Id) then
    Exit;
  Control := CreateItemControl(Id);
  if Control = nil then
    Exit;
  if (Index < 0) or (Index > FIds.Count) then
    Index := FIds.Count;
  FIds.InsertObject(Index, Id, Control);
  UpdateCover;
  RequestLayout;
  Invalidate;
end;

procedure TCustomToolBar.RemoveItem(Index: LongInt);
var
  Control: TControl;
begin
  if (Index < 0) or (Index >= FIds.Count) then
    Exit;
  Control := ItemControls[Index];
  FIds.Delete(Index);
  Control.Free;
  RequestLayout;
  Invalidate;
end;

procedure TCustomToolBar.SetItems(const Ids: string);
var
  Parts: TStringArray;
  Index: LongInt;
begin
  while FIds.Count > 0 do
    RemoveItem(FIds.Count - 1);
  Parts := Ids.Split([',']);
  for Index := 0 to High(Parts) do
    if Trim(Parts[Index]) <> '' then
      InsertItem(Trim(Parts[Index]), -1);
end;

function TCustomToolBar.Items: string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to FIds.Count - 1 do
  begin
    if Index > 0 then
      Result := Result + ',';
    Result := Result + FIds[Index];
  end;
end;

procedure TCustomToolBar.RebuildItems;
begin
  SetItems(Items);
end;

function TCustomToolBar.IsFlexible(Index: LongInt): Boolean;
var
  Definition: TToolbarItemDefinition;
begin
  if FIds[Index] = ToolbarSpringId then
    Exit(True);
  Definition := FToolbox.Definition(FIds[Index]);
  Result := (Definition <> nil) and Definition.Flexible;
end;

function TCustomToolBar.WeightOf(Index: LongInt): LongInt;
var
  Definition: TToolbarItemDefinition;
begin
  Result := 1;
  Definition := FToolbox.Definition(FIds[Index]);
  if (Definition <> nil) and (Definition.FlexWeight > 0) then
    Result := Definition.FlexWeight;
end;

function TCustomToolBar.MinimumOf(Index: LongInt): LongInt;
var
  Definition: TToolbarItemDefinition;
begin
  Result := SpringMinimumWidth;
  Definition := FToolbox.Definition(FIds[Index]);
  if (Definition <> nil) and (Definition.MinimumWidth > 0) then
    Result := Definition.MinimumWidth;
end;

function TCustomToolBar.CountsInExtent(Child: TControl): Boolean;
begin
  Result := (Child <> FCover) and inherited CountsInExtent(Child);
end;

function TCustomToolBar.PreferredSize: TSize;
var
  Index: LongInt;
  Size: TSize;
begin
  Result := MakeSize(2 * ToolbarPadding, 0);
  for Index := 0 to FIds.Count - 1 do
  begin
    Size := ChildSize(ItemControls[Index]);
    if IsFlexible(Index) then
      Result.Width := Result.Width + MinimumOf(Index)
    else
      Result.Width := Result.Width + Size.Width;
    Result.Height := Max(Result.Height, Size.Height);
  end;
  Result.Height := Max(Result.Height, 22) + 2 * ToolbarPadding + 2;
end;

procedure TCustomToolBar.PlaceChildren(const Area: TRectangle);
var
  Index, Fixed, TotalWeight, Room, X, Width, Height, Top, Pad: LongInt;
  Widths: array of LongInt;
  Control: TControl;
  Size: TSize;
begin
  Pad := Scaled(ToolbarPadding);
  Widths := nil;
  SetLength(Widths, FIds.Count);
  Fixed := 0;
  TotalWeight := 0;
  for Index := 0 to FIds.Count - 1 do
    if IsFlexible(Index) then
    begin
      Widths[Index] := Scaled(MinimumOf(Index));
      Inc(Fixed, Widths[Index]);
      Inc(TotalWeight, WeightOf(Index));
    end
    else
    begin
      Widths[Index] := Scaled(ChildSize(ItemControls[Index]).Width);
      Inc(Fixed, Widths[Index]);
    end;
  Room := Max(0, RectangleWidth(Area) - 2 * Pad - Fixed);
  if TotalWeight > 0 then
    for Index := 0 to FIds.Count - 1 do
      if IsFlexible(Index) then
        Inc(Widths[Index], Room * WeightOf(Index) div TotalWeight);
  X := Area.Left + Pad;
  for Index := 0 to FIds.Count - 1 do
  begin
    Control := ItemControls[Index];
    Size := ChildSize(Control);
    Height := Min(Scaled(Size.Height), RectangleHeight(Area) - 2 * Pad);
    if Height <= 0 then
      Height := RectangleHeight(Area) - 2 * Pad;
    Top := Area.Top + (RectangleHeight(Area) - Height) div 2;
    Width := Widths[Index];
    PlaceChild(Control, MakeRectangle(X, Top, Width, Height));
    Inc(X, Width);
  end;
  if FCover <> nil then
    PlaceChild(FCover, Area);
end;

procedure TCustomToolBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawEtchedHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2 * BevelLine);
end;

procedure TCustomToolBar.UpdateCover;
begin
  if FToolbox.Customizing and (FCover = nil) then
  begin
    FCover := TCustomizeCover.Create(Self);
    TCustomizeCover(FCover).FToolbar := Self;
    TCustomizeCover(FCover).FPressIndex := -1;
    RequestLayout;
  end
  else if not FToolbox.Customizing and (FCover <> nil) then
  begin
    FreeAndNil(FCover);
    FDropIndex := -1;
    RequestLayout;
  end;
  if FCover <> nil then
    KeepChildOnTop(FCover);
  Invalidate;
end;

function TCustomToolBar.ItemAt(X: LongInt): LongInt;
var
  Index, Left: LongInt;
  Box: TRectangle;
begin
  Left := PixelBounds.Left;
  for Index := 0 to FIds.Count - 1 do
  begin
    Box := ItemControls[Index].PixelBounds;
    if (X + Left >= Box.Left) and (X + Left < Box.Right) then
      Exit(Index);
  end;
  Result := -1;
end;

function TCustomToolBar.DropIndexAt(X: LongInt): LongInt;
var
  Index, Left: LongInt;
  Box: TRectangle;
begin
  Left := PixelBounds.Left;
  for Index := 0 to FIds.Count - 1 do
  begin
    Box := ItemControls[Index].PixelBounds;
    if X + Left < (Box.Left + Box.Right) div 2 then
      Exit(Index);
  end;
  Result := FIds.Count;
end;

procedure TCustomToolBar.SetDropIndex(Value: LongInt);
begin
  if FDropIndex = Value then
    Exit;
  FDropIndex := Value;
  if FCover <> nil then
    FCover.Invalidate;
end;

function TCustomToolBar.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Info: TToolbarDragInfo;
begin
  Result := DropNone;
  if not FToolbox.Customizing or (Data.Format <> DragFormatToolbarItem) or not DecodeToolbarDrag(Data.Text, Info) then
    Exit(inherited DragOver(Data, X, Y, Modifiers));
  DropIndex := DropIndexAt(X);
  Result := DropMove;
end;

procedure TCustomToolBar.DragLeave;
begin
  DropIndex := -1;
  inherited DragLeave;
end;

procedure TCustomToolBar.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Info: TToolbarDragInfo;
  Source: TCustomToolBar;
  Target: LongInt;
begin
  DropIndex := -1;
  if not FToolbox.Customizing or (Data.Format <> DragFormatToolbarItem) or not DecodeToolbarDrag(Data.Text, Info) then
  begin
    inherited DragDrop(Data, X, Y, Effect);
    Exit;
  end;
  Target := DropIndexAt(X);
  Source := FToolbox.ToolbarByName(Info.ToolbarName);
  if (Source <> nil) and (Info.Index >= 0) and (Info.Index < Source.ItemCount) and
     (Source.ItemIds[Info.Index] = Info.Id) then
  begin
    { Dropping an item where it is changes nothing. }
    if (Source = Self) and ((Target = Info.Index) or (Target = Info.Index + 1)) then
      Exit;
    Source.RemoveItem(Info.Index);
    if (Source = Self) and (Info.Index < Target) then
      Dec(Target);
  end;
  InsertItem(Info.Id, Target);
  FToolbox.ArrangementChanged;
end;

{ ---- the toolbox ---- }

constructor TToolbox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FDefinitions := TList.Create;
  FToolbars := TList.Create;
  Align := AlignTop;
  AutoSize := True;
end;

destructor TToolbox.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to FDefinitions.Count - 1 do
    TToolbarItemDefinition(FDefinitions[Index]).Free;
  FDefinitions.Free;
  FToolbars.Free;
  inherited Destroy;
end;

procedure TToolbox.DefineItem(const Id, Caption: string; ImageIndex: LongInt; Flexible: Boolean;
  FlexWeight: LongInt; MinimumWidth: LongInt);
var
  Item: TToolbarItemDefinition;
begin
  Item := Definition(Id);
  if Item = nil then
  begin
    Item := TToolbarItemDefinition.Create;
    FDefinitions.Add(Item);
  end;
  Item.Id := Id;
  Item.Caption := Caption;
  Item.ImageIndex := ImageIndex;
  Item.Flexible := Flexible;
  Item.FlexWeight := FlexWeight;
  Item.MinimumWidth := MinimumWidth;
end;

function TToolbox.Definition(const Id: string): TToolbarItemDefinition;
var
  Index: LongInt;
begin
  for Index := 0 to FDefinitions.Count - 1 do
    if TToolbarItemDefinition(FDefinitions[Index]).Id = Id then
      Exit(TToolbarItemDefinition(FDefinitions[Index]));
  Result := nil;
end;

function TToolbox.AddToolbar(const Name, DefaultItems: string): TCustomToolBar;
begin
  Result := TCustomToolBar.CreateIn(Self, Name, DefaultItems);
  FToolbars.Add(Result);
end;

function TToolbox.GetToolbar(Index: LongInt): TCustomToolBar;
begin
  Result := TCustomToolBar(FToolbars[Index]);
end;

function TToolbox.ToolbarCount: LongInt;
begin
  Result := FToolbars.Count;
end;

function TToolbox.ToolbarByName(const Name: string): TCustomToolBar;
var
  Index: LongInt;
begin
  for Index := 0 to FToolbars.Count - 1 do
    if Toolbars[Index].Name = Name then
      Exit(Toolbars[Index]);
  Result := nil;
end;

function TToolbox.IsPlaced(const Id: string): Boolean;
var
  Index: LongInt;
begin
  if IsBuiltInItem(Id) then
    Exit(False);
  for Index := 0 to FToolbars.Count - 1 do
    if Toolbars[Index].IndexOfId(Id) >= 0 then
      Exit(True);
  Result := False;
end;

function TToolbox.UnplacedItems: TStringArray;
var
  Index: LongInt;
  Id: string;

  procedure Add(const Value: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Value;
  end;

begin
  Result := nil;
  for Index := 0 to FDefinitions.Count - 1 do
  begin
    Id := TToolbarItemDefinition(FDefinitions[Index]).Id;
    if not IsPlaced(Id) then
      Add(Id);
  end;
  Add(ToolbarSeparatorId);
  Add(ToolbarSpaceId);
  Add(ToolbarSpringId);
end;

procedure TToolbox.BeginCustomize;
var
  Index: LongInt;
begin
  FCustomizing := True;
  for Index := 0 to FToolbars.Count - 1 do
    Toolbars[Index].UpdateCover;
end;

procedure TToolbox.EndCustomize;
var
  Index: LongInt;
begin
  FCustomizing := False;
  for Index := 0 to FToolbars.Count - 1 do
    Toolbars[Index].UpdateCover;
end;

procedure TToolbox.RestoreDefaults;
var
  Index: LongInt;
begin
  { Emptied first, so an item moving between toolbars is free to go. }
  for Index := 0 to FToolbars.Count - 1 do
    Toolbars[Index].SetItems('');
  for Index := 0 to FToolbars.Count - 1 do
    Toolbars[Index].SetItems(Toolbars[Index].DefaultItems);
  ArrangementChanged;
end;

procedure TToolbox.RebuildItems;
var
  Index: LongInt;
begin
  for Index := 0 to FToolbars.Count - 1 do
    Toolbars[Index].RebuildItems;
end;

procedure TToolbox.ArrangementChanged;
var
  Index: LongInt;
begin
  for Index := 0 to FToolbars.Count - 1 do
  begin
    Toolbars[Index].RequestLayout;
    Toolbars[Index].Invalidate;
  end;
  if FPalette <> nil then
    FPalette.Invalidate;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TToolbox.PreferredSize: TSize;
begin
  Result := ChildrenExtent;
end;

end.

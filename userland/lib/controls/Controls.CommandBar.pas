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
  Command bars: a strip of flat command buttons along the top of a
  window's content (a file manager's New, Cut, Copy, Sort, View...),
  each a small picture from the bar's Images with its caption beside it
  (or only the picture, the caption then its hint).

  AddCommand gives a button that runs its OnClick (a toggle stays down
  until clicked again); AddDropDown one with a small arrow whose menu
  the program fills each time it opens (OnOpening, with a fresh menu)
  and which pops up under it; AddSeparator a thin line. A button with
  AlignRight stands at the far end (a details pane's toggle). Changing
  a button's caption, picture or visibility lays the bar out again; a
  button freed is forgotten at the next layout.

  An overflow button ("...") always ends the commands: its menu holds
  the commands that do not fit the bar's width (moved there from the
  end, Controls.CommandLayout, as items that do what the buttons do),
  then whatever the program adds in OnOverflowOpening.
}
unit Controls.CommandBar;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList,
  Controls.Menus;

type
  TCommandButton = class;
  TCommandBar = class;

  { The program fills Menu (fresh each time) for Sender's menu. }
  TCommandMenuEvent = procedure(Sender: TCommandButton; Menu: TMenuItem) of object;

  TCommandButton = class(TControl)
  private
    FImageIndex: LongInt;
    FShowCaption: Boolean;
    FIsSeparator: Boolean;
    FIsDropDown: Boolean;
    FIsOverflow: Boolean;
    FAlignRight: Boolean;
    FIsToggle: Boolean;
    FDown: Boolean;
    FHovered: Boolean;
    FHeld: Boolean;
    FMenuOpen: Boolean;
    FInOverflow: Boolean;
    FOnOpening: TCommandMenuEvent;
    procedure SetImageIndex(Value: LongInt);
    procedure SetShowCaption(Value: Boolean);
    procedure SetAlignRight(Value: Boolean);
    procedure SetDown(Value: Boolean);
    function GetCaption: string;
    procedure SetCaption(const Value: string);
    function Bar: TCommandBar;
    function HasImage: Boolean;
    function ShowsCaption: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure TextChanged; override;
    procedure EnabledChanged; override;
  public
    constructor Create(AParent: TControl); override;
    { Pixels it needs across at the scale now. }
    function NaturalWidth: LongInt;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    { What a click does (a toggle changes Down first). }
    procedure Execute;
    property Caption: string read GetCaption write SetCaption;
    { Its picture in the bar's Images (-1: none). }
    property ImageIndex: LongInt read FImageIndex write SetImageIndex;
    { The caption beside the picture (else only the picture, and the
      caption is its hint unless it has one). }
    property ShowCaption: Boolean read FShowCaption write SetShowCaption;
    property AlignRight: Boolean read FAlignRight write SetAlignRight;
    property IsToggle: Boolean read FIsToggle write FIsToggle;
    property Down: Boolean read FDown write SetDown;
    property IsSeparator: Boolean read FIsSeparator;
    property IsDropDown: Boolean read FIsDropDown;
    property IsOverflow: Boolean read FIsOverflow;
    { Moved into the overflow menu for want of room. }
    property InOverflow: Boolean read FInOverflow;
    property OnOpening: TCommandMenuEvent read FOnOpening write FOnOpening;
  end;

  TCommandBar = class(TControl)
  private
    FCommands: TList;
    FOverflowButton: TCommandButton;
    FImages: TImageList;
    FMenu: TMenuItem;
    FMenuButton: TCommandButton;
    FOnOverflowOpening: TCommandMenuEvent;
    procedure SetImages(Value: TImageList);
    function GetCommandCount: LongInt;
    function GetCommand(Index: LongInt): TCommandButton;
    function NewButton: TCommandButton;
    procedure PruneCommands;
    procedure FillOverflowMenu;
    procedure OverflowItemClicked(Item: TMenuItem);
    procedure MenuClosed(List: TMenuList);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function AddCommand(const ACaption: string; AImageIndex: LongInt; const AHint: string; AOnClick: TControlEvent;
      AShowCaption: Boolean = True): TCommandButton;
    function AddDropDown(const ACaption: string; AImageIndex: LongInt; const AHint: string;
      AOnOpening: TCommandMenuEvent): TCommandButton;
    function AddSeparator: TCommandButton;
    { Opens Button's menu (a drop-down's, or the overflow button's) under
      it, as a click on it does. }
    procedure OpenMenu(Button: TCommandButton);
    { Where Button is (the bar's pixels; empty while it is in the
      overflow menu or hidden). }
    function ButtonBounds(Button: TCommandButton): TRectangle;
    function PreferredSize: TSize; override;
    property CommandCount: LongInt read GetCommandCount;
    property Commands[Index: LongInt]: TCommandButton read GetCommand;
    property OverflowButton: TCommandButton read FOverflowButton;
    { The buttons' pictures, 16 logical units (shared: the bar does not
      own it). }
    property Images: TImageList read FImages write SetImages;
    property OnOverflowOpening: TCommandMenuEvent read FOnOverflowOpening write FOnOverflowOpening;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Icons,
  Controls.Text,
  Controls.Window,
  Controls.LayoutRules,
  Controls.Painting,
  Controls.PartPainting,
  Controls.CommandLayout;

const
  { Logical units. }
  CommandBarHeight = 32;
  ButtonHeight = 28;
  BarPadding = 4;
  ButtonGap = 2;
  ButtonPadding = 8;
  ImageTextGap = 6;
  ArrowWidth = 12;
  ArrowGlyphSize = 7;
  SeparatorWidth = 9;
  OverflowWidth = 32;
  DotsGlyphSize = 12;

{ --- TCommandButton -------------------------------------------------------------- }

constructor TCommandButton.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FImageIndex := -1;
  FShowCaption := True;
end;

function TCommandButton.Bar: TCommandBar;
begin
  Result := nil;
  if Parent is TCommandBar then
    Result := TCommandBar(Parent);
end;

function TCommandButton.HasImage: Boolean;
begin
  Result := (Bar <> nil) and (Bar.Images <> nil) and Bar.Images.ValidIndex(FImageIndex);
end;

function TCommandButton.ShowsCaption: Boolean;
begin
  Result := FShowCaption and (Text <> '');
end;

function TCommandButton.GetCaption: string;
begin
  Result := Text;
end;

procedure TCommandButton.SetCaption(const Value: string);
begin
  Text := Value;
end;

procedure TCommandButton.TextChanged;
begin
  inherited TextChanged;
  if Parent <> nil then
    Parent.RequestLayout;
  Invalidate;
end;

procedure TCommandButton.EnabledChanged;
begin
  inherited EnabledChanged;
  Invalidate;
end;

procedure TCommandButton.SetImageIndex(Value: LongInt);
begin
  FImageIndex := Value;
  if Parent <> nil then
    Parent.RequestLayout;
  Invalidate;
end;

procedure TCommandButton.SetShowCaption(Value: Boolean);
begin
  FShowCaption := Value;
  if Parent <> nil then
    Parent.RequestLayout;
  Invalidate;
end;

procedure TCommandButton.SetAlignRight(Value: Boolean);
begin
  FAlignRight := Value;
  if Parent <> nil then
    Parent.RequestLayout;
end;

procedure TCommandButton.SetDown(Value: Boolean);
begin
  if FDown = Value then
    Exit;
  FDown := Value;
  Invalidate;
end;

function TCommandButton.NaturalWidth: LongInt;
begin
  if FIsSeparator then
    Exit(Scaled(SeparatorWidth));
  if FIsOverflow then
    Exit(Scaled(OverflowWidth));
  Result := 2 * Scaled(ButtonPadding);
  if HasImage then
    Result := Result + Scaled(SmallIconSize);
  if ShowsCaption then
  begin
    Result := Result + MnemonicTextWidth(ControlFace, Text);
    if HasImage then
      Result := Result + Scaled(ImageTextGap);
  end;
  if FIsDropDown then
    Result := Result + Scaled(ArrowWidth);
end;

function TCommandButton.HintAt(X, Y: LongInt; out Area: TRectangle): string;
begin
  Area := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Result := '';
  if not ShowHint or FIsSeparator then
    Exit;
  Result := Hint;
  if (Result = '') and not ShowsCaption then
    Result := TextWithoutMnemonic(Text);
  if (Result = '') and FIsOverflow then
    Result := 'See more';
end;

procedure TCommandButton.Execute;
begin
  if not Enabled then
    Exit;
  if FIsToggle then
    Down := not FDown;
  Click;
end;

procedure TCommandButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Content: TRectangle;
  Picture: TRectangle;
  Look: TPartLook;
  Size: LongInt;
  State: TImageDrawState;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FIsSeparator then
  begin
    DrawEtchedVerticalLine(Canvas, RectangleWidth(Box) div 2 - BevelLine, Scaled(4), RectangleHeight(Box) - Scaled(4));
    Exit;
  end;
  Look := PartNormal;
  if (FHeld and FHovered) or FMenuOpen or FDown then
    Look := PartPressed
  else if FHovered and Enabled then
    Look := PartHot;
  DrawPartFace(Canvas, Box, Look);
  if FIsOverflow then
  begin
    DrawDotsGlyph(Canvas, Box, Scaled(DotsGlyphSize), Theme.FaceText);
    Exit;
  end;
  Content := MakeRectangle(Box.Left + Scaled(ButtonPadding), Box.Top, RectangleWidth(Box) - 2 * Scaled(ButtonPadding),
    RectangleHeight(Box));
  if FIsDropDown then
  begin
    DrawChevronGlyph(Canvas, MakeRectangle(Content.Right - Scaled(ArrowWidth) + Scaled(4), Box.Top,
      Scaled(ArrowWidth) - Scaled(4), RectangleHeight(Box)), ArrowDown, Scaled(ArrowGlyphSize), Theme.FaceText);
    Content.Right := Content.Right - Scaled(ArrowWidth);
  end;
  if HasImage then
  begin
    Size := Scaled(SmallIconSize);
    if ShowsCaption then
      Picture := MakeRectangle(Content.Left, Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size)
    else
      Picture := MakeRectangle(Content.Left + (RectangleWidth(Content) - Size) div 2,
        Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size);
    State := ImageDrawNormal;
    if not Enabled then
      State := ImageDrawDisabled;
    Bar.Images.DrawInBox(Canvas, FImageIndex, Picture, State);
    Content.Left := Picture.Right + Scaled(ImageTextGap);
  end;
  if not ShowsCaption then
    Exit;
  if Enabled then
    TextColor := Theme.FaceText
  else
    TextColor := Theme.DisabledText;
  DrawMnemonicTextInBox(Canvas, ControlFace, Text, Content, AlignTextLeft, TextColor);
end;

procedure TCommandButton.PointerEnter;
begin
  FHovered := True;
  Invalidate;
end;

procedure TCommandButton.PointerLeave;
begin
  FHovered := False;
  Invalidate;
end;

procedure TCommandButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or FIsSeparator or not Enabled then
    Exit;
  if (FIsDropDown or FIsOverflow) and (Bar <> nil) then
  begin
    Bar.OpenMenu(Self);
    Exit;
  end;
  FHeld := True;
  Invalidate;
end;

procedure TCommandButton.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Inside: Boolean;
begin
  if not FHeld then
    Exit;
  FHeld := False;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  FHovered := Inside;
  Invalidate;
  if Inside then
    Execute;
end;

{ --- TCommandBar ------------------------------------------------------------------ }

constructor TCommandBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FCommands := TList.Create;
  FOverflowButton := TCommandButton.Create(Self);
  FOverflowButton.FIsOverflow := True;
  SetBounds(0, 0, 0, CommandBarHeight);
  Align := AlignTop;
end;

destructor TCommandBar.Destroy;
begin
  FMenu.Free;
  FMenu := nil;
  FCommands.Free;
  FCommands := nil;
  inherited Destroy;
end;

function TCommandBar.PreferredSize: TSize;
begin
  Result := MakeSize(Bounds.Right - Bounds.Left, CommandBarHeight);
end;

procedure TCommandBar.SetImages(Value: TImageList);
begin
  FImages := Value;
  RequestLayout;
  Invalidate;
end;

function TCommandBar.GetCommandCount: LongInt;
begin
  Result := FCommands.Count;
end;

function TCommandBar.GetCommand(Index: LongInt): TCommandButton;
begin
  Result := TCommandButton(FCommands[Index]);
end;

function TCommandBar.NewButton: TCommandButton;
begin
  Result := TCommandButton.Create(Self);
  FCommands.Add(Result);
  RequestLayout;
end;

function TCommandBar.AddCommand(const ACaption: string; AImageIndex: LongInt; const AHint: string;
  AOnClick: TControlEvent; AShowCaption: Boolean): TCommandButton;
begin
  Result := NewButton;
  Result.Text := ACaption;
  Result.FImageIndex := AImageIndex;
  Result.Hint := AHint;
  Result.OnClick := AOnClick;
  Result.FShowCaption := AShowCaption;
end;

function TCommandBar.AddDropDown(const ACaption: string; AImageIndex: LongInt; const AHint: string;
  AOnOpening: TCommandMenuEvent): TCommandButton;
begin
  Result := NewButton;
  Result.Text := ACaption;
  Result.FImageIndex := AImageIndex;
  Result.Hint := AHint;
  Result.FIsDropDown := True;
  Result.FOnOpening := AOnOpening;
end;

function TCommandBar.AddSeparator: TCommandButton;
begin
  Result := NewButton;
  Result.FIsSeparator := True;
end;

procedure TCommandBar.Layout;
var
  Showing: TList;
  Slots: TCommandSlots;
  Placements: TCommandPlacements;
  OverflowLeft: LongInt;
  Index: LongInt;
  Button: TCommandButton;
  Padding: LongInt;
  Top: LongInt;
  Available: LongInt;
begin
  if FCommands = nil then
    Exit;
  PruneCommands;
  Showing := TList.Create;
  try
    for Index := 0 to FCommands.Count - 1 do
    begin
      Button := Commands[Index];
      Button.FInOverflow := False;
      if Button.Visible then
        Showing.Add(Button)
      else
        Button.AssignBounds(0, 0, 0, 0);
    end;
    Slots := nil;
    SetLength(Slots, Showing.Count);
    for Index := 0 to Showing.Count - 1 do
    begin
      Button := TCommandButton(Showing[Index]);
      Slots[Index].Width := Button.NaturalWidth;
      Slots[Index].AlignRight := Button.AlignRight;
      Slots[Index].IsSeparator := Button.IsSeparator;
    end;
    Padding := Scaled(BarPadding);
    Available := RectangleWidth(PixelBounds) - 2 * Padding;
    ArrangeCommands(Slots, Available, Scaled(OverflowWidth), Scaled(ButtonGap), Placements, OverflowLeft);
    Top := (CommandBarHeight - ButtonHeight) div 2;
    for Index := 0 to Showing.Count - 1 do
    begin
      Button := TCommandButton(Showing[Index]);
      if Placements[Index].Shown then
        Button.AssignBounds(Unscaled(Padding + Placements[Index].Left), Top, PixelsToLogicalCeiling(Slots[Index].Width),
          ButtonHeight)
      else
      begin
        Button.FInOverflow := not Button.IsSeparator;
        Button.AssignBounds(0, 0, 0, 0);
      end;
    end;
    FOverflowButton.AssignBounds(Unscaled(Padding + OverflowLeft), Top, OverflowWidth, ButtonHeight);
  finally
    Showing.Free;
  end;
  inherited Layout;
end;

{ Forgets buttons the program freed (no longer among the children). }
procedure TCommandBar.PruneCommands;
var
  Index: LongInt;
  Child: LongInt;
  Found: Boolean;
begin
  for Index := FCommands.Count - 1 downto 0 do
  begin
    Found := False;
    for Child := 0 to ChildCount - 1 do
      if Pointer(Children[Child]) = FCommands[Index] then
        Found := True;
    if not Found then
      FCommands.Delete(Index);
  end;
end;

function TCommandBar.ButtonBounds(Button: TCommandButton): TRectangle;
var
  Place: TRectangle;
begin
  Place := Button.PixelBounds;
  if not Button.Visible or Button.InOverflow or (RectangleWidth(Place) <= 0) then
    Exit(MakeRectangle(0, 0, 0, 0));
  Result := OffsetRectangle(Place, -PixelBounds.Left, -PixelBounds.Top);
end;

procedure TCommandBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  if Theme.HeaderBandsShown then
    FillRectangle(Canvas, MakeRectangle(0, Box.Bottom - BevelLine, Box.Right, BevelLine), Theme.Shadow)
  else
    DrawEtchedHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2 * BevelLine);
end;

{ The commands that did not fit, as items doing what they do, then the
  program's own. }
procedure TCommandBar.FillOverflowMenu;
var
  Index: LongInt;
  Button: TCommandButton;
  Item: TMenuItem;
  LastWasSeparator: Boolean;
  Moved: Boolean;
begin
  LastWasSeparator := True;
  Moved := False;
  for Index := 0 to FCommands.Count - 1 do
  begin
    Button := Commands[Index];
    if not Button.Visible then
      Continue;
    if Button.IsSeparator then
    begin
      if not LastWasSeparator and Moved then
      begin
        FMenu.AddSeparator;
        LastWasSeparator := True;
      end;
      Continue;
    end;
    if not Button.InOverflow then
      Continue;
    Item := FMenu.Add(Button.Text, @OverflowItemClicked);
    Item.ImageIndex := Button.ImageIndex;
    Item.Enabled := Button.Enabled;
    Item.Checked := Button.IsToggle and Button.Down;
    Item.Tag := PtrInt(Button);
    if Button.IsDropDown then
    begin
      Item.OnClick := nil;
      if Assigned(Button.FOnOpening) then
        Button.FOnOpening(Button, Item);
    end;
    LastWasSeparator := False;
    Moved := True;
  end;
  if Moved and not LastWasSeparator and Assigned(FOnOverflowOpening) then
    FMenu.AddSeparator;
  if Assigned(FOnOverflowOpening) then
    FOnOverflowOpening(FOverflowButton, FMenu);
end;

procedure TCommandBar.OverflowItemClicked(Item: TMenuItem);
var
  Button: TCommandButton;
  Index: LongInt;
begin
  { Only a button still on the bar (the menu may outlive one taken
    away). }
  for Index := 0 to FCommands.Count - 1 do
    if FCommands[Index] = Pointer(Item.Tag) then
    begin
      Button := Commands[Index];
      Button.Execute;
      Exit;
    end;
end;

procedure TCommandBar.OpenMenu(Button: TCommandButton);
var
  Window: TControlWindow;
  List: TMenuList;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  if not (Button.IsDropDown or Button.IsOverflow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FMenu.Free;
  FMenu := TMenuItem.Create('');
  FMenu.Images := FImages;
  if Button.IsOverflow then
    FillOverflowMenu
  else if Assigned(Button.FOnOpening) then
    Button.FOnOpening(Button, FMenu);
  if FMenu.Count = 0 then
    Exit;
  FMenuButton := Button;
  Button.FMenuOpen := True;
  Button.Invalidate;
  List := ShowPopupMenu(Window, FMenu, Window.ScreenLeft + Unscaled(Button.PixelBounds.Left),
    Window.ScreenTop + Unscaled(Button.PixelBounds.Bottom));
  List.OnClosed := @MenuClosed;
end;

procedure TCommandBar.MenuClosed(List: TMenuList);
begin
  if FMenuButton = nil then
    Exit;
  FMenuButton.FMenuOpen := False;
  FMenuButton.FHeld := False;
  FMenuButton.Invalidate;
  FMenuButton := nil;
end;

end.

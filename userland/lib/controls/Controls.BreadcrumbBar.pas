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
  Breadcrumb bars: an address bar that looks like an edit field and
  shows the path as a row of buttons, one for each folder down to the
  one shown (SetSegments: each segment's caption and the path it stands
  for), with a picture before them if the program gives one
  (RootImageIndex of Images).

  Each segment is a flat button (OnNavigate with its path) followed by
  a chevron; a chevron lists the folders inside its segment's in a
  pop-up menu (asked for with OnListChildren; pointing down while
  open), and choosing one navigates into it (Controls.BreadcrumbLayout
  joins the path). Segments that do not fit collapse from the left into
  an overflow button whose menu lists the hidden ancestors, the nearest
  first.

  A click on the empty part right of the segments (or BeginEditing)
  swaps them for an edit box holding EditText, all of it selected:
  Enter gives OnPathEntered with the text and the segments come back,
  Escape or the focus going elsewhere brings them back unchanged. While
  editing, every change asks OnComplete for suggestions, shown in a list
  under the bar (Controls.SuggestionList): Up and Down move through
  them, Enter or a click takes one (OnPathEntered with it), Tab puts it
  in the box without going there.
}
unit Controls.BreadcrumbBar;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList,
  Controls.EditBox,
  Controls.Menus,
  Controls.SuggestionList;

type
  TPathEvent = procedure(Sender: TControl; const Path: string) of object;
  TListChildrenEvent = procedure(Sender: TControl; const Path: string; Names: TStrings) of object;
  TCompleteEvent = procedure(Sender: TControl; const Text: string; Suggestions: TStrings) of object;

  TBreadcrumbPartKind = (CrumbNone, CrumbRoot, CrumbOverflow, CrumbSegment, CrumbChevron, CrumbEmpty);

  TBreadcrumbPart = record
    Kind: TBreadcrumbPartKind;
    Index: LongInt;
  end;

  TBreadcrumbBar = class(TControl)
  private
    FCaptions: array of string;
    FPaths: array of string;
    FImages: TImageList;
    FRootImageIndex: LongInt;
    FEditText: string;
    FEdit: TEditBox;
    FEditing: Boolean;
    FSettingText: Boolean;
    FSuggestions: TSuggestionDropDown;
    { Where the parts are (pixels), worked out by Arrange. }
    FRootBox: TRectangle;
    FOverflowBox: TRectangle;
    FSegmentBoxes: array of TRectangle;
    FChevronBoxes: array of TRectangle;
    FFirstShown: LongInt;
    FEmptyLeft: LongInt;
    FHot: TBreadcrumbPart;
    FPressed: TBreadcrumbPart;
    { The menu open (a chevron's or the overflow's) and the paths of its
      items (by Tag); kept until the next opens, as a chosen item is
      still in use when the menu says it closed. }
    FOpen: TBreadcrumbPart;
    FMenu: TMenuItem;
    FMenuPaths: TStringList;
    FOnNavigate: TPathEvent;
    FOnListChildren: TListChildrenEvent;
    FOnPathEntered: TPathEvent;
    FOnComplete: TCompleteEvent;
    procedure SetImages(Value: TImageList);
    procedure SetRootImageIndex(Value: LongInt);
    function GetSegmentCount: LongInt;
    function HasRootImage: Boolean;
    function SegmentTextWidth(Index: LongInt): LongInt;
    function InnerBox: TRectangle;
    procedure Arrange;
    function PartAt(X, Y: LongInt): TBreadcrumbPart;
    function PartBox(const Part: TBreadcrumbPart): TRectangle;
    procedure SetHot(const Part: TBreadcrumbPart);
    procedure OpenMenu(const Part: TBreadcrumbPart; Names, Paths: TStrings);
    procedure OpenChildMenu(Index: LongInt);
    procedure OpenOverflowMenu;
    procedure MenuChosen(Item: TMenuItem);
    procedure MenuClosed(List: TMenuList);
    procedure EditChanged(Sender: TControl);
    procedure EditFocusChanged(Sender: TControl);
    procedure AskSuggestions;
    procedure SuggestionAccepted(Index: LongInt);
    procedure SuggestionCompleted(Index: LongInt);
    procedure EndEditing(Accept: Boolean; const Entered: string);
    procedure PaintPart(var Canvas: TCanvas; const Part: TBreadcrumbPart);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { The segments from the top of the path down: Captions[I] shown,
      Paths[I] where it goes (the arrays as long as each other). }
    procedure SetSegments(const Captions, Paths: array of string);
    { Swaps the segments for the edit box (holding EditText, selected). }
    procedure BeginEditing;
    { Back to the segments, the text dropped. }
    procedure CancelEditing;
    function IsEditing: Boolean;
    function SegmentCaption(Index: LongInt): string;
    function SegmentPath(Index: LongInt): string;
    { Where segment Index's button and its chevron are (the bar's
      pixels; empty for one collapsed into the overflow button), the
      overflow button (empty without one), and a point in the empty part
      that starts editing. }
    function SegmentBounds(Index: LongInt): TRectangle;
    function ChevronBounds(Index: LongInt): TRectangle;
    function OverflowBounds: TRectangle;
    function EmptyAreaPoint: TPoint;
    { The first segment not collapsed into the overflow button. }
    function FirstShownSegment: LongInt;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    function PreferredSize: TSize; override;
    property SegmentCount: LongInt read GetSegmentCount;
    { The text the edit box starts with (the full path, say). }
    property EditText: string read FEditText write FEditText;
    { The edit box (while editing: its text as typed). }
    property EditBox: TEditBox read FEdit;
    { The picture before the segments (shared: the bar does not own
      it), and which of its pictures (-1, the default: none). }
    property Images: TImageList read FImages write SetImages;
    property RootImageIndex: LongInt read FRootImageIndex write SetRootImageIndex;
    property OnNavigate: TPathEvent read FOnNavigate write FOnNavigate;
    property OnListChildren: TListChildrenEvent read FOnListChildren write FOnListChildren;
    property OnPathEntered: TPathEvent read FOnPathEntered write FOnPathEntered;
    property OnComplete: TCompleteEvent read FOnComplete write FOnComplete;
  end;

implementation

uses
  Abi.SystemCalls,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Icons,
  Controls.Text,
  Controls.Window,
  Controls.LayoutRules,
  Controls.Painting,
  Controls.PartPainting,
  Controls.BreadcrumbLayout;

const
  { Logical units. }
  BarHeight = 28;
  RootWidth = 26;
  OverflowWidth = 24;
  SegmentPadding = 6;
  ChevronWidth = 16;
  ChevronGlyphSize = 8;
  { Room kept free at the right for a click that starts editing. }
  EmptyRoom = 32;

function MakePart(Kind: TBreadcrumbPartKind; Index: LongInt = -1): TBreadcrumbPart;
begin
  Result.Kind := Kind;
  Result.Index := Index;
end;

function SamePart(const A, B: TBreadcrumbPart): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Index = B.Index);
end;

constructor TBreadcrumbBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FRootImageIndex := -1;
  FHot := MakePart(CrumbNone);
  FPressed := MakePart(CrumbNone);
  FOpen := MakePart(CrumbNone);
  FMenuPaths := TStringList.Create;
  FEdit := TEditBox.Create(Self);
  FEdit.Align := AlignClient;
  FEdit.Visible := False;
  FEdit.OnChange := @EditChanged;
  FEdit.OnFocusChanged := @EditFocusChanged;
  FSuggestions := TSuggestionDropDown.Create(Self, FEdit);
  FSuggestions.OnAccept := @SuggestionAccepted;
  FSuggestions.OnComplete := @SuggestionCompleted;
  SetBounds(0, 0, 200, BarHeight);
end;

destructor TBreadcrumbBar.Destroy;
begin
  FSuggestions.Free;
  FMenu.Free;
  FMenuPaths.Free;
  inherited Destroy;
end;

function TBreadcrumbBar.PreferredSize: TSize;
begin
  Result := MakeSize(Bounds.Right - Bounds.Left, BarHeight);
end;

procedure TBreadcrumbBar.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

procedure TBreadcrumbBar.SetRootImageIndex(Value: LongInt);
begin
  FRootImageIndex := Value;
  Invalidate;
end;

function TBreadcrumbBar.GetSegmentCount: LongInt;
begin
  Result := Length(FCaptions);
end;

function TBreadcrumbBar.SegmentCaption(Index: LongInt): string;
begin
  Result := '';
  if (Index >= 0) and (Index < Length(FCaptions)) then
    Result := FCaptions[Index];
end;

function TBreadcrumbBar.SegmentPath(Index: LongInt): string;
begin
  Result := '';
  if (Index >= 0) and (Index < Length(FPaths)) then
    Result := FPaths[Index];
end;

procedure TBreadcrumbBar.SetSegments(const Captions, Paths: array of string);
var
  Index: LongInt;
begin
  FCaptions := nil;
  FPaths := nil;
  SetLength(FCaptions, Length(Captions));
  SetLength(FPaths, Length(Captions));
  for Index := 0 to High(Captions) do
  begin
    FCaptions[Index] := Captions[Index];
    if Index <= High(Paths) then
      FPaths[Index] := Paths[Index]
    else
      FPaths[Index] := '';
  end;
  FHot := MakePart(CrumbNone);
  FPressed := MakePart(CrumbNone);
  Invalidate;
end;

{ --- where the parts go ---------------------------------------------------------- }

function TBreadcrumbBar.HasRootImage: Boolean;
begin
  Result := (FImages <> nil) and FImages.ValidIndex(FRootImageIndex);
end;

function TBreadcrumbBar.SegmentTextWidth(Index: LongInt): LongInt;
begin
  Result := TextWidth(ControlFace, FCaptions[Index]) + 2 * Scaled(SegmentPadding);
end;

function TBreadcrumbBar.InnerBox: TRectangle;
begin
  Result := InflateRectangle(MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)),
    -BevelWidth);
end;

procedure TBreadcrumbBar.Arrange;
var
  Inner: TRectangle;
  X: LongInt;
  Widths: array of LongInt;
  Index: LongInt;
  Width: LongInt;
  Chevron: LongInt;
begin
  Inner := InnerBox;
  X := Inner.Left + Scaled(2);
  FRootBox := MakeRectangle(0, 0, 0, 0);
  FOverflowBox := MakeRectangle(0, 0, 0, 0);
  if HasRootImage then
  begin
    FRootBox := MakeRectangle(X, Inner.Top, Scaled(RootWidth), RectangleHeight(Inner));
    X := FRootBox.Right;
  end;
  Chevron := Scaled(ChevronWidth);
  Widths := nil;
  SetLength(Widths, Length(FCaptions));
  for Index := 0 to High(FCaptions) do
    Widths[Index] := SegmentTextWidth(Index) + Chevron;
  FFirstShown := Controls.BreadcrumbLayout.FirstShownSegment(Widths, Inner.Right - Scaled(EmptyRoom) - X,
    Scaled(OverflowWidth));
  if FFirstShown > 0 then
  begin
    FOverflowBox := MakeRectangle(X, Inner.Top, Scaled(OverflowWidth), RectangleHeight(Inner));
    X := FOverflowBox.Right;
  end;
  FSegmentBoxes := nil;
  FChevronBoxes := nil;
  SetLength(FSegmentBoxes, Length(FCaptions));
  SetLength(FChevronBoxes, Length(FCaptions));
  for Index := FFirstShown to High(FCaptions) do
  begin
    Width := SegmentTextWidth(Index);
    { The last one cut short if it must be, its chevron kept. }
    if X + Width + Chevron > Inner.Right then
      Width := Inner.Right - Chevron - X;
    if Width < 0 then
      Width := 0;
    FSegmentBoxes[Index] := MakeRectangle(X, Inner.Top, Width, RectangleHeight(Inner));
    FChevronBoxes[Index] := MakeRectangle(X + Width, Inner.Top, Chevron, RectangleHeight(Inner));
    X := X + Width + Chevron;
  end;
  FEmptyLeft := X;
end;

function TBreadcrumbBar.PartBox(const Part: TBreadcrumbPart): TRectangle;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  case Part.Kind of
    CrumbRoot: Result := FRootBox;
    CrumbOverflow: Result := FOverflowBox;
    CrumbSegment: Result := FSegmentBoxes[Part.Index];
    CrumbChevron: Result := FChevronBoxes[Part.Index];
  end;
end;

function TBreadcrumbBar.PartAt(X, Y: LongInt): TBreadcrumbPart;
var
  Index: LongInt;
begin
  Arrange;
  Result := MakePart(CrumbNone);
  if not RectangleContainsPoint(InnerBox, X, Y) then
    Exit;
  if RectangleContainsPoint(FRootBox, X, Y) then
    Exit(MakePart(CrumbRoot));
  if RectangleContainsPoint(FOverflowBox, X, Y) then
    Exit(MakePart(CrumbOverflow));
  for Index := FFirstShown to High(FCaptions) do
  begin
    if RectangleContainsPoint(FSegmentBoxes[Index], X, Y) then
      Exit(MakePart(CrumbSegment, Index));
    if RectangleContainsPoint(FChevronBoxes[Index], X, Y) then
      Exit(MakePart(CrumbChevron, Index));
  end;
  if X >= FEmptyLeft then
    Result := MakePart(CrumbEmpty);
end;

function TBreadcrumbBar.SegmentBounds(Index: LongInt): TRectangle;
begin
  Arrange;
  Result := MakeRectangle(0, 0, 0, 0);
  if (Index >= FFirstShown) and (Index < Length(FCaptions)) then
    Result := FSegmentBoxes[Index];
end;

function TBreadcrumbBar.ChevronBounds(Index: LongInt): TRectangle;
begin
  Arrange;
  Result := MakeRectangle(0, 0, 0, 0);
  if (Index >= FFirstShown) and (Index < Length(FCaptions)) then
    Result := FChevronBoxes[Index];
end;

function TBreadcrumbBar.OverflowBounds: TRectangle;
begin
  Arrange;
  Result := FOverflowBox;
end;

function TBreadcrumbBar.EmptyAreaPoint: TPoint;
var
  Inner: TRectangle;
begin
  Arrange;
  Inner := InnerBox;
  Result := MakePoint((FEmptyLeft + Inner.Right) div 2, (Inner.Top + Inner.Bottom) div 2);
end;

function TBreadcrumbBar.FirstShownSegment: LongInt;
begin
  Arrange;
  Result := FFirstShown;
end;

function TBreadcrumbBar.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Under: TBreadcrumbPart;
begin
  Result := '';
  Area := MakeRectangle(0, 0, 0, 0);
  if FEditing or not ShowHint then
    Exit;
  Under := PartAt(X, Y);
  case Under.Kind of
    CrumbSegment: Result := FPaths[Under.Index];
    CrumbOverflow: Result := 'Folders above these';
  else
    Exit;
  end;
  Area := PartBox(Under);
end;

{ --- the menus ------------------------------------------------------------------ }

procedure TBreadcrumbBar.OpenMenu(const Part: TBreadcrumbPart; Names, Paths: TStrings);
var
  Window: TControlWindow;
  Index: LongInt;
  Item: TMenuItem;
  Box: TRectangle;
  List: TMenuList;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FMenu.Free;
  FMenu := TMenuItem.Create('');
  FMenuPaths.Assign(Paths);
  FMenu.Images := FImages;
  for Index := 0 to Names.Count - 1 do
  begin
    Item := FMenu.Add(Names[Index]);
    Item.Tag := Index;
  end;
  if Names.Count = 0 then
  begin
    Item := FMenu.Add('No folders');
    Item.Enabled := False;
    Item.Tag := -1;
  end;
  FOpen := Part;
  Invalidate;
  Box := PartBox(Part);
  List := ShowPopupMenu(Window, FMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Box.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Box.Bottom), @MenuChosen);
  List.OnClosed := @MenuClosed;
end;

procedure TBreadcrumbBar.OpenChildMenu(Index: LongInt);
var
  Names: TStringList;
  Paths: TStringList;
  Position: LongInt;
begin
  Names := TStringList.Create;
  Paths := TStringList.Create;
  try
    if Assigned(FOnListChildren) then
      FOnListChildren(Self, FPaths[Index], Names);
    for Position := 0 to Names.Count - 1 do
      Paths.Add(JoinChildPath(FPaths[Index], Names[Position]));
    OpenMenu(MakePart(CrumbChevron, Index), Names, Paths);
  finally
    Names.Free;
    Paths.Free;
  end;
end;

{ The hidden ancestors, the nearest first. }
procedure TBreadcrumbBar.OpenOverflowMenu;
var
  Names: TStringList;
  Paths: TStringList;
  Index: LongInt;
begin
  Names := TStringList.Create;
  Paths := TStringList.Create;
  try
    for Index := FFirstShown - 1 downto 0 do
    begin
      Names.Add(FCaptions[Index]);
      Paths.Add(FPaths[Index]);
    end;
    OpenMenu(MakePart(CrumbOverflow), Names, Paths);
  finally
    Names.Free;
    Paths.Free;
  end;
end;

procedure TBreadcrumbBar.MenuChosen(Item: TMenuItem);
begin
  if (Item.Tag < 0) or (Item.Tag >= FMenuPaths.Count) then
    Exit;
  if Assigned(FOnNavigate) then
    FOnNavigate(Self, FMenuPaths[Item.Tag]);
end;

procedure TBreadcrumbBar.MenuClosed(List: TMenuList);
begin
  FOpen := MakePart(CrumbNone);
  FPressed := MakePart(CrumbNone);
  Invalidate;
end;

{ --- editing ------------------------------------------------------------------- }

function TBreadcrumbBar.IsEditing: Boolean;
begin
  Result := FEditing;
end;

procedure TBreadcrumbBar.BeginEditing;
begin
  if FEditing then
    Exit;
  FEditing := True;
  FSettingText := True;
  FEdit.Text := FEditText;
  FSettingText := False;
  FEdit.Visible := True;
  FEdit.SetFocus;
  FEdit.SelectAll;
  Invalidate;
end;

procedure TBreadcrumbBar.CancelEditing;
begin
  EndEditing(False, '');
end;

procedure TBreadcrumbBar.EndEditing(Accept: Boolean; const Entered: string);
begin
  if not FEditing then
    Exit;
  FEditing := False;
  FSuggestions.Close;
  if FEdit.Focused and (Host <> nil) then
    Host.FocusControl(nil);
  FEdit.Visible := False;
  Invalidate;
  if Accept and Assigned(FOnPathEntered) then
    FOnPathEntered(Self, Entered);
end;

procedure TBreadcrumbBar.AskSuggestions;
var
  Suggestions: TStringList;
begin
  if not Assigned(FOnComplete) then
    Exit;
  Suggestions := TStringList.Create;
  try
    FOnComplete(Self, FEdit.Text, Suggestions);
    FSuggestions.Show(Suggestions);
  finally
    Suggestions.Free;
  end;
end;

procedure TBreadcrumbBar.EditChanged(Sender: TControl);
begin
  if FEditing and not FSettingText then
    AskSuggestions;
end;

procedure TBreadcrumbBar.EditFocusChanged(Sender: TControl);
begin
  if FEditing and not FEdit.Focused then
    EndEditing(False, '');
end;

procedure TBreadcrumbBar.SuggestionAccepted(Index: LongInt);
var
  Entered: string;
begin
  if Index >= 0 then
    Entered := FSuggestions.ChosenText
  else
    Entered := FEdit.Text;
  EndEditing(True, Entered);
end;

procedure TBreadcrumbBar.SuggestionCompleted(Index: LongInt);
var
  Completed: string;
begin
  Completed := FSuggestions.ChosenText;
  FSettingText := True;
  FEdit.Text := Completed;
  FEdit.SelectRange(CharacterCountOf(Completed), 0);
  FSettingText := False;
  AskSuggestions;
end;

function TBreadcrumbBar.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := False;
  if not FEditing then
    Exit;
  Result := True;
  if IsEnterKey(Code) then
    EndEditing(True, FEdit.Text)
  else if Code = KeyEscape then
    EndEditing(False, '')
  else if Code = KeyArrowDown then
    AskSuggestions
  else
    Result := False;
end;

{ --- the pointer ---------------------------------------------------------------- }

procedure TBreadcrumbBar.SetHot(const Part: TBreadcrumbPart);
begin
  if SamePart(Part, FHot) then
    Exit;
  FHot := Part;
  Invalidate;
end;

procedure TBreadcrumbBar.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Under: TBreadcrumbPart;
begin
  if (Button <> ButtonLeft) or FEditing then
    Exit;
  Under := PartAt(X, Y);
  case Under.Kind of
    CrumbSegment:
      begin
        FPressed := Under;
        Invalidate;
      end;
    CrumbChevron: OpenChildMenu(Under.Index);
    CrumbOverflow: OpenOverflowMenu;
    CrumbEmpty, CrumbRoot: BeginEditing;
  end;
end;

procedure TBreadcrumbBar.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if not FEditing then
    SetHot(PartAt(X, Y));
end;

procedure TBreadcrumbBar.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Pressed: TBreadcrumbPart;
begin
  if (Button <> ButtonLeft) or (FPressed.Kind <> CrumbSegment) then
    Exit;
  Pressed := FPressed;
  FPressed := MakePart(CrumbNone);
  Invalidate;
  if SamePart(PartAt(X, Y), Pressed) and Assigned(FOnNavigate) then
    FOnNavigate(Self, FPaths[Pressed.Index]);
end;

procedure TBreadcrumbBar.PointerLeave;
begin
  SetHot(MakePart(CrumbNone));
end;

{ --- painting ------------------------------------------------------------------- }

procedure TBreadcrumbBar.PaintPart(var Canvas: TCanvas; const Part: TBreadcrumbPart);
var
  Box: TRectangle;
  Look: TPartLook;
  Direction: TArrowDirection;
begin
  Box := PartBox(Part);
  if RectangleWidth(Box) <= 0 then
    Exit;
  Look := PartNormal;
  if SamePart(Part, FPressed) or SamePart(Part, FOpen) then
    Look := PartPressed
  else if SamePart(Part, FHot) then
    Look := PartHot;
  DrawPartFace(Canvas, InflateRectangle(Box, -Scaled(1)), Look);
  case Part.Kind of
    CrumbRoot: FImages.DrawInBox(Canvas, FRootImageIndex, MakeRectangle(Box.Left + (RectangleWidth(Box) -
      Scaled(SmallIconSize)) div 2, Box.Top + (RectangleHeight(Box) - Scaled(SmallIconSize)) div 2,
      Scaled(SmallIconSize), Scaled(SmallIconSize)));
    CrumbOverflow: DrawDoubleChevronGlyph(Canvas, Box, Scaled(ChevronGlyphSize), Theme.FieldText);
    CrumbSegment: DrawTextInBox(Canvas, ControlFace, FCaptions[Part.Index], InflateRectangle(Box,
      -Scaled(SegmentPadding)), AlignTextCenter, Theme.FieldText);
    CrumbChevron:
      begin
        Direction := ArrowRight;
        if SamePart(Part, FOpen) then
          Direction := ArrowDown;
        DrawChevronGlyph(Canvas, Box, Direction, Scaled(ChevronGlyphSize), Theme.FieldText);
      end;
  end;
end;

procedure TBreadcrumbBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Index: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
  if FEditing then
    Exit;
  Arrange;
  Inner := Canvas;
  NarrowCanvasClip(Inner, InnerBox);
  if HasRootImage then
    PaintPart(Inner, MakePart(CrumbRoot));
  if FFirstShown > 0 then
    PaintPart(Inner, MakePart(CrumbOverflow));
  for Index := FFirstShown to High(FCaptions) do
  begin
    PaintPart(Inner, MakePart(CrumbSegment, Index));
    PaintPart(Inner, MakePart(CrumbChevron, Index));
  end;
end;

end.

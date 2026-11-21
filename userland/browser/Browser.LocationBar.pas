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
  The location bar, in one field: at the left the site identity button
  (the page's icon; for a secure page also a lock and the site's name
  on a coloured band; a click opens the site information pop-up, and
  dragging it drags the page's address, to the bookmarks toolbar say),
  then the address, a drop-down of the pages visited last, and the star
  (filled when the page is bookmarked; a click bookmarks it, a click on
  a filled star edits the bookmark).

  Typing shows suggestions under it (the "AwesomeBar": OnSuggest gives
  the rows, title over address with a star for bookmarks): Up and Down
  move through them, Enter or a click goes to one. Enter goes to what
  was typed (Alt+Enter in a new tab; Ctrl+Enter adds "www." and ".com",
  Shift+Enter ".net"), Escape closes the suggestions and then puts the
  page's address back.
}
unit Browser.LocationBar;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Canvas,
  Drawing.Rectangles,
  Image.Model,
  Controls.Base,
  Controls.EditBox,
  Controls.ImageList,
  Controls.SuggestionPopup;

const
  { What dragging a page's address carries: the URL, a line break, the
    title. }
  DragFormatPageLink = 'browser-link';

type
  TLocationBar = class;

  { The rows to suggest for Typed, and each row's address. }
  TSuggestEvent = procedure(Sender: TLocationBar; const Typed: string; out Rows: TSuggestionRows;
    out Urls: TStringArray) of object;
  TNavigateEvent = procedure(Sender: TLocationBar; const Text: string; NewTab: Boolean) of object;

  TIdentityButton = class(TControl)
  private
    FBar: TLocationBar;
    FHot: Boolean;
    FPressX, FPressY: LongInt;
    FPressed: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    function PreferredSize: TSize; override;
  end;

  { The star and the drop marker. }
  TLocationGlyphKind = (GlyphStar, GlyphDropMarker);

  TLocationGlyph = class(TControl)
  private
    FBar: TLocationBar;
    FKind: TLocationGlyphKind;
    FHot: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  end;

  TLocationBar = class(TControl)
  private
    FIdentity: TIdentityButton;
    FEdit: TEditBox;
    FDropMarker: TLocationGlyph;
    FStar: TLocationGlyph;
    FPopup: TSuggestionPopup;
    FUrls: TStringArray;
    FFavicon: TImage;
    FSecureHost: string;
    FBookmarked: Boolean;
    FPageUrl: string;
    FPageTitle: string;
    FTyped: string;
    FSettingText: Boolean;
    FOnSuggest: TSuggestEvent;
    FOnDropDown: TSuggestEvent;
    FOnNavigate: TNavigateEvent;
    FOnRevert: TControlEvent;
    FOnIdentityClick: TControlEvent;
    FOnStarClick: TControlEvent;
    FOnEdited: TControlEvent;
    procedure EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure EditChanged(Sender: TControl);
    procedure SuggestionChosen(Sender: TObject; Index: LongInt);
    procedure ShowRows(const Rows: TSuggestionRows; const Urls: TStringArray);
    function GetText: string;
    procedure SetText(const Value: string);
    procedure SetBookmarked(Value: Boolean);
    procedure SetSecureHost(const Value: string);
    procedure SetFavicon(Value: TImage);
    procedure Go(const Text: string; NewTab: Boolean);
    function GetImages: TImageList;
    procedure SetImages(Value: TImageList);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PlaceChildren(const Area: TRectangle); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    procedure FocusAndSelect;
    procedure CloseSuggestions;
    { Shows the pages visited last under the bar. }
    procedure DropDown;
    property Text: string read GetText write SetText;
    property Edit: TEditBox read FEdit;
    property Identity: TIdentityButton read FIdentity;
    property StarButton: TLocationGlyph read FStar;
    property Popup: TSuggestionPopup read FPopup;
    { The page's icon (not owned; nil: a plain page). }
    property Favicon: TImage read FFavicon write SetFavicon;
    { For a secure page, the site's name shown on the identity button. }
    property SecureHost: string read FSecureHost write SetSecureHost;
    property Bookmarked: Boolean read FBookmarked write SetBookmarked;
    property PageUrl: string read FPageUrl write FPageUrl;
    property PageTitle: string read FPageTitle write FPageTitle;
    { The suggestions' pictures. }
    property Images: TImageList read GetImages write SetImages;
    property OnSuggest: TSuggestEvent read FOnSuggest write FOnSuggest;
    property OnDropDown: TSuggestEvent read FOnDropDown write FOnDropDown;
    property OnNavigate: TNavigateEvent read FOnNavigate write FOnNavigate;
    { Escape put the page's address back. }
    property OnRevert: TControlEvent read FOnRevert write FOnRevert;
    property OnIdentityClick: TControlEvent read FOnIdentityClick write FOnIdentityClick;
    property OnStarClick: TControlEvent read FOnStarClick write FOnStarClick;
    { The user changed the text. }
    property OnEdited: TControlEvent read FOnEdited write FOnEdited;
  end;

{ A five-pointed star filling Box (outline only unless Filled). }
procedure DrawBookmarkStar(const Canvas: TCanvas; const Box: TRectangle; Filled: Boolean; Fill, Outline: TColor);

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.SmoothLines,
  Image.Surfaces,
  Image.Scalable,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Window,
  Controls.Keys,
  Controls.Text,
  Controls.Painting,
  Controls.DragData,
  Controls.IconTheme,
  Controls.LayoutRules;

const
  BarHeight = 26;
  IconSize = 16;
  GlyphWidth = 20;
  DragThreshold = 4;

procedure DrawBookmarkStar(const Canvas: TCanvas; const Box: TRectangle; Filled: Boolean; Fill, Outline: TColor);
var
  CenterX, CenterY, Outer, Inner, Angle: Double;
  Points: array[0..9] of record X, Y: Double; end;
  Index, Row, Left, Right, Thickness: LongInt;
  Y, X1, X2, Crossing: Double;
  Crossings: array[0..9] of Double;
  Count, A, B: LongInt;
  Temp: Double;
begin
  CenterX := (Box.Left + Box.Right) / 2;
  CenterY := (Box.Top + Box.Bottom) / 2 + RectangleHeight(Box) * 0.05;
  Outer := Min(RectangleWidth(Box), RectangleHeight(Box)) / 2;
  Inner := Outer * 0.45;
  for Index := 0 to 9 do
  begin
    Angle := -Pi / 2 + Index * Pi / 5;
    if Odd(Index) then
    begin
      Points[Index].X := CenterX + Inner * Cos(Angle);
      Points[Index].Y := CenterY + Inner * Sin(Angle);
    end
    else
    begin
      Points[Index].X := CenterX + Outer * Cos(Angle);
      Points[Index].Y := CenterY + Outer * Sin(Angle);
    end;
  end;
  if Filled then
    { Scan lines through the polygon (even-odd). }
    for Row := Box.Top to Box.Bottom - 1 do
    begin
      Y := Row + 0.5;
      Count := 0;
      for Index := 0 to 9 do
      begin
        X1 := Points[Index].X;
        X2 := Points[(Index + 1) mod 10].X;
        if (Points[Index].Y <= Y) <> (Points[(Index + 1) mod 10].Y <= Y) then
        begin
          Crossing := X1 + (Y - Points[Index].Y) * (X2 - X1) / (Points[(Index + 1) mod 10].Y - Points[Index].Y);
          Crossings[Count] := Crossing;
          Inc(Count);
        end;
      end;
      for A := 0 to Count - 2 do
        for B := A + 1 to Count - 1 do
          if Crossings[B] < Crossings[A] then
          begin
            Temp := Crossings[A];
            Crossings[A] := Crossings[B];
            Crossings[B] := Temp;
          end;
      A := 0;
      while A + 1 < Count do
      begin
        Left := Round(Crossings[A]);
        Right := Round(Crossings[A + 1]);
        if Right > Left then
          FillRectangle(Canvas, MakeRectangle(Left, Row, Right - Left, 1), Fill);
        Inc(A, 2);
      end;
    end;
  Thickness := Max(1, Scaled(10) div 10);
  for Index := 0 to 9 do
    DrawSmoothLine(Canvas, Round(Points[Index].X), Round(Points[Index].Y), Round(Points[(Index + 1) mod 10].X),
      Round(Points[(Index + 1) mod 10].Y), Thickness, Outline);
end;

{ ---- the identity button ---- }

function TIdentityButton.PreferredSize: TSize;
begin
  Result := MakeSize(IconSize + 8, BarHeight - 4);
  if FBar.FSecureHost <> '' then
    Result.Width := Result.Width + IconSize + PixelsToLogicalCeiling(TextWidth(ControlFace, FBar.FSecureHost)) + 8;
end;

procedure TIdentityButton.Paint(var Canvas: TCanvas);
var
  Box, IconBox, TextBox: TRectangle;
  Size: LongInt;
  Icon: TImage;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  TextColor := Theme.FieldText;
  if FBar.FSecureHost <> '' then
  begin
    { A secure site: its name on a band of the selection's colour. }
    FillRectangle(Canvas, Box, MixColors(Theme.Selection, Theme.Field, 200));
    TextColor := Theme.SelectionText;
  end
  else if FHot then
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
  if FHot then
    DrawRaisedEdge(Canvas, Box);
  Size := Scaled(IconSize);
  IconBox := MakeRectangle(Box.Left + Scaled(4), Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size);
  Icon := FBar.FFavicon;
  if Icon <> nil then
  begin
    if Icon is TScalableImage then
      Icon := TScalableImage(Icon).RenderedAt(Size, Size);
    if Icon = nil then
      Icon := FBar.FFavicon;
    DrawSurfaceScaled(Canvas, ImageSurface(Icon), MakeRectangle(0, 0, Icon.Width, Icon.Height), IconBox, True);
  end
  else if not DrawThemeIcon(Canvas, 'internet', IconBox) then
    DrawRectangleOutline(Canvas, IconBox, Theme.Shadow);
  if FBar.FSecureHost = '' then
    Exit;
  IconBox := OffsetRectangle(IconBox, Size + Scaled(2), 0);
  DrawThemeIcon(Canvas, 'action-lock', IconBox);
  TextBox := MakeRectangle(IconBox.Right + Scaled(3), Box.Top, Box.Right - IconBox.Right - Scaled(4),
    RectangleHeight(Box));
  DrawTextInBox(Canvas, ControlBoldFace, FBar.FSecureHost, TextBox, AlignTextLeft, TextColor);
end;

procedure TIdentityButton.PointerEnter;
begin
  FHot := True;
  Invalidate;
end;

procedure TIdentityButton.PointerLeave;
begin
  FHot := False;
  Invalidate;
end;

procedure TIdentityButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  FPressed := Button = ButtonLeft;
  FPressX := X;
  FPressY := Y;
end;

procedure TIdentityButton.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  inherited PointerMove(X, Y, Buttons);
  if not FPressed or ((Buttons and ButtonLeft) = 0) or (FBar.FPageUrl = '') then
    Exit;
  if (Abs(X - FPressX) < Scaled(DragThreshold)) and (Abs(Y - FPressY) < Scaled(DragThreshold)) then
    Exit;
  FPressed := False;
  BeginDrag(TDragData.Create(DragFormatPageLink, FBar.FPageUrl + #10 + FBar.FPageTitle, FBar));
end;

procedure TIdentityButton.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if FPressed and (Button = ButtonLeft) and Assigned(FBar.FOnIdentityClick) then
    FBar.FOnIdentityClick(FBar);
  FPressed := False;
end;

{ ---- the star and the drop marker ---- }

procedure TLocationGlyph.Paint(var Canvas: TCanvas);
var
  Box, Star: TRectangle;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FHot then
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
  case FKind of
    GlyphDropMarker:
      DrawArrowGlyph(Canvas, Box, ArrowDown, Max(2, Scaled(3)), Theme.FieldText);
    GlyphStar:
      begin
        Size := Min(Scaled(14), RectangleHeight(Box) - Scaled(4));
        Star := MakeRectangle(Box.Left + (RectangleWidth(Box) - Size) div 2, Box.Top + (RectangleHeight(Box) - Size) div 2,
          Size, Size);
        if FBar.FBookmarked then
          DrawBookmarkStar(Canvas, Star, True, Theme.ActiveTitleStart, Theme.DarkShadow)
        else
          DrawBookmarkStar(Canvas, Star, False, Theme.Field, Theme.Shadow);
      end;
  end;
end;

procedure TLocationGlyph.PointerEnter;
begin
  FHot := True;
  Invalidate;
end;

procedure TLocationGlyph.PointerLeave;
begin
  FHot := False;
  Invalidate;
end;

procedure TLocationGlyph.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  case FKind of
    GlyphDropMarker:
      FBar.DropDown;
    GlyphStar:
      if Assigned(FBar.FOnStarClick) then
        FBar.FOnStarClick(FBar);
  end;
end;

{ ---- the bar ---- }

constructor TLocationBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FIdentity := TIdentityButton.Create(Self);
  FIdentity.FBar := Self;
  FIdentity.Hint := 'Site information';
  FEdit := TEditBox.Create(Self);
  FEdit.Borderless := True;
  FEdit.OnKeyDown := @EditKey;
  FEdit.OnChange := @EditChanged;
  FEdit.Hint := 'Type an address, or words to look for in your history and bookmarks (Ctrl+L)';
  FDropMarker := TLocationGlyph.Create(Self);
  FDropMarker.FBar := Self;
  FDropMarker.FKind := GlyphDropMarker;
  FDropMarker.Hint := 'Pages visited last';
  FStar := TLocationGlyph.Create(Self);
  FStar.FBar := Self;
  FStar.FKind := GlyphStar;
  FStar.Hint := 'Bookmark this page (Ctrl+D)';
  FPopup := TSuggestionPopup.Create(FEdit);
  FPopup.OnChoose := @SuggestionChosen;
  SetBounds(0, 0, 300, BarHeight);
end;

destructor TLocationBar.Destroy;
begin
  FPopup.Free;
  inherited Destroy;
end;

function TLocationBar.PreferredSize: TSize;
begin
  Result := MakeSize(300, BarHeight);
end;

function TLocationBar.GetImages: TImageList;
begin
  Result := FPopup.Images;
end;

procedure TLocationBar.SetImages(Value: TImageList);
begin
  FPopup.Images := Value;
end;

procedure TLocationBar.PlaceChildren(const Area: TRectangle);
var
  Inner: TRectangle;
  IdentityWidth, Glyph: LongInt;
begin
  Inner := InflateRectangle(Area, -BevelWidth);
  IdentityWidth := Scaled(ChildSize(FIdentity).Width);
  Glyph := Scaled(GlyphWidth);
  PlaceChild(FIdentity, MakeRectangle(Inner.Left, Inner.Top, IdentityWidth, RectangleHeight(Inner)));
  PlaceChild(FStar, MakeRectangle(Inner.Right - Glyph, Inner.Top, Glyph, RectangleHeight(Inner)));
  PlaceChild(FDropMarker, MakeRectangle(Inner.Right - 2 * Glyph, Inner.Top, Glyph, RectangleHeight(Inner)));
  PlaceChild(FEdit, MakeRectangle(Inner.Left + IdentityWidth + Scaled(2), Inner.Top,
    Max(0, RectangleWidth(Inner) - IdentityWidth - 2 * Glyph - Scaled(2)), RectangleHeight(Inner)));
end;

procedure TLocationBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
end;

function TLocationBar.GetText: string;
begin
  Result := FEdit.Text;
end;

procedure TLocationBar.SetText(const Value: string);
begin
  if FEdit.Text = Value then
    Exit;
  FSettingText := True;
  try
    FEdit.Text := Value;
  finally
    FSettingText := False;
  end;
end;

procedure TLocationBar.SetBookmarked(Value: Boolean);
begin
  if FBookmarked = Value then
    Exit;
  FBookmarked := Value;
  if Value then
    FStar.Hint := 'Edit this bookmark'
  else
    FStar.Hint := 'Bookmark this page (Ctrl+D)';
  FStar.Invalidate;
end;

procedure TLocationBar.SetSecureHost(const Value: string);
begin
  if FSecureHost = Value then
    Exit;
  FSecureHost := Value;
  if Value <> '' then
    FIdentity.Hint := 'Verified secure connection to ' + Value + ': click for more'
  else
    FIdentity.Hint := 'Site information';
  RequestLayout;
  Invalidate;
end;

procedure TLocationBar.SetFavicon(Value: TImage);
begin
  FFavicon := Value;
  FIdentity.Invalidate;
end;

procedure TLocationBar.FocusAndSelect;
begin
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    TControlWindow(Host.OwnerWindow).FocusControl(FEdit);
  FEdit.SelectAll;
end;

procedure TLocationBar.CloseSuggestions;
begin
  FPopup.Close;
end;

procedure TLocationBar.ShowRows(const Rows: TSuggestionRows; const Urls: TStringArray);
begin
  FUrls := Urls;
  FPopup.ShowRows(Rows);
end;

procedure TLocationBar.DropDown;
var
  Rows: TSuggestionRows;
  Urls: TStringArray;
begin
  if FPopup.IsOpen then
  begin
    FPopup.Close;
    Exit;
  end;
  if not Assigned(FOnDropDown) then
    Exit;
  FOnDropDown(Self, '', Rows, Urls);
  ShowRows(Rows, Urls);
end;

procedure TLocationBar.Go(const Text: string; NewTab: Boolean);
begin
  FPopup.Close;
  if Assigned(FOnNavigate) then
    FOnNavigate(Self, Text, NewTab);
end;

procedure TLocationBar.SuggestionChosen(Sender: TObject; Index: LongInt);
var
  Url: string;
begin
  if (Index < 0) or (Index > High(FUrls)) then
    Exit;
  Url := FUrls[Index];
  Text := Url;
  Go(Url, (HeldModifiers and ModifierControl) <> 0);
end;

procedure TLocationBar.EditChanged(Sender: TControl);
var
  Rows: TSuggestionRows;
  Urls: TStringArray;
begin
  if FSettingText then
    Exit;
  FTyped := FEdit.Text;
  if Assigned(FOnEdited) then
    FOnEdited(Self);
  if not FEdit.Focused then
    Exit;
  if (Trim(FTyped) = '') or not Assigned(FOnSuggest) then
  begin
    FPopup.Close;
    Exit;
  end;
  FOnSuggest(Self, FTyped, Rows, Urls);
  ShowRows(Rows, Urls);
end;

procedure TLocationBar.EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
var
  Typed: string;
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    if FPopup.IsOpen and (FPopup.Highlighted >= 0) then
    begin
      SuggestionChosen(FPopup, FPopup.Highlighted);
      Exit;
    end;
    Typed := Trim(FEdit.Text);
    if ((Modifiers and ModifierControl) <> 0) and (Typed <> '') and (Pos('.', Typed) = 0) and (Pos(' ', Typed) = 0) then
      Typed := 'www.' + Typed + '.com'
    else if ((Modifiers and ModifierShift) <> 0) and (Typed <> '') and (Pos('.', Typed) = 0) and
            (Pos(' ', Typed) = 0) then
      Typed := 'www.' + Typed + '.net';
    Go(Typed, (Modifiers and ModifierAlt) <> 0);
  end
  else if Code = KeyEscape then
  begin
    Handled := True;
    if FPopup.IsOpen then
      FPopup.Close
    else if Assigned(FOnRevert) then
      FOnRevert(Self);
  end
  else if (Code = KeyArrowDown) or (Code = KeyArrowUp) then
  begin
    Handled := True;
    if not FPopup.IsOpen then
    begin
      if Code = KeyArrowDown then
        DropDown;
      Exit;
    end;
    if Code = KeyArrowDown then
      FPopup.MoveHighlight(1)
    else
      FPopup.MoveHighlight(-1);
    { The highlighted page's address in the field, as the old bars did;
      off the list, what was typed. }
    FSettingText := True;
    try
      if (FPopup.Highlighted >= 0) and (FPopup.Highlighted <= High(FUrls)) then
        FEdit.Text := FUrls[FPopup.Highlighted]
      else
        FEdit.Text := FTyped;
      FEdit.SelectRange(Length(FEdit.Text), 0);
    finally
      FSettingText := False;
    end;
  end;
end;

end.

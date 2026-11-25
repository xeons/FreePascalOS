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

{ WebView.Engine: find in page - the next match (wrapping, counted) and
  every match highlighted. The highlights are text index places, found
  again whenever the index is built again (a layout that changed the
  text's runs), and painted over the backing like the selection, in
  device pixels (CSS pixels times the device scale). }

const
  { More matches than this: the count is unknown (-1). }
  MatchCountLimit = 100000;
  { A soft yellow under the selection's colour, whatever the theme. }
  FindHighlightColor = $FFFFD23F;
  FindHighlightAlpha = 120;

function TWebEngineView.FindText(const Needle: string; Forward, MatchCase: Boolean): Boolean;
var
  Wrapped: Boolean;
  MatchCount: Integer;
begin
  Result := FindTextDetailed(Needle, Forward, MatchCase, Wrapped, MatchCount);
end;

function TWebEngineView.FindTextDetailed(const Needle: string; Forward, MatchCase: Boolean; out Wrapped: Boolean;
  out MatchCount: Integer): Boolean;
var
  From, MatchStart, MatchEnd, Anchor, Focus: TTextPosition;
  Rectangles: TTextRectangleArray;
  Matches: TTextMatchArray;
begin
  Result := False;
  Wrapped := False;
  MatchCount := 0;
  if (FLayout = nil) or (Needle = '') then
    Exit;
  EnsureTextIndex;
  Matches := FSelection.Index.AllMatches(Needle, MatchCase, MatchCountLimit + 1);
  if Length(Matches) > MatchCountLimit then
    MatchCount := -1
  else
    MatchCount := Length(Matches);
  From := TextPosition(-1, 0);
  if FSelection.HasSelection then
  begin
    Anchor := FSelection.Anchor;
    Focus := FSelection.Focus;
    { Again: after the match shown (or before it). }
    if Forward = (TPageTextIndex.Compare(Anchor, Focus) < 0) then
      From := Focus
    else
      From := Anchor;
    if (Needle <> FFindText) then
      if TPageTextIndex.Compare(Anchor, Focus) < 0 then
        From := Anchor
      else
        From := Focus;
  end;
  FFindText := Needle;
  if not FSelection.Index.FindWrapping(Needle, From, Forward, MatchCase, MatchStart, MatchEnd, Wrapped) then
    Exit;
  SetSelection(MatchStart, MatchEnd);
  Rectangles := FSelection.Index.RangeRectangles(MatchStart, MatchEnd, TextViewport);
  if (Length(Rectangles) > 0) and not Rectangles[0].Fixed then
    ScrollRectangleIntoView(Rectangles[0].X, Rectangles[0].Y, Rectangles[0].Width, Rectangles[0].Height);
  Result := True;
end;

procedure TWebEngineView.SetFindHighlight(const Needle: string; MatchCase: Boolean);
begin
  if (Needle = FHighlightNeedle) and (MatchCase = FHighlightMatchCase) then
    Exit;
  FHighlightNeedle := Needle;
  FHighlightMatchCase := MatchCase;
  FHighlights := nil;
  FHighlightsValid := False;
  InvalidateViewport;
end;

{ The matches of the highlighted needle in the index as it is now. }
procedure TWebEngineView.EnsureHighlights;
begin
  if FHighlightNeedle = '' then
  begin
    FHighlights := nil;
    Exit;
  end;
  if FHighlightsValid and (FHighlightGeneration = FSelection.IndexGeneration) then
    Exit;
  FHighlights := FSelection.Index.AllMatches(FHighlightNeedle, FHighlightMatchCase, MatchCountLimit);
  FHighlightGeneration := FSelection.IndexGeneration;
  FHighlightsValid := True;
end;

{ Text rectangles (document CSS pixels; viewport ones for fixed text)
  filled in device pixels at the scroll offset now. }
procedure TWebEngineView.PaintTextRectangles(var Canvas: TCanvas; constref Rectangles: TTextRectangleArray;
  Color: LongWord);
var
  Index: Integer;
  Scale: Double;
  View: TTextViewport;
  OffsetX, OffsetY: Double;
  Area: TRectangle;
begin
  Scale := DeviceScale;
  View := TextViewport;
  for Index := 0 to High(Rectangles) do
  begin
    OffsetX := View.ScrollX;
    OffsetY := View.ScrollY;
    if Rectangles[Index].Fixed then
    begin
      OffsetX := 0;
      OffsetY := 0;
    end;
    Area.Left := Floor((Rectangles[Index].X - OffsetX) * Scale);
    Area.Top := Floor((Rectangles[Index].Y - OffsetY) * Scale);
    Area.Right := Ceil((Rectangles[Index].X + Rectangles[Index].Width - OffsetX) * Scale);
    Area.Bottom := Ceil((Rectangles[Index].Y + Rectangles[Index].Height - OffsetY) * Scale);
    FillRectangle(Canvas, Area, Color);
  end;
end;

{ Only the matches whose runs may be on the screen are measured: runs in
  no group are skipped by their place, the others (fixed, sticky,
  transformed) always measured. }
procedure TWebEngineView.PaintFindHighlights(var Canvas: TCanvas);
var
  View: TTextViewport;
  Index: Integer;
  First, Last: PTextRunEntry;
  Color: LongWord;
begin
  if (FLayout = nil) or (FHighlightNeedle = '') then
    Exit;
  EnsureHighlights;
  if Length(FHighlights) = 0 then
    Exit;
  View := TextViewport;
  Color := WithAlpha(FindHighlightColor, FindHighlightAlpha);
  for Index := 0 to High(FHighlights) do
  begin
    First := FSelection.Index.Run(FHighlights[Index].Start.Run);
    Last := FSelection.Index.Run(FHighlights[Index].Finish.Run);
    if not First^.Fixed and not Last^.Fixed and (First^.Group < 0) and (Last^.Group < 0) and
       ((Last^.Y + Last^.Height < View.ScrollY) or (First^.Y > View.ScrollY + View.Height)) then
      Continue;
    PaintTextRectangles(Canvas, FSelection.Index.RangeRectangles(FHighlights[Index].Start, FHighlights[Index].Finish,
      View), Color);
  end;
end;

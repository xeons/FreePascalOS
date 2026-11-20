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

{ WebView.Control: the text index, selection, copying and finding. }

function ValidPosition(Index: TPageTextIndex; constref Position: TTextPosition): Boolean;
begin
  Result := (Position.Run >= 0) and (Position.Run < Index.Count) and (Position.Offset >= 0) and
    (Position.Offset <= Index.Run(Position.Run)^.TextLength);
end;

{ The index follows the display list; a selection that no longer fits
  the new runs goes. }
procedure TWebView.EnsureTextIndex;
begin
  if FPainter = nil then
  begin
    FTextIndex.Clear;
    Exit;
  end;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  FPainter.Refresh;
  if FTextIndexValid and (FTextIndexVersion = FPainter.BuiltVersion) then
    Exit;
  FTextIndex.Build(FPainter.DisplayList);
  FTextIndexVersion := FPainter.BuiltVersion;
  FTextIndexValid := True;
  if not ValidPosition(FTextIndex, FSelectionAnchor) or not ValidPosition(FTextIndex, FSelectionFocus) then
  begin
    FSelectionAnchor := TextPosition(-1, 0);
    FSelectionFocus := FSelectionAnchor;
  end;
end;

function TWebView.TextPositionAt(X, Y: LongInt): TTextPosition;
var
  Scale: Double;
  ScrollX, ScrollY: Single;
begin
  Result := TextPosition(-1, 0);
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Scale := DeviceScale;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Result := FTextIndex.PositionAt(X / Scale + ScrollX, Y / Scale + ScrollY, ScrollX, ScrollY);
end;

procedure TWebView.SetSelection(constref Anchor, Focus: TTextPosition);
begin
  if (TPageTextIndex.Compare(Anchor, FSelectionAnchor) = 0) and (TPageTextIndex.Compare(Focus, FSelectionFocus) = 0)
     and (Anchor.Run = FSelectionAnchor.Run) then
    Exit;
  FSelectionAnchor := Anchor;
  FSelectionFocus := Focus;
  InvalidateViewport;
end;

procedure TWebView.ClearSelection;
begin
  SetSelection(TextPosition(-1, 0), TextPosition(-1, 0));
end;

procedure TWebView.SelectAll;
begin
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  SetSelection(FTextIndex.FirstPosition, FTextIndex.LastPosition);
end;

function TWebView.HasSelection: Boolean;
begin
  Result := (FSelectionAnchor.Run >= 0) and (FSelectionFocus.Run >= 0) and
    (TPageTextIndex.Compare(FSelectionAnchor, FSelectionFocus) <> 0);
end;

function TWebView.SelectedText: string;
begin
  Result := '';
  if not HasSelection then
    Exit;
  EnsureTextIndex;
  if HasSelection then
    Result := FTextIndex.TextBetween(FSelectionAnchor, FSelectionFocus);
end;

procedure TWebView.CopySelection;
var
  Chosen: string;
begin
  Chosen := SelectedText;
  if Chosen <> '' then
    SetClipboardText(Chosen);
end;

function TWebView.PageText: string;
begin
  Result := '';
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Result := FTextIndex.AllText;
end;

function TWebView.FindText(const Needle: string; Forward, MatchCase: Boolean): Boolean;
var
  From, MatchStart, MatchEnd: TTextPosition;
  Rectangles: TTextRectangleArray;
  ScrollX, ScrollY: Single;
begin
  Result := False;
  if (FLayout = nil) or (Needle = '') then
    Exit;
  EnsureTextIndex;
  From := TextPosition(-1, 0);
  if HasSelection then
  begin
    { Again: after the match shown (or before it). }
    if Forward = (TPageTextIndex.Compare(FSelectionAnchor, FSelectionFocus) < 0) then
      From := FSelectionFocus
    else
      From := FSelectionAnchor;
    if (Needle <> FFindText) then
      if TPageTextIndex.Compare(FSelectionAnchor, FSelectionFocus) < 0 then
        From := FSelectionAnchor
      else
        From := FSelectionFocus;
  end;
  FFindText := Needle;
  if not FTextIndex.Find(Needle, From, Forward, MatchCase, MatchStart, MatchEnd) then
    Exit;
  SetSelection(MatchStart, MatchEnd);
  Rectangles := FTextIndex.RangeRectangles(MatchStart, MatchEnd);
  if (Length(Rectangles) > 0) and not Rectangles[0].Fixed then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    ScrollRectangleIntoView(Rectangles[0].X, Rectangles[0].Y, Rectangles[0].Width, Rectangles[0].Height);
  end;
  Result := True;
end;

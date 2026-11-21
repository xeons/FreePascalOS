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

{ The index follows the display list of the layout as it is now
  (TPageSelection rebuilds it when the layout changed and takes the
  selection from the document's again). }
procedure TWebView.EnsureTextIndex;
begin
  if (FLayout <> nil) and FLayout.NeedsUpdate then
    UpdateLayout;
  FSelection.Refresh;
end;

function TWebView.TextViewport: TTextViewport;
begin
  Result := ViewportOfLayout(FLayout);
end;

procedure TWebView.DocumentSelectionChanged;
begin
  if FSelection.DocumentSelectionChanged then
    InvalidateViewport;
end;

function TWebView.TextPositionAt(X, Y: LongInt): TTextPosition;
var
  Scale: Double;
  View: TTextViewport;
begin
  Result := TextPosition(-1, 0);
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Scale := DeviceScale;
  View := TextViewport;
  Result := FSelection.PositionAt(X / Scale + View.ScrollX, Y / Scale + View.ScrollY, View);
end;

procedure TWebView.SetSelection(constref Anchor, Focus: TTextPosition);
begin
  if FSelection.Select(Anchor, Focus) then
    InvalidateViewport;
end;

procedure TWebView.ExtendSelectionTo(X, Y: LongInt);
var
  Focus: TTextPosition;
begin
  { The place is found in the index as it is now; the anchor kept is
    the one the index (rebuilt if the layout changed) has now. }
  Focus := TextPositionAt(X, Y);
  if (Focus.Run >= 0) and FSelection.Extend(Focus) then
    InvalidateViewport;
end;

function TWebView.AutoscrollSelection: Boolean;
var
  Scale: Double;
  Delta: Double;
begin
  Result := False;
  if not FSelecting or not FDragged or (FPressButton <> ButtonLeft) or (FLayout = nil) then
    Exit;
  Scale := DeviceScale;
  Delta := 0;
  if FLastPointerY < 0 then
    Delta := FLastPointerY / Scale
  else if FLastPointerY > ViewportPixelHeight then
    Delta := (FLastPointerY - ViewportPixelHeight) / Scale;
  if Delta = 0 then
    Exit;
  ScrollBy(0, Delta);
  ExtendSelectionTo(FLastPointerX, FLastPointerY);
  Result := True;
end;

procedure TWebView.ClearSelection;
begin
  if FSelection.Clear then
    InvalidateViewport;
end;

procedure TWebView.SelectAll;
begin
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  if FSelection.SelectAll then
    InvalidateViewport;
end;

function TWebView.HasSelection: Boolean;
begin
  if FLayout <> nil then
    EnsureTextIndex;
  Result := FSelection.HasSelection;
end;

function TWebView.SelectedText: string;
begin
  Result := '';
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Result := FSelection.SelectedText;
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
  Result := FSelection.Index.AllText;
end;

function TWebView.FindText(const Needle: string; Forward, MatchCase: Boolean): Boolean;
var
  From, MatchStart, MatchEnd, Anchor, Focus: TTextPosition;
  Rectangles: TTextRectangleArray;
begin
  Result := False;
  if (FLayout = nil) or (Needle = '') then
    Exit;
  EnsureTextIndex;
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
  if not FSelection.Index.Find(Needle, From, Forward, MatchCase, MatchStart, MatchEnd) then
    Exit;
  SetSelection(MatchStart, MatchEnd);
  Rectangles := FSelection.Index.RangeRectangles(MatchStart, MatchEnd, TextViewport);
  if (Length(Rectangles) > 0) and not Rectangles[0].Fixed then
    ScrollRectangleIntoView(Rectangles[0].X, Rectangles[0].Y, Rectangles[0].Width, Rectangles[0].Height);
  Result := True;
end;

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

{ WebView.Engine: the text index, selection and copying (finding is in
  WebView.Engine.Find.inc). }

{ The index follows the display list of the layout as it is now
  (TPageSelection rebuilds it when the layout changed and takes the
  selection from the document's again). }
procedure TWebEngineView.EnsureTextIndex;
begin
  if (FLayout <> nil) and FLayout.NeedsUpdate then
    UpdateLayout;
  FSelection.Refresh;
end;

function TWebEngineView.TextViewport: TTextViewport;
begin
  Result := ViewportOfLayout(FLayout);
end;

procedure TWebEngineView.DocumentSelectionChanged;
begin
  if FSelection.DocumentSelectionChanged then
    InvalidateViewport;
  SelectionChanged;
end;

procedure TWebEngineView.SelectionChanged;
begin
  if Assigned(FOnSelectionChanged) then
    FOnSelectionChanged(Self);
end;

function TWebEngineView.TextPositionAt(X, Y: LongInt): TTextPosition;
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

procedure TWebEngineView.SetSelection(constref Anchor, Focus: TTextPosition);
begin
  if FSelection.Select(Anchor, Focus) then
  begin
    InvalidateViewport;
    SelectionChanged;
  end;
end;

procedure TWebEngineView.ExtendSelectionTo(X, Y: LongInt);
var
  Focus: TTextPosition;
begin
  { The place is found in the index as it is now; the anchor kept is
    the one the index (rebuilt if the layout changed) has now. }
  Focus := TextPositionAt(X, Y);
  if (Focus.Run >= 0) and FSelection.Extend(Focus) then
  begin
    InvalidateViewport;
    SelectionChanged;
  end;
end;

function TWebEngineView.AutoscrollSelection: Boolean;
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

procedure TWebEngineView.ClearSelection;
begin
  if FSelection.Clear then
  begin
    InvalidateViewport;
    SelectionChanged;
  end;
end;

procedure TWebEngineView.SelectAll;
begin
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  if FSelection.SelectAll then
  begin
    InvalidateViewport;
    SelectionChanged;
  end;
end;

function TWebEngineView.HasSelection: Boolean;
begin
  if FLayout <> nil then
    EnsureTextIndex;
  Result := FSelection.HasSelection;
end;

function TWebEngineView.SelectedText: string;
begin
  Result := '';
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Result := FSelection.SelectedText;
end;

procedure TWebEngineView.CopySelection;
var
  Chosen: string;
begin
  Chosen := SelectedText;
  if Chosen <> '' then
    WriteClipboard(Chosen);
end;

function TWebEngineView.PageText: string;
begin
  Result := '';
  if FLayout = nil then
    Exit;
  EnsureTextIndex;
  Result := FSelection.Index.AllText;
end;

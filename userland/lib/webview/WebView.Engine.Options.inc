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

{ WebView.Engine: what a browser's View menu sets - images, zooming the
  text only, the page's own styles, the character encoding - and
  window.open with its pop-up blocking. }

const
  { A click or key this recent lets window.open through. }
  UserGestureMilliseconds = 1000;

{ The layout's share of the options: text zoom and author styles. }
procedure TWebEngineView.ApplyDocumentOptions;
begin
  if FLayout = nil then
    Exit;
  if FTextOnlyZoom then
    FLayout.SetTextZoom(FZoom)
  else
    FLayout.SetTextZoom(1);
  FLayout.SetAuthorStylesEnabled(FAuthorStylesEnabled);
end;

{ The navigable's share: images and the encoding, from its next
  document on. }
procedure TWebEngineView.ApplyLoadingSettings;
var
  Settings: TLoadingSettings;
begin
  if FPage = nil then
    Exit;
  Settings := FPage.Navigable.Settings;
  Settings.LoadImages := FImagesEnabled;
  FPage.Navigable.Settings := Settings;
  FPage.Navigable.EncodingOverride := FEncodingOverride;
end;

procedure TWebEngineView.SetImagesEnabled(Value: Boolean);
begin
  FImagesEnabled := Value;
  ApplyLoadingSettings;
end;

procedure TWebEngineView.SetTextOnlyZoom(Value: Boolean);
var
  ScrollX, ScrollY: Single;
  Ratio: Double;
begin
  if Value = FTextOnlyZoom then
    Exit;
  ScrollX := 0;
  ScrollY := 0;
  Ratio := 0;
  if FLayout <> nil then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    if FLayout.DocumentHeight > 0 then
      Ratio := ScrollY / FLayout.DocumentHeight;
  end;
  FTextOnlyZoom := Value;
  ApplyViewport;
  ApplyDocumentOptions;
  if FLayout <> nil then
  begin
    UpdateLayout(True);
    ScrollViewportTo(ScrollX, Ratio * FLayout.DocumentHeight);
  end;
  InvalidateViewport;
end;

procedure TWebEngineView.SetAuthorStylesEnabled(Value: Boolean);
begin
  if Value = FAuthorStylesEnabled then
    Exit;
  FAuthorStylesEnabled := Value;
  ApplyDocumentOptions;
  RequestFrame;
  InvalidateViewport;
end;

procedure TWebEngineView.SetEncodingOverride(const Value: string);
begin
  if Value = FEncodingOverride then
    Exit;
  FEncodingOverride := Value;
  ApplyLoadingSettings;
  { The document again, decoded the new way (not before there is one). }
  if (FPage <> nil) and (FUrl <> '') and (FUrl <> 'about:blank') then
    Reload(False);
end;

procedure TWebEngineView.NoteUserGesture;
begin
  FLastUserGesture := GetTickCount64;
end;

function TWebEngineView.HasUserGesture: Boolean;
begin
  Result := (FLastUserGesture <> 0) and (GetTickCount64 - FLastUserGesture <= UserGestureMilliseconds);
end;

{ window.open for anything but _self: a frame of the page or an open
  name navigates there; anything else is a new tab (or a new window
  when features were given), which the host opens (OnLinkClicked) -
  unless pop-ups are blocked and nobody clicked or typed just now. }
function TWebEngineView.ScriptOpenWindow(const Url, Target, Features: string): Boolean;
var
  TargetNavigable: TNavigable;
  Parsed: TUrlRecord;
  Options: TNavigateOptions;
  Disposition: TLinkDisposition;
  Handled: Boolean;
  LowerTarget: string;
begin
  Result := False;
  if (FPage = nil) or not ParseUrl(Url, Parsed) or (Parsed.Scheme = 'javascript') then
    Exit;
  LowerTarget := LowerCase(Target);
  TargetNavigable := nil;
  if (LowerTarget <> '_blank') and (LowerTarget <> '') then
    TargetNavigable := FPage.Navigable.ChooseNavigable(Target);
  if TargetNavigable <> nil then
  begin
    Options := DefaultNavigateOptions;
    Options.Source := FPage.Navigable.Loader;
    TargetNavigable.Navigate(Parsed, Options);
    PostWake;
    Exit(True);
  end;
  if FPopupsBlocked and not HasUserGesture then
  begin
    if Assigned(FOnPopupBlocked) then
      FOnPopupBlocked(Self, Url);
    Exit;
  end;
  { One window per gesture. }
  FLastUserGesture := 0;
  if Trim(Features) <> '' then
    Disposition := LinkInNewWindow
  else
    Disposition := LinkInNewTab;
  Handled := False;
  if Assigned(FOnLinkClicked) then
    FOnLinkClicked(Self, Url, Disposition, Handled);
  Result := Handled;
end;

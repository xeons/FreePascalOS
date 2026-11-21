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

{ WebView.Control: the display options (images, text-only zoom, the
  page's styles, the encoding, pop-ups), the find highlight, find's
  details and Page Info, in the program or through the content process. }

function SupportedEncodings: TStringArray;
var
  Names: TEncodingNameArray;
  Index: Integer;
begin
  Names := SelectableEncodingNames;
  Result := nil;
  SetLength(Result, Length(Names));
  for Index := 0 to High(Names) do
    Result[Index] := Names[Index];
end;

{ Every option at once: after a new view in a process, and when one
  changes. }
procedure TWebView.SendDisplayOptions;
var
  Options: TIpcDisplayOptions;
begin
  Options.ImagesEnabled := FImagesEnabled;
  Options.TextOnlyZoom := FTextOnlyZoom;
  Options.AuthorStylesEnabled := FAuthorStylesEnabled;
  Options.PopupsBlocked := FPopupsBlocked;
  Options.EncodingOverride := FEncodingOverride;
  SendToProcess(IpcSetDisplayOptions, EncodeDisplayOptions(Options));
end;

procedure TWebView.ApplyEngineOptions;
begin
  if FEngine = nil then
    Exit;
  FEngine.ImagesEnabled := FImagesEnabled;
  FEngine.TextOnlyZoom := FTextOnlyZoom;
  FEngine.AuthorStylesEnabled := FAuthorStylesEnabled;
  FEngine.PopupsBlocked := FPopupsBlocked;
  FEngine.EncodingOverride := FEncodingOverride;
end;

procedure TWebView.SetImagesEnabled(Value: Boolean);
begin
  if Value = FImagesEnabled then
    Exit;
  FImagesEnabled := Value;
  if FEngine <> nil then
    ApplyEngineOptions
  else
    SendDisplayOptions;
end;

procedure TWebView.SetTextOnlyZoom(Value: Boolean);
begin
  if Value = FTextOnlyZoom then
    Exit;
  FTextOnlyZoom := Value;
  if FEngine <> nil then
    ApplyEngineOptions
  else
    SendDisplayOptions;
end;

procedure TWebView.SetAuthorStylesEnabled(Value: Boolean);
begin
  if Value = FAuthorStylesEnabled then
    Exit;
  FAuthorStylesEnabled := Value;
  if FEngine <> nil then
    ApplyEngineOptions
  else
    SendDisplayOptions;
end;

procedure TWebView.SetPopupsBlocked(Value: Boolean);
begin
  if Value = FPopupsBlocked then
    Exit;
  FPopupsBlocked := Value;
  if FEngine <> nil then
    ApplyEngineOptions
  else
    SendDisplayOptions;
end;

procedure TWebView.SetEncodingOverride(const Value: string);
begin
  if Value = FEncodingOverride then
    Exit;
  FEncodingOverride := Value;
  if FEngine <> nil then
    ApplyEngineOptions
  else
    SendDisplayOptions;
end;

procedure TWebView.SetFindHighlight(const Needle: string; MatchCase: Boolean);
var
  Request: TIpcFindRequest;
begin
  if FEngine <> nil then
  begin
    FEngine.SetFindHighlight(Needle, MatchCase);
    Exit;
  end;
  Request.Needle := Needle;
  Request.Forward := True;
  Request.MatchCase := MatchCase;
  SendToProcess(IpcSetFindHighlight, EncodeFindRequest(Request));
end;

procedure TWebView.TakeFindResult(Message: TIpcMessage);
var
  Answer: TIpcFindResult;
begin
  FFindRequestId := 0;
  Answer := DecodeFindResult(Message.Payload);
  TellFindResult(FFindNeedle, Answer.Found, Answer.Wrapped, Answer.MatchCount);
end;

procedure TWebView.RequestPageInfo;
var
  Info: TWebPageInfo;
begin
  if FEngine <> nil then
  begin
    Info := FEngine.PageInfo;
    TellPageInfo(Info);
    Exit;
  end;
  if FProcess = nil then
  begin
    { Nothing to ask (no page, or it crashed): what the view knows. }
    Info := Default(TWebPageInfo);
    Info.Url := FUrl;
    Info.Title := FTitle;
    TellPageInfo(Info);
    Exit;
  end;
  FPageInfoRequestId := NextRequestId;
  SendToProcess(IpcRequestPageInfo, nil, FPageInfoRequestId);
end;

procedure TWebView.TakePageInfo(Message: TIpcMessage);
var
  Wire: TIpcPageInfo;
  Info: TWebPageInfo;
  Index: Integer;
begin
  FPageInfoRequestId := 0;
  Wire := DecodePageInfo(Message.Payload);
  Info := Default(TWebPageInfo);
  Info.Url := Wire.Url;
  Info.Title := Wire.Title;
  Info.Referrer := Wire.Referrer;
  Info.ContentType := Wire.ContentType;
  Info.Encoding := Wire.Encoding;
  Info.RenderMode := Wire.RenderMode;
  Info.LastModified := Wire.LastModified;
  SetLength(Info.Meta, Length(Wire.Meta));
  for Index := 0 to High(Wire.Meta) do
  begin
    Info.Meta[Index].Name := Wire.Meta[Index].Name;
    Info.Meta[Index].Content := Wire.Meta[Index].Content;
  end;
  SetLength(Info.Media, Length(Wire.Media));
  for Index := 0 to High(Wire.Media) do
  begin
    Info.Media[Index].Url := Wire.Media[Index].Url;
    Info.Media[Index].Kind := Wire.Media[Index].Kind;
    Info.Media[Index].AltText := Wire.Media[Index].AltText;
    Info.Media[Index].Width := Wire.Media[Index].Width;
    Info.Media[Index].Height := Wire.Media[Index].Height;
  end;
  Info.FormCount := Wire.FormCount;
  Info.LinkCount := Wire.LinkCount;
  TellPageInfo(Info);
end;

procedure TWebView.EnginePopupBlocked(Sender: TWebEngineView; const Value: string);
begin
  TellPopupBlocked(Value);
end;

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

{ WebIpcTest: the typed payloads (WebIpc.ViewMessages, WebIpc.NetworkMessages). }
unit WebIpcTest.Payloads;

{$mode objfpc}
{$H+}

interface

procedure RunPayloadChecks;

implementation

uses
  SysUtils,
  TestChecks,
  WebIpc.Wire,
  WebIpc.ViewMessages,
  WebIpc.NetworkMessages;

procedure CheckViewPayloads;
var
  Setup, SetupBack: TIpcViewSetup;
  Input, InputBack: TIpcInputEvent;
  Frame, FrameBack: TIpcFrameInfo;
  Surface, SurfaceBack: TIpcSurfaceInfo;
  Context, ContextBack: TIpcContextInfo;
  Menu, MenuBack: TIpcPopupMenu;
  Open, OpenBack: TIpcOpenUrl;
  Dialog, DialogBack: TIpcDialogRequest;
  Answer, AnswerBack: TIpcDialogAnswer;
  First, Second: string;
  Left, Right: LongInt;
begin
  Setup := Default(TIpcViewSetup);
  Setup.Geometry.Width := 800;
  Setup.Geometry.Height := 600;
  Setup.Geometry.ScalePercent := 150;
  Setup.Geometry.Dpi := 144;
  Setup.Zoom := 1.25;
  Setup.Visible := True;
  Setup.ScriptingEnabled := True;
  SetupBack := DecodeViewSetup(EncodeViewSetup(Setup));
  Check((SetupBack.Geometry.Width = 800) and (SetupBack.Geometry.Height = 600) and
    (SetupBack.Geometry.ScalePercent = 150) and (SetupBack.Geometry.Dpi = 144) and (SetupBack.Zoom = 1.25) and
    SetupBack.Visible and not SetupBack.Focused and SetupBack.ScriptingEnabled, 'payloads: a view''s setup');

  Input := Default(TIpcInputEvent);
  Input.Kind := InputKeyDown;
  Input.Sequence := 99;
  Input.X := -5;
  Input.Y := 17;
  Input.Code := 30;
  Input.Character := $E9;
  Input.Modifiers := 3;
  Input.Text := 'x';
  InputBack := DecodeInputEvent(EncodeInputEvent(Input));
  Check((InputBack.Kind = InputKeyDown) and (InputBack.Sequence = 99) and (InputBack.X = -5) and (InputBack.Y = 17) and
    (InputBack.Code = 30) and (InputBack.Character = $E9) and (InputBack.Modifiers = 3) and (InputBack.Text = 'x'),
    'payloads: an input event');

  Surface.SurfaceId := 4;
  Surface.Width := 640;
  Surface.Height := 480;
  Surface.StrideBytes := 2560;
  SurfaceBack := DecodeSurfaceInfo(EncodeSurfaceInfo(Surface));
  Check((SurfaceBack.SurfaceId = 4) and (SurfaceBack.Width = 640) and (SurfaceBack.StrideBytes = 2560),
    'payloads: a surface');
  Surface.StrideBytes := 100;
  try
    DecodeSurfaceInfo(EncodeSurfaceInfo(Surface));
    Check(False, 'payloads: a surface narrower than its width is refused');
  except
    on EIpcMalformed do
      Check(True, 'payloads: a surface narrower than its width is refused');
  end;

  Frame := Default(TIpcFrameInfo);
  Frame.FrameNumber := 12;
  Frame.SurfaceId := 4;
  Frame.Width := 640;
  Frame.Height := 480;
  Frame.DamageLeft := 10;
  Frame.DamageBottom := 480;
  Frame.ScrollY := 1234.5;
  Frame.DocumentHeight := 9000;
  Frame.ViewportWidth := 624;
  Frame.HasFixedBoxes := True;
  Frame.InputHandled := 77;
  FrameBack := DecodeFrameInfo(EncodeFrameInfo(Frame));
  Check((FrameBack.FrameNumber = 12) and (FrameBack.DamageLeft = 10) and (FrameBack.DamageBottom = 480) and
    (FrameBack.ScrollY = 1234.5) and (FrameBack.DocumentHeight = 9000) and (FrameBack.ViewportWidth = 624) and
    FrameBack.HasFixedBoxes and (FrameBack.InputHandled = 77), 'payloads: a frame');

  Context := Default(TIpcContextInfo);
  Context.X := 3;
  Context.Y := 4;
  Context.LinkUrl := 'https://example.com/a';
  Context.SelectedText := 'some text';
  Context.InTextField := True;
  ContextBack := DecodeContextInfo(EncodeContextInfo(Context));
  Check((ContextBack.X = 3) and (ContextBack.LinkUrl = 'https://example.com/a') and
    (ContextBack.SelectedText = 'some text') and ContextBack.InTextField, 'payloads: a context menu''s place');

  Menu.MenuId := 2;
  Menu.X := 10;
  Menu.Y := 20;
  Menu.Items := nil;
  SetLength(Menu.Items, 3);
  Menu.Items[0] := Default(TIpcMenuItem);
  Menu.Items[0].Caption := 'One';
  Menu.Items[0].Tag := 0;
  Menu.Items[0].Enabled := True;
  Menu.Items[1] := Default(TIpcMenuItem);
  Menu.Items[1].Separator := True;
  Menu.Items[2] := Default(TIpcMenuItem);
  Menu.Items[2].Caption := 'Two';
  Menu.Items[2].Tag := 5;
  Menu.Items[2].Checked := True;
  MenuBack := DecodePopupMenu(EncodePopupMenu(Menu));
  Check((MenuBack.MenuId = 2) and (Length(MenuBack.Items) = 3) and (MenuBack.Items[0].Caption = 'One') and
    MenuBack.Items[0].Enabled and MenuBack.Items[1].Separator and (MenuBack.Items[2].Tag = 5) and
    MenuBack.Items[2].Checked and not MenuBack.Items[2].Enabled, 'payloads: a pop-up menu');

  Open := Default(TIpcOpenUrl);
  Open.Url := 'https://other.example/form';
  Open.Disposition := 1;
  Open.Method := 'POST';
  Open.Body := BytesOf('a=1&b=2');
  Open.ContentType := 'application/x-www-form-urlencoded';
  Open.Replace := True;
  OpenBack := DecodeOpenUrl(EncodeOpenUrl(Open));
  Check((OpenBack.Url = Open.Url) and (OpenBack.Disposition = 1) and (OpenBack.Method = 'POST') and
    (StringOf(OpenBack.Body) = 'a=1&b=2') and (OpenBack.ContentType = Open.ContentType) and OpenBack.Replace and
    not OpenBack.UserInitiated, 'payloads: a navigation to another site');

  Dialog.Kind := DialogPrompt;
  Dialog.Message := 'Your name?';
  Dialog.DefaultText := 'Ann';
  DialogBack := DecodeDialogRequest(EncodeDialogRequest(Dialog));
  Check((DialogBack.Kind = DialogPrompt) and (DialogBack.Message = 'Your name?') and (DialogBack.DefaultText = 'Ann'),
    'payloads: a dialog');
  Answer.Accepted := True;
  Answer.Text := 'Bob';
  AnswerBack := DecodeDialogAnswer(EncodeDialogAnswer(Answer));
  Check(AnswerBack.Accepted and (AnswerBack.Text = 'Bob'), 'payloads: a dialog''s answer');

  DecodeTexts(EncodeTexts('level', 'text'), First, Second);
  Check((First = 'level') and (Second = 'text'), 'payloads: two texts');
  DecodeNumbers(EncodeNumbers(-1, 7), Left, Right);
  Check((Left = -1) and (Right = 7) and (DecodeNumber(EncodeNumber(123)) = 123), 'payloads: numbers');
  Check(DecodeFlag(EncodeFlag(True)) and not DecodeFlag(EncodeFlag(False)), 'payloads: a flag');
  Check(DecodeReal(EncodeReal(0.5)) = 0.5, 'payloads: a real');
end;

procedure CheckFavicon;
var
  Icon, Back: TIpcFavicon;
  Payload: TBytes;
begin
  Icon.Width := 2;
  Icon.Height := 2;
  Icon.Pixels := nil;
  SetLength(Icon.Pixels, 4);
  Icon.Pixels[0] := $FF112233;
  Icon.Pixels[3] := $80FFFFFF;
  Back := DecodeFavicon(EncodeFavicon(Icon));
  Check((Back.Width = 2) and (Back.Height = 2) and (Back.Pixels[0] = $FF112233) and (Back.Pixels[3] = $80FFFFFF),
    'payloads: an icon');
  Payload := EncodeFavicon(Icon);
  SetLength(Payload, Length(Payload) - 1);
  try
    DecodeFavicon(Payload);
    Check(False, 'payloads: an icon of the wrong length is refused');
  except
    on EIpcMalformed do
      Check(True, 'payloads: an icon of the wrong length is refused');
  end;
end;

procedure CheckNetworkPayloads;
var
  Request, RequestBack: TIpcHopRequest;
  Head, HeadBack: TIpcHopHead;
  Outcome, OutcomeBack: TIpcHopOutcome;
  LocalFile, LocalFileBack: TIpcLocalFile;
  Pairs, PairsBack: TIpcStoragePairs;
  HopId: QWord;
  Data: TBytes;
  Url, Cookie, Origin, Key, Value: string;
  Secure: Boolean;
  ClientId: LongWord;
  Length_: Integer;
  Bytes, Cut: TBytes;
  Refused: Boolean;
begin
  Request := Default(TIpcHopRequest);
  Request.HopId := QWord($100000002);
  Request.Method := 'POST';
  Request.Url := 'https://example.com/submit?q=1';
  Request.Fields := nil;
  SetLength(Request.Fields, 2);
  Request.Fields[0].Name := 'accept';
  Request.Fields[0].Value := 'text/html';
  Request.Fields[1].Name := 'referer';
  Request.Fields[1].Value := 'https://example.com/';
  Request.HasBody := True;
  Request.Body := BytesOf('x=y');
  Request.BodyType := 'text/plain';
  Request.PriorityUrgency := 2;
  Request.MaximumRedirects := -1;
  Request.CacheMode := 3;
  Request.CredentialsMode := 1;
  Request.DecodeContent := True;
  Request.CookieSecure := True;
  Request.CookieTopLevelNavigation := True;
  Request.Urgent := True;
  RequestBack := DecodeHopRequest(EncodeHopRequest(Request));
  Check((RequestBack.HopId = QWord($100000002)) and (RequestBack.Method = 'POST') and (RequestBack.Url = Request.Url) and
    (Length(RequestBack.Fields) = 2) and (RequestBack.Fields[1].Value = 'https://example.com/') and
    RequestBack.HasBody and (StringOf(RequestBack.Body) = 'x=y') and (RequestBack.BodyType = 'text/plain') and
    (RequestBack.PriorityUrgency = 2) and (RequestBack.MaximumRedirects = -1) and (RequestBack.CacheMode = 3) and
    (RequestBack.CredentialsMode = 1) and RequestBack.DecodeContent and RequestBack.CookieSecure and
    not RequestBack.CookieSameSite and RequestBack.CookieTopLevelNavigation and RequestBack.Urgent,
    'payloads: an HTTP request');

  Head := Default(TIpcHopHead);
  Head.HopId := 9;
  Head.Status := 301;
  Head.Reason := 'Moved Permanently';
  SetLength(Head.Fields, 1);
  Head.Fields[0].Name := 'location';
  Head.Fields[0].Value := '/next';
  Head.Url := 'https://example.com/old';
  Head.FromCache := True;
  Head.Protocol := 'h2';
  HeadBack := DecodeHopHead(EncodeHopHead(Head));
  Check((HeadBack.HopId = 9) and (HeadBack.Status = 301) and (HeadBack.Reason = 'Moved Permanently') and
    (Length(HeadBack.Fields) = 1) and (HeadBack.Fields[0].Value = '/next') and HeadBack.FromCache and
    (HeadBack.Protocol = 'h2'), 'payloads: a response''s head');

  DecodeHopData(EncodeHopData(77, PChar('body bytes'), 10), HopId, Data);
  Check((HopId = 77) and (StringOf(Data) = 'body bytes'), 'payloads: a piece of a body');
  Check(DecodeHopId(EncodeHopId(QWord(High(Int64)))) = QWord(High(Int64)), 'payloads: a hop id');

  Outcome.HopId := 9;
  Outcome.Code := 4;
  Outcome.Text := 'connection reset';
  Outcome.ErrorCode := -104;
  Outcome.Retryable := True;
  OutcomeBack := DecodeHopOutcome(EncodeHopOutcome(Outcome));
  Check((OutcomeBack.HopId = 9) and (OutcomeBack.Code = 4) and (OutcomeBack.Text = 'connection reset') and
    (OutcomeBack.ErrorCode = -104) and OutcomeBack.Retryable, 'payloads: an outcome');

  LocalFile.Found := True;
  LocalFile.IsFolder := False;
  LocalFile.Contents := BytesOf('<p>hi</p>');
  LocalFile.Error := '';
  LocalFileBack := DecodeLocalFile(EncodeLocalFile(LocalFile));
  Check(LocalFileBack.Found and not LocalFileBack.IsFolder and (StringOf(LocalFileBack.Contents) = '<p>hi</p>'),
    'payloads: a local file');

  Pairs.Keys := nil;
  Pairs.Values := nil;
  SetLength(Pairs.Keys, 2);
  SetLength(Pairs.Values, 2);
  Pairs.Keys[0] := 'a';
  Pairs.Values[0] := '1';
  Pairs.Keys[1] := 'b';
  Pairs.Values[1] := '';
  PairsBack := DecodeStoragePairs(EncodeStoragePairs(Pairs));
  Check((Length(PairsBack.Keys) = 2) and (PairsBack.Keys[1] = 'b') and (PairsBack.Values[0] = '1') and
    (PairsBack.Values[1] = ''), 'payloads: storage pairs');

  DecodeCookieAccess(EncodeCookieAccess('https://a.example/', 'k=v', True), Url, Cookie, Secure);
  Check((Url = 'https://a.example/') and (Cookie = 'k=v') and Secure, 'payloads: a cookie access');
  DecodeStorageChange(EncodeStorageChange('https://a.example', 'key', 'value'), Origin, Key, Value);
  Check((Origin = 'https://a.example') and (Key = 'key') and (Value = 'value'), 'payloads: a storage change');

  Bytes := nil;
  SetLength(Bytes, 3);
  Bytes[0] := 16;
  Bytes[1] := 0;
  Bytes[2] := 255;
  DecodeIndexedDbRequest(EncodeIndexedDbRequest(7, 'https://a.example', Bytes), ClientId, Origin, Data);
  Check((ClientId = 7) and (Origin = 'https://a.example') and (Length(Data) = 3) and (Data[2] = 255),
    'payloads: an IndexedDB request');
  DecodeIndexedDbNotice(EncodeIndexedDbNotice(9, Bytes), ClientId, Data);
  Check((ClientId = 9) and (Length(Data) = 3) and (Data[0] = 16), 'payloads: an IndexedDB notice');
  DecodeIndexedDbNotice(EncodeIndexedDbNotice(9, nil), ClientId, Data);
  Check((ClientId = 9) and (Length(Data) = 0), 'payloads: an IndexedDB client closed');
  { Cut short at every length: refused, never read past. }
  Bytes := EncodeIndexedDbRequest(7, 'https://a.example', Bytes);
  Refused := True;
  for Length_ := 0 to Length(Bytes) - 1 do
  begin
    Cut := Copy(Bytes, 0, Length_);
    try
      DecodeIndexedDbRequest(Cut, ClientId, Origin, Data);
      Refused := False;
    except
      on EIpcMalformed do
        ;
    end;
  end;
  Check(Refused, 'payloads: a cut IndexedDB request is refused');
end;

procedure RunPayloadChecks;
begin
  CheckViewPayloads;
  CheckFavicon;
  CheckNetworkPayloads;
end;

end.

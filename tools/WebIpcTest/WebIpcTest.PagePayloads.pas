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

{ WebIpcTest: the payloads of protocol version 2 (session history, find
  with its details, the context menu's new fields, display options,
  Page Info): both ways, and refused when cut short or lying. }
unit WebIpcTest.PagePayloads;

{$mode objfpc}
{$H+}

interface

procedure RunPagePayloadChecks;

implementation

uses
  SysUtils,
  TestChecks,
  WebIpc.Wire,
  WebIpc.Messages,
  WebIpc.ViewMessages;

type
  TPayloadDecoder = procedure(const Payload: TBytes);

procedure DecodeHistoryOnly(const Payload: TBytes);
begin
  DecodeHistoryState(Payload);
end;

procedure DecodePageInfoOnly(const Payload: TBytes);
begin
  DecodePageInfo(Payload);
end;

procedure DecodeFindResultOnly(const Payload: TBytes);
begin
  DecodeFindResult(Payload);
end;

procedure DecodeDisplayOptionsOnly(const Payload: TBytes);
begin
  DecodeDisplayOptions(Payload);
end;

procedure DecodeContextOnly(const Payload: TBytes);
begin
  DecodeContextInfo(Payload);
end;

function Refuses(Decoder: TPayloadDecoder; const Payload: TBytes): Boolean;
begin
  Result := False;
  try
    Decoder(Payload);
  except
    on EIpcMalformed do
      Result := True;
  end;
end;

{ Every payload shorter than the whole is refused. }
function RefusesEveryCut(Decoder: TPayloadDecoder; const Payload: TBytes): Boolean;
var
  Cut: TBytes;
  Length_: Integer;
begin
  Result := True;
  Length_ := 0;
  while Length_ < Length(Payload) do
  begin
    Cut := Copy(Payload, 0, Length_);
    if not Refuses(Decoder, Cut) then
      Exit(False);
    Inc(Length_);
  end;
end;

{ The little-endian LongWord at Offset becomes Value. }
procedure Poke(var Payload: TBytes; Offset: Integer; Value: LongWord);
begin
  StoreLongWord(@Payload[Offset], Value);
end;

procedure CheckHistoryState;
var
  State, Back: TIpcHistoryState;
  Payload: TBytes;
begin
  State := Default(TIpcHistoryState);
  State.CanGoBack := True;
  State.Index := 1;
  SetLength(State.Entries, 3);
  State.Entries[0].Url := 'https://a.example/';
  State.Entries[0].Title := 'First';
  State.Entries[1].Url := 'https://a.example/two';
  State.Entries[1].Title := '';
  State.Entries[2].Url := 'https://a.example/three';
  State.Entries[2].Title := 'Third '#$E2#$80#$94' page';
  Payload := EncodeHistoryState(State);
  Back := DecodeHistoryState(Payload);
  Check(Back.CanGoBack and not Back.CanGoForward and (Back.Index = 1) and (Length(Back.Entries) = 3) and
    (Back.Entries[0].Title = 'First') and (Back.Entries[1].Url = 'https://a.example/two') and
    (Back.Entries[2].Title = State.Entries[2].Title), 'page payloads: a session history');
  Check(RefusesEveryCut(@DecodeHistoryOnly, Payload), 'page payloads: a history cut short is refused');

  { The count claims more entries than the message holds. }
  Poke(Payload, 6, 1000);
  Check(Refuses(@DecodeHistoryOnly, Payload), 'page payloads: a history claiming more entries is refused');
  Payload := EncodeHistoryState(State);
  Poke(Payload, 6, $7FFFFFFF);
  Check(Refuses(@DecodeHistoryOnly, Payload), 'page payloads: a huge history count is refused');

  { The current entry outside the entries. }
  State.Index := 3;
  Check(Refuses(@DecodeHistoryOnly, EncodeHistoryState(State)), 'page payloads: a current entry past the end is refused');
  State.Index := -1;
  Check(Refuses(@DecodeHistoryOnly, EncodeHistoryState(State)), 'page payloads: no current entry with entries is refused');
  State.Entries := nil;
  Back := DecodeHistoryState(EncodeHistoryState(State));
  Check((Back.Index = -1) and (Length(Back.Entries) = 0), 'page payloads: an empty history');
  State.Index := 0;
  Check(Refuses(@DecodeHistoryOnly, EncodeHistoryState(State)), 'page payloads: a current entry of an empty history is refused');
end;

procedure CheckFind;
var
  Request, RequestBack: TIpcFindRequest;
  Answer, AnswerBack: TIpcFindResult;
  Payload: TBytes;
begin
  Request.Needle := 'Needle';
  Request.Forward := False;
  Request.MatchCase := True;
  RequestBack := DecodeFindRequest(EncodeFindRequest(Request));
  Check((RequestBack.Needle = 'Needle') and not RequestBack.Forward and RequestBack.MatchCase,
    'page payloads: a find request');

  Answer.Found := True;
  Answer.Wrapped := True;
  Answer.MatchCount := 42;
  Payload := EncodeFindResult(Answer);
  AnswerBack := DecodeFindResult(Payload);
  Check(AnswerBack.Found and AnswerBack.Wrapped and (AnswerBack.MatchCount = 42), 'page payloads: a find result');
  Check(RefusesEveryCut(@DecodeFindResultOnly, Payload), 'page payloads: a find result cut short is refused');
  Answer.Found := False;
  Answer.Wrapped := False;
  Answer.MatchCount := -1;
  AnswerBack := DecodeFindResult(EncodeFindResult(Answer));
  Check(not AnswerBack.Found and (AnswerBack.MatchCount = -1), 'page payloads: a find result of an unknown count');
  Answer.MatchCount := -2;
  Check(Refuses(@DecodeFindResultOnly, EncodeFindResult(Answer)), 'page payloads: a negative match count is refused');
end;

procedure CheckContextInfo;
var
  Context, Back: TIpcContextInfo;
  Payload: TBytes;
begin
  Context := Default(TIpcContextInfo);
  Context.X := -1;
  Context.Y := 200;
  Context.ImageUrl := 'https://a.example/i.png';
  Context.BackgroundImageUrl := 'https://a.example/bg.jpg';
  Context.IsEditable := True;
  Context.FrameUrl := 'https://b.example/frame';
  Context.CanCopy := True;
  Payload := EncodeContextInfo(Context);
  Back := DecodeContextInfo(Payload);
  Check((Back.X = -1) and (Back.ImageUrl = Context.ImageUrl) and (Back.BackgroundImageUrl = Context.BackgroundImageUrl) and
    Back.IsEditable and (Back.FrameUrl = Context.FrameUrl) and Back.CanCopy and not Back.InTextField,
    'page payloads: a context menu''s place with its version 2 fields');
  Check(RefusesEveryCut(@DecodeContextOnly, Payload), 'page payloads: a context menu''s place cut short is refused');
end;

procedure CheckDisplayOptions;
var
  Options, Back: TIpcDisplayOptions;
  Payload: TBytes;
begin
  Options.ImagesEnabled := False;
  Options.TextOnlyZoom := True;
  Options.AuthorStylesEnabled := False;
  Options.PopupsBlocked := True;
  Options.EncodingOverride := 'windows-1251';
  Payload := EncodeDisplayOptions(Options);
  Back := DecodeDisplayOptions(Payload);
  Check(not Back.ImagesEnabled and Back.TextOnlyZoom and not Back.AuthorStylesEnabled and Back.PopupsBlocked and
    (Back.EncodingOverride = 'windows-1251'), 'page payloads: display options');
  Check(RefusesEveryCut(@DecodeDisplayOptionsOnly, Payload), 'page payloads: display options cut short are refused');
  Options.EncodingOverride := StringOfChar('x', 65);
  Check(Refuses(@DecodeDisplayOptionsOnly, EncodeDisplayOptions(Options)),
    'page payloads: an encoding label too long is refused');
end;

procedure CheckPageInfo;
var
  Info, Back: TIpcPageInfo;
  Payload: TBytes;
  MetaCountAt: Integer;
begin
  Info := Default(TIpcPageInfo);
  Info.Url := 'https://a.example/page';
  Info.Title := 'A page';
  Info.Referrer := 'https://search.example/?q=a';
  Info.ContentType := 'text/html';
  Info.Encoding := 'UTF-8';
  Info.RenderMode := 'Standards compliance mode';
  Info.LastModified := 'Tue, 03 Nov 2026 10:00:00 GMT';
  SetLength(Info.Meta, 2);
  Info.Meta[0].Name := 'description';
  Info.Meta[0].Content := 'About a';
  Info.Meta[1].Name := 'viewport';
  Info.Meta[1].Content := 'width=device-width';
  SetLength(Info.Media, 2);
  Info.Media[0].Url := 'https://a.example/logo.png';
  Info.Media[0].Kind := 'Image';
  Info.Media[0].AltText := 'Logo';
  Info.Media[0].Width := 120;
  Info.Media[0].Height := 40;
  Info.Media[1].Url := 'https://a.example/favicon.ico';
  Info.Media[1].Kind := 'Icon';
  Info.FormCount := 1;
  Info.LinkCount := 17;
  Payload := EncodePageInfo(Info);
  Back := DecodePageInfo(Payload);
  Check((Back.Url = Info.Url) and (Back.Title = 'A page') and (Back.Referrer = Info.Referrer) and
    (Back.ContentType = 'text/html') and (Back.Encoding = 'UTF-8') and (Back.RenderMode = Info.RenderMode) and
    (Back.LastModified = Info.LastModified) and (Length(Back.Meta) = 2) and (Back.Meta[1].Content = 'width=device-width') and
    (Length(Back.Media) = 2) and (Back.Media[0].AltText = 'Logo') and (Back.Media[0].Width = 120) and
    (Back.Media[0].Height = 40) and (Back.Media[1].Kind = 'Icon') and (Back.FormCount = 1) and (Back.LinkCount = 17),
    'page payloads: Page Info');
  Check(RefusesEveryCut(@DecodePageInfoOnly, Payload), 'page payloads: Page Info cut short is refused');

  { The meta count lies: it comes after the seven texts. }
  MetaCountAt := 4;
  MetaCountAt := MetaCountAt + 4 * 7 + Length(Info.Url) + Length(Info.Title) + Length(Info.Referrer) +
    Length(Info.ContentType) + Length(Info.Encoding) + Length(Info.RenderMode) + Length(Info.LastModified);
  Poke(Payload, MetaCountAt, 5000);
  Check(Refuses(@DecodePageInfoOnly, Payload), 'page payloads: Page Info claiming more meta items is refused');

  Info.FormCount := -3;
  Check(Refuses(@DecodePageInfoOnly, EncodePageInfo(Info)), 'page payloads: a negative form count is refused');
end;

procedure CheckKinds;
begin
  Check(IpcKindName(IpcGoToHistoryOffset) = 'go-to-history-offset', 'page payloads: the history offset kind');
  Check((IpcKindName(IpcRestoreHistory) = 'restore-history') and (IpcKindName(IpcPopupBlocked) = 'popup-blocked'),
    'page payloads: the new kinds have names');
end;

procedure RunPagePayloadChecks;
begin
  CheckKinds;
  CheckHistoryState;
  CheckFind;
  CheckContextInfo;
  CheckDisplayOptions;
  CheckPageInfo;
end;

end.

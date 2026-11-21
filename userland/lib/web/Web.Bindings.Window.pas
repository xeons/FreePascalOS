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
  bindings/Window.webidl: the window (the global object), Location (read
  only: navigation goes to the environment), History and the user
  prompts through the environment, Navigator, atob and btoa (forgiving
  base64), the timers (Web.Script.Timers) and structuredClone (a
  script function of the context's prelude).
}
unit Web.Bindings.Window;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Window.Members.inc}

implementation

uses
  SysUtils,
  Classes,
  Js.Strings,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Url.Records,
  Url.Parser,
  Url.Accessors,
  Url.Origins,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Encoding.Utf8,
  Web.Bindings.Context,
  Web.Bindings.Style,
  Web.Bindings.UrlResolution,
  Web.Bindings.CrossOrigin,
  Web.Origins,
  Web.Script.Timers;

type
  { Location, History and Navigator keep no state of their own here. }
  TWindowPart = class
  end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function GlobalValue(const Call: TBindingCall): TJsValue; inline;
begin
  Result := JsObjectValue(Context(Call).Engine.GlobalObject);
end;

function Text(const Call: TBindingCall; const Value: string): TJsValue; inline;
begin
  Result := Context(Call).TextValue(Value);
end;

function Part(const Call: TBindingCall; Kind: TWindowSingleton; InterfaceId: Integer): TJsValue;
begin
  Result := Context(Call).Singleton(Kind);
  if Result = JsUndefined then
  begin
    Result := Context(Call).WrapObject(TWindowPart.Create, InterfaceId, True, JsUndefined);
    Context(Call).SetSingleton(Kind, Result);
  end;
end;

{ Window }

function Window_get_window(var Call: TBindingCall): TJsValue;
begin
  Result := GlobalValue(Call);
end;

function Window_get_self(var Call: TBindingCall): TJsValue;
begin
  Result := GlobalValue(Call);
end;

function Window_get_frames(var Call: TBindingCall): TJsValue;
begin
  Result := GlobalValue(Call);
end;

function Window_get_top(var Call: TBindingCall): TJsValue;
begin
  Result := WindowValueFor(Context(Call), Context(Call).TopContext);
end;

function Window_get_parent(var Call: TBindingCall): TJsValue;
begin
  if Context(Call).ParentContext <> nil then
    Result := WindowValueFor(Context(Call), Context(Call).ParentContext)
  else
    Result := GlobalValue(Call);
end;

function Window_get_document(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(Context(Call).Document);
end;

function Window_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).Singleton(SingletonWindowName);
  if Result = JsUndefined then
    Result := Text(Call, '');
end;

function Window_set_name(var Call: TBindingCall): TJsValue;
begin
  Context(Call).SetSingleton(SingletonWindowName, Text(Call, Call.Text(0)));
  Result := JsUndefined;
end;

function Window_get_location(var Call: TBindingCall): TJsValue;
begin
  Result := Part(Call, SingletonLocation, InterfaceLocation);
end;

function Window_get_history(var Call: TBindingCall): TJsValue;
begin
  Result := Part(Call, SingletonHistory, InterfaceHistory);
end;

function Window_get_navigator(var Call: TBindingCall): TJsValue;
begin
  Result := Part(Call, SingletonNavigator, InterfaceNavigator);
end;

function Window_get_closed(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function Window_close(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Window_stop(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Window_focus(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Window_blur(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Window_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Context(Call).FrameCount);
end;

function Window_get_frameElement(var Call: TBindingCall): TJsValue;
begin
  { Not across origins. }
  if (Context(Call).ParentContext <> nil) and not Context(Call).Closed and
     SameOriginContexts(Context(Call), Context(Call).ParentContext) then
    Result := Context(Call).ParentContext.WrapNode(Context(Call).FrameElement)
  else
    Result := JsNull;
end;

function Window_get_originAgentCluster(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function Window_alert(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.Alert(Context(Call), Call.Text(0));
  Result := JsUndefined;
end;

function Window_confirm(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(Context(Call).Environment.Confirm(Context(Call), Call.Text(0)));
end;

function Window_prompt(var Call: TBindingCall): TJsValue;
var
  Answer: string;
begin
  if not Context(Call).Environment.Prompt(Context(Call), Call.Text(0), Call.Text(1), Answer) then
    Exit(JsNull);
  Result := Text(Call, Answer);
end;

function Window_print(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Window_get_innerWidth(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Context(Call).Environment.ViewportWidth);
end;

function Window_get_innerHeight(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Context(Call).Environment.ViewportHeight);
end;

function Window_get_scrollX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function Window_get_pageXOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function Window_get_scrollY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function Window_get_pageYOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function Window_get_devicePixelRatio(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(Context(Call).Environment.DevicePixelRatio);
end;

function Window_getComputedStyle(var Call: TBindingCall): TJsValue;
begin
  Result := ComputedStyleObject(Context(Call), TElement(Call.Native(0)), Context(Call).WrapNode(TNode(Call.Native(0))));
end;

function DocumentOrigin(Document: TDocument): TUrlOrigin;
begin
  Result := Web.Origins.DocumentOrigin(Document);
end;

function Window_get_origin(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, SerializeOrigin(DocumentOrigin(Context(Call).Document)));
end;

function Window_get_isSecureContext(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(OriginIsPotentiallyTrustworthy(DocumentOrigin(Context(Call).Document)));
end;

function Window_get_crossOriginIsolated(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Window_btoa(var Call: TBindingCall): TJsValue;
var
  Source, Bytes, Output: string;
  Index: SizeInt;
  CodePoint, Group: LongWord;
  Remaining: Integer;
begin
  Source := Call.Text(0);
  Bytes := '';
  Index := 1;
  while Index <= Length(Source) do
  begin
    CodePoint := NextCodePoint(Source, Index);
    if CodePoint > 255 then
      RaiseDomError(InvalidCharacterError, 'btoa takes characters up to U+00FF');
    Bytes := Bytes + Chr(CodePoint);
  end;
  Output := '';
  Index := 1;
  while Index <= Length(Bytes) do
  begin
    Remaining := Length(Bytes) - Index + 1;
    Group := LongWord(Ord(Bytes[Index])) shl 16;
    if Remaining > 1 then
      Group := Group or (LongWord(Ord(Bytes[Index + 1])) shl 8);
    if Remaining > 2 then
      Group := Group or LongWord(Ord(Bytes[Index + 2]));
    Output := Output + Base64Alphabet[(Group shr 18) and 63 + 1] + Base64Alphabet[(Group shr 12) and 63 + 1];
    if Remaining > 1 then
      Output := Output + Base64Alphabet[(Group shr 6) and 63 + 1]
    else
      Output := Output + '=';
    if Remaining > 2 then
      Output := Output + Base64Alphabet[Group and 63 + 1]
    else
      Output := Output + '=';
    Inc(Index, 3);
  end;
  Result := Text(Call, Output);
end;

{ Infra's forgiving-base64 decode; False on failure. }
function ForgivingBase64Decode(const Input: string; out Bytes: string): Boolean;
var
  Data: string;
  Index, Value, Bits, Count: Integer;
  Buffer: LongWord;
begin
  Bytes := '';
  Data := '';
  for Index := 1 to Length(Input) do
    if not (Input[Index] in [#9, #10, #12, #13, ' ']) then
      Data := Data + Input[Index];
  if Length(Data) mod 4 = 0 then
  begin
    if (Length(Data) >= 2) and (Copy(Data, Length(Data) - 1, 2) = '==') then
      SetLength(Data, Length(Data) - 2)
    else if (Length(Data) >= 1) and (Data[Length(Data)] = '=') then
      SetLength(Data, Length(Data) - 1);
  end;
  if Length(Data) mod 4 = 1 then
    Exit(False);
  Buffer := 0;
  Bits := 0;
  Count := 0;
  for Index := 1 to Length(Data) do
  begin
    Value := Pos(Data[Index], Base64Alphabet) - 1;
    if Value < 0 then
      Exit(False);
    Buffer := (Buffer shl 6) or LongWord(Value);
    Inc(Bits, 6);
    Inc(Count);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Bytes := Bytes + Chr((Buffer shr Bits) and $FF);
    end;
  end;
  Result := True;
end;

function Window_atob(var Call: TBindingCall): TJsValue;
var
  Bytes: string;
begin
  if not ForgivingBase64Decode(Call.Text(0), Bytes) then
    RaiseDomError(InvalidCharacterError, 'the string is not valid base64');
  Result := JsStringValue(NewLatin1String(Context(Call).Engine.Runtime.Heap, PByte(PChar(Bytes)), Length(Bytes)));
end;

function StartTimer(var Call: TBindingCall; Repeating: Boolean): TJsValue;
var
  Arguments: TJsValueList;
  Index: Integer;
  Handler: TJsValue;
begin
  Arguments := nil;
  SetLength(Arguments, Call.Count - 2);
  for Index := 2 to Call.Count - 1 do
    Arguments[Index - 2] := Call.Arguments[Index].Script;
  Handler := Call.Script(0);
  if not JsIsCallable(Handler) then
    Handler := Text(Call, Context(Call).Engine.ToText(Handler));
  Result := JsInteger(TimersOf(Context(Call)).Start(Handler, Call.Int(1), Arguments, Repeating));
end;

function Window_setTimeout(var Call: TBindingCall): TJsValue;
begin
  Result := StartTimer(Call, False);
end;

function Window_setInterval(var Call: TBindingCall): TJsValue;
begin
  Result := StartTimer(Call, True);
end;

function Window_clearTimeout(var Call: TBindingCall): TJsValue;
begin
  TimersOf(Context(Call)).Clear(Call.Int(0));
  Result := JsUndefined;
end;

function Window_clearInterval(var Call: TBindingCall): TJsValue;
begin
  TimersOf(Context(Call)).Clear(Call.Int(0));
  Result := JsUndefined;
end;

function Window_structuredClone(var Call: TBindingCall): TJsValue;
var
  Helper, Value: TJsValue;
begin
  Helper := Context(Call).Singleton(SingletonStructuredClone);
  Value := Call.Script(0);
  Result := Call.Realm.Call(Helper, JsUndefined, @Value, 1);
  if Result = JsException then
    raise EBindingPendingException.Create('');
end;

{ Location }

function LocationUrl(const Call: TBindingCall; out Url: TUrlRecord): Boolean;
var
  Href: string;
begin
  Href := Context(Call).Environment.LocationHref(Context(Call));
  if Href = '' then
    Href := DocumentUrlText(Context(Call).Document);
  Result := ParseUrl(Href, Url);
end;

type
  TUrlGetter = function(constref Url: TUrlRecord): string;

function LocationPart(const Call: TBindingCall; Getter: TUrlGetter): TJsValue;
var
  Url: TUrlRecord;
begin
  if LocationUrl(Call, Url) then
    Result := Text(Call, Getter(Url))
  else
    Result := Text(Call, '');
end;

function Location_get_href(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetHref);
end;

function Location_get_origin(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetOrigin);
end;

function Location_get_protocol(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetProtocol);
end;

function Location_get_host(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetHost);
end;

function Location_get_hostname(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetHostname);
end;

function Location_get_port(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetPort);
end;

function Location_get_pathname(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetPathname);
end;

function Location_get_search(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetSearch);
end;

function Location_get_hash(var Call: TBindingCall): TJsValue;
begin
  Result := LocationPart(Call, @GetHash);
end;

function NavigateTo(const Call: TBindingCall; ReplaceEntry: Boolean): TJsValue;
var
  Resolved: string;
begin
  if not ResolveUrlText(Context(Call).Document, Call.Text(0), Resolved) then
    RaiseDomError(SyntaxError, '''' + Call.Text(0) + ''' is not a valid URL');
  Context(Call).Environment.Navigate(Context(Call), Resolved, ReplaceEntry);
  Result := JsUndefined;
end;

function Location_set_href(var Call: TBindingCall): TJsValue;
begin
  Result := NavigateTo(Call, False);
end;

function Location_assign(var Call: TBindingCall): TJsValue;
begin
  Result := NavigateTo(Call, False);
end;

function Location_replace(var Call: TBindingCall): TJsValue;
begin
  Result := NavigateTo(Call, True);
end;

function Location_reload(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.Reload(Context(Call));
  Result := JsUndefined;
end;

{ History }

function History_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Context(Call).Environment.HistoryLength(Context(Call)));
end;

function History_get_scrollRestoration(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).Singleton(SingletonScrollRestoration);
  if Result = JsUndefined then
    Result := Text(Call, 'auto');
end;

function History_set_scrollRestoration(var Call: TBindingCall): TJsValue;
begin
  Context(Call).SetSingleton(SingletonScrollRestoration, Text(Call, Call.Text(0)));
  Result := JsUndefined;
end;

function History_get_state(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).Singleton(SingletonHistoryState);
  if Result = JsUndefined then
    Result := JsNull;
end;

function History_go(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.HistoryGo(Context(Call), Call.Int(0));
  Result := JsUndefined;
end;

function History_back(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.HistoryGo(Context(Call), -1);
  Result := JsUndefined;
end;

function History_forward(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.HistoryGo(Context(Call), 1);
  Result := JsUndefined;
end;

function ChangeHistory(const Call: TBindingCall; ReplaceEntry: Boolean): TJsValue;
var
  Resolved: string;
begin
  Resolved := DocumentUrlText(Context(Call).Document);
  if not Call.IsNull(2) and not ResolveUrlText(Context(Call).Document, Call.Text(2), Resolved) then
    RaiseDomError(SyntaxError, '''' + Call.Text(2) + ''' is not a valid URL');
  Context(Call).Environment.HistoryChangeUrl(Context(Call), Resolved, ReplaceEntry);
  Context(Call).Document.Url := Resolved;
  Context(Call).SetSingleton(SingletonHistoryState, Call.Script(0));
  Result := JsUndefined;
end;

function History_pushState(var Call: TBindingCall): TJsValue;
begin
  Result := ChangeHistory(Call, False);
end;

function History_replaceState(var Call: TBindingCall): TJsValue;
begin
  Result := ChangeHistory(Call, True);
end;

{ Navigator }

function Navigator_get_appCodeName(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'Mozilla');
end;

function Navigator_get_appName(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'Netscape');
end;

function Navigator_get_appVersion(var Call: TBindingCall): TJsValue;
var
  Agent: string;
begin
  Agent := Context(Call).Environment.UserAgent;
  if Copy(Agent, 1, 8) = 'Mozilla/' then
    Delete(Agent, 1, 8);
  Result := Text(Call, Agent);
end;

function Navigator_get_platform(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'FreePascalOS');
end;

function Navigator_get_product(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'Gecko');
end;

function Navigator_get_productSub(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, '20030107');
end;

function Navigator_get_userAgent(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, Context(Call).Environment.UserAgent);
end;

function Navigator_get_vendor(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, '');
end;

function Navigator_get_vendorSub(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, '');
end;

function Navigator_get_language(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, Context(Call).Environment.Language);
end;

function Navigator_get_languages(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).StringArray([Context(Call).Environment.Language]);
end;

function Navigator_get_onLine(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

function Navigator_get_cookieEnabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

function Navigator_get_pdfViewerEnabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function Navigator_get_hardwareConcurrency(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(TThread.ProcessorCount);
end;

function Navigator_get_webdriver(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function Navigator_javaEnabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

end.

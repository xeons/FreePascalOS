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
  Nested navigables for script (HTML Standard 7.3.4, iframe): an iframe
  element that becomes connected in a scripted document gets a child
  window - a TScriptContext over a document of its own, in a realm of
  the parent's engine (so contentWindow, contentDocument and the
  child's built-ins are ordinary objects to the parent's script). Its
  first document is about:blank (with html, head and body, the
  parent's origin), or srcdoc's markup parsed with its scripts; the
  iframe's load event fires then. Removing the element closes the
  window. src documents are not loaded into the frame yet.

  TFrameEnvironment is the child's environment: timers, prompts,
  cookies (an about:blank frame's are its creator's), the user agent
  and the viewport come from the parent's; location is the frame
  document's own.
}
unit Web.Script.Frames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.MediaQueries,
  Web.Dom,
  Web.Storage,
  Web.ScriptEnvironment,
  Web.Bindings.Context;

type
  TFrameEnvironment = class(TScriptEnvironment)
  private
    FParent: TScriptEnvironment;
    FParentContext: TBindingContext;
    function CookieUrl(Context: TObject; const Url: string): string;
  public
    constructor Create(AParent: TScriptEnvironment; AParentContext: TBindingContext);
    function SupportsTimers: Boolean; override;
    procedure StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean); override;
    procedure StopTimer(Context: TObject; TimerId: Integer); override;
    function LocationHref(Context: TObject): string; override;
    procedure Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Reload(Context: TObject); override;
    function HistoryLength(Context: TObject): Integer; override;
    procedure HistoryGo(Context: TObject; Delta: Integer); override;
    procedure HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Alert(Context: TObject; const Message: string); override;
    function OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean; override;
    function Confirm(Context: TObject; const Message: string): Boolean; override;
    function Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean; override;
    function ViewportWidth: Integer; override;
    function ViewportHeight: Integer; override;
    function DevicePixelRatio: Double; override;
    function GetCookies(Context: TObject; const Url: string): string; override;
    procedure SetCookie(Context: TObject; const Url, Cookie: string); override;
    function UserAgent: string; override;
    function Language: string; override;
    function StorageArea(Context: TObject; Session: Boolean): TWebStorageArea; override;
    procedure StorageChanged(Context: TObject; Area: TWebStorageArea); override;
    function MediaEnvironment: TCssMediaEnvironment; override;
    function ScreenWidth: Integer; override;
    function ScreenHeight: Integer; override;
    procedure SendBeacon(Context: TObject; const Url: string; const Body: TBytes; const ContentType: string); override;
    function StartFetch(Context: TObject; const Request: TScriptFetchRequest; Sink: TScriptFetchSink): TObject;
      override;
    procedure CancelFetch(Context: TObject; Handle: TObject); override;
    function LoadingContextOf(Context: TObject): TObject; override;
    function IsWorkerAgent: Boolean; override;
    function SharedStorageBackend: TObject; override;
    { The environment it forwards to (the parent's). }
    property Parent: TScriptEnvironment read FParent;
  end;

{ The insertion and removal steps of iframe elements in Context's
  document (the script context's document observer calls them). }
procedure FrameElementConnected(Context: TBindingContext; Element: TElement);
procedure FrameElementDisconnected(Context: TBindingContext; Element: TElement);
{ The URL whose origin an about:blank or srcdoc document has (its
  creator's), else Document's own URL. }
function OriginUrlOf(Context: TBindingContext): string;

implementation

uses
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Bindings.CrossOrigin,
  Web.Origins,
  Web.Script.Context;

const
  { The default size of an iframe (CSS 2 10.3.2's 300 by 150). }
  DefaultFrameWidth = 300;
  DefaultFrameHeight = 150;
  AboutBlankHtml = '<html><head></head><body></body></html>';

var
  AtomIframeName, AtomSrcdocName, AtomFrameNameName: TAtom;

function IsAboutDocument(const Url: string): Boolean;
begin
  Result := (Url = '') or (Url = 'about:blank') or (Url = 'about:srcdoc');
end;

function OriginUrlOf(Context: TBindingContext): string;
begin
  while (Context <> nil) and IsAboutDocument(Context.Document.Url) and (Context.ParentContext <> nil) do
    Context := Context.ParentContext;
  Result := Context.Document.Url;
end;

{ TFrameEnvironment }

constructor TFrameEnvironment.Create(AParent: TScriptEnvironment; AParentContext: TBindingContext);
begin
  inherited Create;
  FParent := AParent;
  FParentContext := AParentContext;
end;

function TFrameEnvironment.SupportsTimers: Boolean;
begin
  Result := FParent.SupportsTimers;
end;

procedure TFrameEnvironment.StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean);
begin
  FParent.StartTimer(Context, TimerId, Milliseconds, Repeating);
end;

procedure TFrameEnvironment.StopTimer(Context: TObject; TimerId: Integer);
begin
  FParent.StopTimer(Context, TimerId);
end;

function TFrameEnvironment.LocationHref(Context: TObject): string;
begin
  Result := TBindingContext(Context).Document.Url;
  if Result = '' then
    Result := 'about:blank';
end;

procedure TFrameEnvironment.Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  RaiseUnsupported('navigating a frame');
end;

procedure TFrameEnvironment.Reload(Context: TObject);
begin
end;

function TFrameEnvironment.HistoryLength(Context: TObject): Integer;
begin
  Result := FParent.HistoryLength(FParentContext);
end;

procedure TFrameEnvironment.HistoryGo(Context: TObject; Delta: Integer);
begin
  FParent.HistoryGo(FParentContext, Delta);
end;

procedure TFrameEnvironment.HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  { The frame's own document URL changes (the context does it); the
    joint session history is not kept per frame. }
end;

function TFrameEnvironment.OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean;
begin
  Result := FParent.OpenWindow(FParentContext, Url, Target, Features);
end;

procedure TFrameEnvironment.Alert(Context: TObject; const Message: string);
begin
  FParent.Alert(FParentContext, Message);
end;

function TFrameEnvironment.Confirm(Context: TObject; const Message: string): Boolean;
begin
  Result := FParent.Confirm(FParentContext, Message);
end;

function TFrameEnvironment.Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean;
begin
  Result := FParent.Prompt(FParentContext, Message, Default, Answer);
end;

function TFrameEnvironment.ViewportWidth: Integer;
begin
  Result := DefaultFrameWidth;
end;

function TFrameEnvironment.ViewportHeight: Integer;
begin
  Result := DefaultFrameHeight;
end;

function TFrameEnvironment.DevicePixelRatio: Double;
begin
  Result := FParent.DevicePixelRatio;
end;

function TFrameEnvironment.CookieUrl(Context: TObject; const Url: string): string;
begin
  if IsAboutDocument(Url) then
    Result := OriginUrlOf(TBindingContext(Context))
  else
    Result := Url;
end;

function TFrameEnvironment.GetCookies(Context: TObject; const Url: string): string;
begin
  Result := FParent.GetCookies(FParentContext, CookieUrl(Context, Url));
end;

procedure TFrameEnvironment.SetCookie(Context: TObject; const Url, Cookie: string);
begin
  FParent.SetCookie(FParentContext, CookieUrl(Context, Url), Cookie);
end;

function TFrameEnvironment.UserAgent: string;
begin
  Result := FParent.UserAgent;
end;

function TFrameEnvironment.Language: string;
begin
  Result := FParent.Language;
end;

function TFrameEnvironment.StorageArea(Context: TObject; Session: Boolean): TWebStorageArea;
begin
  Result := FParent.StorageArea(Context, Session);
end;

procedure TFrameEnvironment.StorageChanged(Context: TObject; Area: TWebStorageArea);
begin
  FParent.StorageChanged(Context, Area);
end;

function TFrameEnvironment.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := FParent.MediaEnvironment;
  Result.Width := DefaultFrameWidth;
  Result.Height := DefaultFrameHeight;
end;

function TFrameEnvironment.ScreenWidth: Integer;
begin
  Result := FParent.ScreenWidth;
end;

function TFrameEnvironment.ScreenHeight: Integer;
begin
  Result := FParent.ScreenHeight;
end;

procedure TFrameEnvironment.SendBeacon(Context: TObject; const Url: string; const Body: TBytes;
  const ContentType: string);
begin
  FParent.SendBeacon(Context, Url, Body, ContentType);
end;

function TFrameEnvironment.StartFetch(Context: TObject; const Request: TScriptFetchRequest;
  Sink: TScriptFetchSink): TObject;
begin
  Result := FParent.StartFetch(Context, Request, Sink);
end;

procedure TFrameEnvironment.CancelFetch(Context: TObject; Handle: TObject);
begin
  FParent.CancelFetch(Context, Handle);
end;

function TFrameEnvironment.LoadingContextOf(Context: TObject): TObject;
begin
  Result := FParent.LoadingContextOf(Context);
end;

function TFrameEnvironment.IsWorkerAgent: Boolean;
begin
  Result := FParent.IsWorkerAgent;
end;

function TFrameEnvironment.SharedStorageBackend: TObject;
begin
  Result := FParent.SharedStorageBackend;
end;

{ Frames }

procedure FireFrameLoad(Element: TElement);
var
  Event: TEvent;
begin
  Event := TEvent.Create('load', False, False);
  try
    Event.IsTrusted := True;
    Element.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

procedure FrameElementConnected(Context: TBindingContext; Element: TElement);
var
  Document: TDocument;
  Environment: TFrameEnvironment;
  Child: TScriptContext;
  Srcdoc: string;
begin
  if Context.Closed or (Context.FrameOf(Element) <> nil) or not Element.IsConnected then
    Exit;
  Document := TDocument.CreateDocument(True);
  try
    { about:blank and srcdoc documents have their creator's origin. }
    SetDocumentOrigin(Document, DocumentOrigin(Context.Document));
    Environment := TFrameEnvironment.Create(Context.Environment, Context);
    if Element.HasAttributeAtom(AtomSrcdocName) then
    begin
      Document.Url := 'about:srcdoc';
      Srcdoc := Element.AttributeValueOf(AtomSrcdocName);
    end
    else
    begin
      Document.Url := 'about:blank';
      Srcdoc := AboutBlankHtml;
    end;
    Child := TScriptContext.CreateFrame(Document, Environment, Context, Element);
    Child.OwnsEnvironment := True;
    Child.OnConsoleMessage := Context.OnConsoleMessage;
    { The browsing context's name is the element's name (window.name). }
    Child.SetSingleton(SingletonWindowName, Child.TextValue(Element.AttributeValueOf(AtomFrameNameName)));
    UpdateFrameIndices(Context);
    Child.ParseDocument(Srcdoc);
  finally
    Document.Release;
  end;
  FireFrameLoad(Element);
end;

procedure FrameElementDisconnected(Context: TBindingContext; Element: TElement);
var
  Child: TBindingContext;
begin
  Child := Context.FrameOf(Element);
  if Child <> nil then
  begin
    Child.Close;
    UpdateFrameIndices(Context);
  end;
end;

initialization
  AtomIframeName := Atomize('iframe');
  AtomSrcdocName := Atomize('srcdoc');
  AtomFrameNameName := Atomize('name');
end.

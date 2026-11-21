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
  The script environment of a document in a child navigable (an
  iframe's document loaded by the page): what belongs to the page
  (timers, cookies, storage, fetches, the user agent, prompts) goes to
  the page's environment with the frame's own context, so fetches and
  storage are the frame document's; what belongs to the navigable is the
  child's: location and navigation, pushState, the viewport and media
  queries (the frame's content box), geometry (its frame view's layout).
  history.length and history.go are the joint session history's (the
  top-level navigable's). A frame sandboxed without allow-modals gets
  no prompts; one with an opaque origin no cookies.
}
unit Web.Script.FrameNavigables;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.MediaQueries,
  Web.Dom,
  Web.ScriptEnvironment,
  Web.Bindings.Context,
  Web.Script.Frames,
  Web.Navigation.Navigables;

type
  TNavigableFrameEnvironment = class(TFrameEnvironment)
  private
    FNavigable: TNavigable;
    FOwnLayout: TScriptLayout;
    procedure ReloadTask;
    function OpaqueOrigin(Context: TObject): Boolean;
    function ModalsAllowed: Boolean;
  public
    { Page: the page's environment; ParentContext: the parent document's
      context (nil when it has none); Document: the frame's document. }
    constructor Create(Page: TScriptEnvironment; ParentContext: TBindingContext; Navigable: TNavigable;
      Document: TDocument);
    destructor Destroy; override;
    { The frame's document was left (or its navigable went): from now on
      nothing reaches the navigable (script may still hold the window). }
    procedure Disconnect;
    function ManagesFrames: Boolean; override;
    function LocationHref(Context: TObject): string; override;
    procedure Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Reload(Context: TObject); override;
    function HistoryLength(Context: TObject): Integer; override;
    procedure HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Alert(Context: TObject; const Message: string); override;
    function OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean; override;
    function Confirm(Context: TObject; const Message: string): Boolean; override;
    function Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean; override;
    function ViewportWidth: Integer; override;
    function ViewportHeight: Integer; override;
    function MediaEnvironment: TCssMediaEnvironment; override;
    function GetCookies(Context: TObject; const Url: string): string; override;
    procedure SetCookie(Context: TObject; const Url, Cookie: string); override;
    function NavigationTiming(Context: TObject): TScriptNavigationTiming; override;
    function RequestAnimationFrame(Context: TObject): Boolean; override;
    property Navigable: TNavigable read FNavigable;
  end;

implementation

uses
  Url.Records,
  Url.Parser,
  Url.Origins,
  Web.EventLoop.Tasks,
  Web.Origins,
  Web.Navigation.FramePolicy,
  Web.Frames.Views;

constructor TNavigableFrameEnvironment.Create(Page: TScriptEnvironment; ParentContext: TBindingContext;
  Navigable: TNavigable; Document: TDocument);
begin
  inherited Create(Page, ParentContext);
  FNavigable := Navigable;
  FOwnLayout := TFrameScriptLayout.Create(Document);
  Layout := FOwnLayout;
end;

destructor TNavigableFrameEnvironment.Destroy;
begin
  Layout := nil;
  FOwnLayout.Free;
  inherited Destroy;
end;

procedure TNavigableFrameEnvironment.Disconnect;
begin
  FNavigable := nil;
end;

function TNavigableFrameEnvironment.ManagesFrames: Boolean;
begin
  Result := True;
end;

function TNavigableFrameEnvironment.LocationHref(Context: TObject): string;
begin
  if FNavigable = nil then
    Result := TBindingContext(Context).Document.Url
  else
    Result := FNavigable.CurrentUrlText;
end;

procedure TNavigableFrameEnvironment.Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean);
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
begin
  if (FNavigable = nil) or not ParseUrl(Url, Target) or (Target.Scheme = 'javascript') then
    Exit;
  Options := DefaultNavigateOptions;
  Options.Replace := ReplaceEntry;
  Options.Source := FNavigable.Loader;
  FNavigable.Navigate(Target, Options);
end;

procedure TNavigableFrameEnvironment.ReloadTask;
begin
  if FNavigable <> nil then
    FNavigable.Reload;
end;

procedure TNavigableFrameEnvironment.Reload(Context: TObject);
begin
  if FNavigable <> nil then
    FNavigable.Loop.QueueMethod(@ReloadTask, TaskSourceNavigation, Context);
end;

function TNavigableFrameEnvironment.HistoryLength(Context: TObject): Integer;
begin
  if FNavigable = nil then
    Result := 1
  else
    Result := FNavigable.Top.History.Count;
end;

procedure TNavigableFrameEnvironment.HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean);
var
  Target: TUrlRecord;
begin
  if (FNavigable <> nil) and ParseUrl(Url, Target) then
    FNavigable.ChangeUrlFromScript(Target, ReplaceEntry);
end;

function TNavigableFrameEnvironment.ModalsAllowed: Boolean;
begin
  Result := (FNavigable <> nil) and (not FNavigable.Sandboxed or (AllowModals in FNavigable.Allowances));
end;

{ A sandboxed frame opens windows only with allow-popups. }
function TNavigableFrameEnvironment.OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean;
begin
  Result := (FNavigable <> nil) and (not FNavigable.Sandboxed or (AllowPopups in FNavigable.Allowances)) and
    inherited OpenWindow(Context, Url, Target, Features);
end;

procedure TNavigableFrameEnvironment.Alert(Context: TObject; const Message: string);
begin
  if ModalsAllowed then
    inherited Alert(Context, Message);
end;

function TNavigableFrameEnvironment.Confirm(Context: TObject; const Message: string): Boolean;
begin
  Result := ModalsAllowed and inherited Confirm(Context, Message);
end;

function TNavigableFrameEnvironment.Prompt(Context: TObject; const Message, Default: string;
  out Answer: string): Boolean;
begin
  Answer := '';
  Result := ModalsAllowed and inherited Prompt(Context, Message, Default, Answer);
end;

function TNavigableFrameEnvironment.ViewportWidth: Integer;
begin
  Result := Round(MediaEnvironment.Width);
end;

function TNavigableFrameEnvironment.ViewportHeight: Integer;
begin
  Result := Round(MediaEnvironment.Height);
end;

function TNavigableFrameEnvironment.MediaEnvironment: TCssMediaEnvironment;
begin
  if FNavigable = nil then
  begin
    Result := Parent.MediaEnvironment;
    Result.Width := 0;
    Result.Height := 0;
  end
  else
    Result := FNavigable.Sink.MediaEnvironment;
end;

function TNavigableFrameEnvironment.OpaqueOrigin(Context: TObject): Boolean;
var
  Origin: TUrlOrigin;
begin
  Result := False;
  if not (Context is TBindingContext) then
    Exit;
  Origin := DocumentOrigin(TBindingContext(Context).Document);
  Result := Origin.Opaque;
end;

function TNavigableFrameEnvironment.GetCookies(Context: TObject; const Url: string): string;
begin
  if OpaqueOrigin(Context) then
    Exit('');
  Result := inherited GetCookies(Context, Url);
end;

procedure TNavigableFrameEnvironment.SetCookie(Context: TObject; const Url, Cookie: string);
begin
  if not OpaqueOrigin(Context) then
    inherited SetCookie(Context, Url, Cookie);
end;

function TNavigableFrameEnvironment.NavigationTiming(Context: TObject): TScriptNavigationTiming;
begin
  Result := Parent.NavigationTiming(Context);
end;

function TNavigableFrameEnvironment.RequestAnimationFrame(Context: TObject): Boolean;
begin
  Result := Parent.RequestAnimationFrame(Context);
end;

end.

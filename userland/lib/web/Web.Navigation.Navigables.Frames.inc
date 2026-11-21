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
  Web.Navigation.Navigables: child navigables (HTML 7.3.1 and 4.8.5, the
  iframe element; frame elements the same) and the joint session
  history.

  - An iframe or frame that becomes connected in the active document
    gets a child navigable at once, with an initial about:blank document
    of the parent's origin (so contentWindow and contentDocument work
    right after the insertion); then its attributes are processed:
    srcdoc navigates to about:srcdoc (in a task), src to its URL
    resolved against the parent's base URL (about:blank on the first
    insertion only fires the load event, at once); loading=lazy waits
    for the parent's load event. A URL of an ancestor's document is not
    loaded again (no endless nesting), nor anything deeper than eight
    frames.
  - The navigation request is the parent document's (its client: origin,
    referrer and policy, the top-level site for SameSite cookies), with
    the destination iframe or frame and the element's referrerpolicy. A
    response that X-Frame-Options or CSP frame-ancestors keeps out of
    this frame shows an error page instead.
  - The sandbox attribute as it is at each navigation: no allow-scripts,
    no scripts; no allow-same-origin, an opaque origin; nested frames
    keep their ancestors' restrictions. The allow attribute is kept.
  - While a child loads it delays its parent's load event (not a lazy
    one); when its document has loaded, load fires at the element.
  - A navigation while the child or its parent is still loading
    replaces the child's entry; later ones add an entry to the child's
    history and one naming it to the top-level history (the joint
    session history): Back over such an entry traverses the child.
  - The element leaving, or its document being unloaded, detaches the
    child at once (loading stopped, its scripts' windows closed, its
    rendering taken away) and frees it in a later task.
}

const
  MaximumFrameDepth = 8;

var
  SrcdocNavigator: TObject;

type
  { A srcdoc navigation waiting for its task. }
  TSrcdocNavigation = class
  public
    Navigable: TNavigable;
    Html: string;
  end;

  TSrcdocNavigator = class
  public
    procedure Run(Data: TObject);
  end;

procedure TSrcdocNavigator.Run(Data: TObject);
var
  Pending: TSrcdocNavigation;
begin
  Pending := TSrcdocNavigation(Data);
  if not Pending.Navigable.FDetached then
    Pending.Navigable.NavigateToSrcdoc(Pending.Html);
end;

constructor TNavigable.CreateChild(AParent: TNavigable; AContainer: TElement);
begin
  inherited Create;
  FParent := AParent;
  FContainer := AContainer;
  FContainer.Retain;
  FFetcher := AParent.FFetcher;
  FLoop := AParent.FLoop;
  FSettings := AParent.FSettings;
  FSettings.LoadIcons := False;
  FExecutor := AParent.FExecutor;
  FHistory := TSessionHistory.Create;
  FConsumer := TNavigationConsumer.Create;
  FConsumer.Navigable := Self;
  FGarbage := TList.Create;
  FTraverseIndex := -1;
  FChildren := TList.Create;
  FId := NewNavigableId;
  FFrameName := AContainer.AttributeValueOf(AtomName);
  TakeContainerSandbox;
  FSink := AParent.FSink.CreateChildSink(Self);
  FOwnsSink := True;
  FObserver := TNavigableObserver(FSink.NavigableObserver);
  CreateInitialDocument;
end;

class function TNavigable.OfDocument(Document: TDocument): TNavigable;
var
  DocumentWindow: TWebWindow;
begin
  Result := nil;
  if (Document = nil) or not (Document.BrowsingContext is TDocumentLoader) then
    Exit;
  DocumentWindow := TDocumentLoader(Document.BrowsingContext).Window;
  if (DocumentWindow <> nil) and (DocumentWindow.Navigable is TNavigable) then
    Result := TNavigable(DocumentWindow.Navigable);
  if (Result <> nil) and (Result.ActiveDocument <> Document) then
    Result := nil;
end;

function TNavigable.Top: TNavigable;
begin
  Result := Self;
  while Result.FParent <> nil do
    Result := Result.FParent;
end;

function TNavigable.ChildCount: Integer;
begin
  Result := FChildren.Count;
end;

function TNavigable.Child(Index: Integer): TNavigable;
begin
  Result := TNavigable(FChildren[Index]);
end;

function TNavigable.ChildFor(Element: TElement): TNavigable;
var
  Index: Integer;
begin
  for Index := 0 to FChildren.Count - 1 do
    if TNavigable(FChildren[Index]).FContainer = Element then
      Exit(TNavigable(FChildren[Index]));
  Result := nil;
end;

function FindNamedIn(Navigable: TNavigable; const Name: string): TNavigable;
var
  Index: Integer;
begin
  for Index := 0 to Navigable.ChildCount - 1 do
  begin
    if Navigable.Child(Index).FrameName = Name then
      Exit(Navigable.Child(Index));
    Result := FindNamedIn(Navigable.Child(Index), Name);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function TNavigable.FindByName(const Name: string): TNavigable;
begin
  if Name = '' then
    Exit(nil);
  Result := FindNamedIn(Top, Name);
end;

function TNavigable.ChooseNavigable(const Target: string): TNavigable;
var
  Keyword: string;
begin
  Keyword := LowerCase(Target);
  if (Target = '') or (Keyword = '_self') then
    Result := Self
  else if Keyword = '_parent' then
  begin
    Result := FParent;
    if Result = nil then
      Result := Self;
  end
  else if Keyword = '_top' then
    Result := Top
  else if Keyword = '_blank' then
    Result := nil
  else
    Result := FindByName(Target);
end;

function TNavigable.HostObserver: TNavigableObserver;
begin
  Result := Top.FObserver;
end;

function TNavigable.FindById(Id: QWord): TNavigable;
var
  Index: Integer;
begin
  if FId = Id then
    Exit(Self);
  for Index := 0 to FChildren.Count - 1 do
  begin
    Result := TNavigable(FChildren[Index]).FindById(Id);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function NavigableDepth(Navigable: TNavigable): Integer;
begin
  Result := 0;
  while Navigable.Parent <> nil do
  begin
    Inc(Result);
    Navigable := Navigable.Parent;
  end;
end;

{ ---- the frame elements of the active document ---- }

procedure TNavigable.LoaderFrameInserted(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
var
  Frame: TNavigable;
begin
  if (Loader <> FLoader) or FDetached or (ChildFor(Element) <> nil) or not Element.IsConnected or
     (Element.NodeDocument <> FLoader.Document) or (NavigableDepth(Self) >= MaximumFrameDepth) then
    Exit;
  Frame := TNavigable.CreateChild(Self, Element);
  FChildren.Add(Frame);
  Frame.ProcessFrameAttributes(True);
end;

procedure TNavigable.LoaderFrameChanged(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
var
  Frame: TNavigable;
begin
  if (Loader <> FLoader) or FDetached then
    Exit;
  Frame := ChildFor(Element);
  if Frame = nil then
    Exit;
  if Attribute = AtomName then
    Frame.FFrameName := Element.AttributeValueOf(AtomName)
  else
    Frame.ProcessFrameAttributes(False);
end;

procedure TNavigable.LoaderFrameRemoved(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
var
  Frame: TNavigable;
begin
  Frame := ChildFor(Element);
  if Frame = nil then
    Exit;
  FChildren.Remove(Frame);
  Top.FHistory.RemoveFrameEntries(Frame.FId);
  Frame.Detach;
  Discard(Frame);
  if HostObserver <> nil then
    HostObserver.HistoryChanged(Top);
end;

procedure TNavigable.DetachChildren;
var
  Index: Integer;
  Frame: TNavigable;
begin
  for Index := FChildren.Count - 1 downto 0 do
  begin
    Frame := TNavigable(FChildren[Index]);
    Frame.Detach;
    Discard(Frame);
  end;
  FChildren.Clear;
end;

procedure TNavigable.Detach;
begin
  if FDetached then
    Exit;
  FDetached := True;
  CancelNavigation;
  CancelRefresh;
  FLazyPending := False;
  DetachChildren;
  UndelayParentLoad;
  if FWindow <> nil then
    FWindow.StopActivity;
  if FLoader <> nil then
    FLoader.Abort;
  if FObserver <> nil then
    FObserver.DocumentChanged(Self, nil, nil);
  FObserver := nil;
end;

procedure TNavigable.TakeContainerSandbox;
begin
  if FParent = nil then
    Exit;
  FAllowances := AllFrameAllowances;
  FSandboxed := FContainer.HasAttributeAtom(AtomSandbox);
  if FSandboxed then
    FAllowances := ParseSandboxAllowances(FContainer.AttributeValueOf(AtomSandbox));
  if FParent.FSandboxed then
  begin
    FSandboxed := True;
    FAllowances := FAllowances * FParent.FAllowances;
  end;
  FAllowAttribute := FContainer.GetAttribute('allow');
end;

function TNavigable.DocumentOriginForCommit(constref Url: TUrlRecord; out Origin: TUrlOrigin): Boolean;
begin
  Origin := Default(TUrlOrigin);
  Result := False;
  if FParent = nil then
    Exit;
  if FSandboxed and not (AllowSameOrigin in FAllowances) then
  begin
    Origin := NewOpaqueOrigin;
    Exit(True);
  end;
  if (Url.Scheme = 'about') and ((Url.Path = 'blank') or (Url.Path = 'srcdoc')) then
  begin
    Origin := DocumentOrigin(FContainer.NodeDocument);
    Exit(True);
  end;
end;

function TNavigable.FrameHistoryHandling(Requested: THistoryHandling): THistoryHandling;
begin
  Result := Requested;
  if Result <> HistoryPush then
    Exit;
  if FInitialAboutBlank or (FLoader = nil) or not FLoader.LoadFired or (FParent.FLoader = nil) or
     not FParent.FLoader.LoadFired then
    Result := HistoryReplace;
end;

function UrlOfAncestor(Navigable: TNavigable; constref Url: TUrlRecord): Boolean;
var
  Text: string;
begin
  Text := SerializeUrl(Url, True);
  Navigable := Navigable.Parent;
  while Navigable <> nil do
  begin
    if SerializeUrl(Navigable.CurrentUrl, True) = Text then
      Exit(True);
    Navigable := Navigable.Parent;
  end;
  Result := False;
end;

procedure TNavigable.ProcessFrameAttributes(Initial: Boolean);
var
  Source: string;
  Target: TUrlRecord;
  Options: TNavigateOptions;
  ParentLoader: TDocumentLoader;
  Pending: TSrcdocNavigation;
  HasTarget: Boolean;
begin
  if FDetached or (FParent = nil) or (FParent.FLoader = nil) then
    Exit;
  ParentLoader := FParent.FLoader;
  if FContainer.IsHtmlElement(AtomIframe) and FContainer.HasAttributeAtom(AtomSrcdoc) then
  begin
    Pending := TSrcdocNavigation.Create;
    Pending.Navigable := Self;
    Pending.Html := FContainer.AttributeValueOf(AtomSrcdoc);
    FLoop.QueueTask(TDataTask.Create(@TSrcdocNavigator(SrcdocNavigator).Run, Pending), TaskSourceNavigation, Self);
    DelayParentLoad;
    Exit;
  end;
  Source := TrimHttpWhitespace(FContainer.AttributeValueOf(AtomSrc));
  HasTarget := (Source <> '') and ParentLoader.ResolveUrl(Source, Target);
  if not HasTarget then
    ParseUrl('about:blank', Target);
  if (Target.Scheme = 'about') and (Target.Path = 'blank') and Initial then
  begin
    FireContainerLoad;
    Exit;
  end;
  if (Target.Scheme = 'javascript') or UrlOfAncestor(Self, Target) then
    Exit;
  Options := DefaultNavigateOptions;
  Options.Source := ParentLoader;
  Options.ReferrerPolicy := ReferrerPolicyFromAttribute(FContainer.GetAttribute('referrerpolicy'));
  if Initial and (LowerCase(FContainer.AttributeValueOf(AtomLoading)) = 'lazy') and not ParentLoader.LoadFired then
  begin
    FLazyPending := True;
    FLazyUrl := Target;
    Exit;
  end;
  Navigate(Target, Options);
end;

procedure TNavigable.NavigateToSrcdoc(const Html: string);
var
  Url: TUrlRecord;
begin
  CancelNavigation;
  CancelRefresh;
  TakeContainerSandbox;
  FNavigationHandling := FrameHistoryHandling(HistoryPush);
  ParseUrl('about:srcdoc', Url);
  CommitDocument(Url, ContentHtml, 'utf-8');
  FLoader.ReceiveBytes(PChar(Html), Length(Html));
  FLoader.EndOfInput;
end;

procedure TNavigable.FireContainerLoad;
begin
  if (FContainer = nil) or FDetached or not FContainer.IsConnected then
    Exit;
  FireEvent(FContainer, 'load');
end;

procedure TNavigable.DelayParentLoad;
begin
  if (FParent = nil) or (FDelayedLoader <> nil) or (FParent.FLoader = nil) or FParent.FLoader.LoadFired or
     FLazyPending then
    Exit;
  FDelayedLoader := FParent.FLoader;
  FDelayedLoader.DelayLoad;
end;

procedure TNavigable.UndelayParentLoad;
var
  Delayed: TDocumentLoader;
begin
  if FDelayedLoader = nil then
    Exit;
  Delayed := FDelayedLoader;
  FDelayedLoader := nil;
  if (FParent <> nil) and (FParent.FLoader = Delayed) then
    Delayed.UndelayLoad;
end;

procedure TNavigable.StartLazyFrames;
var
  Index: Integer;
  Frame: TNavigable;
  Options: TNavigateOptions;
begin
  for Index := 0 to FChildren.Count - 1 do
  begin
    Frame := TNavigable(FChildren[Index]);
    if not Frame.FLazyPending then
      Continue;
    Frame.FLazyPending := False;
    Options := DefaultNavigateOptions;
    Options.Source := FLoader;
    Options.ReferrerPolicy := ReferrerPolicyFromAttribute(Frame.FContainer.GetAttribute('referrerpolicy'));
    Frame.Navigate(Frame.FLazyUrl, Options);
  end;
end;

function TNavigable.ResponseMayBeFramed(Response: TFetchResponse; constref Url: TUrlRecord): Boolean;
var
  Ancestors: TOriginArray;
  Ancestor: TNavigable;
begin
  Ancestors := nil;
  Ancestor := FParent;
  while Ancestor <> nil do
  begin
    SetLength(Ancestors, Length(Ancestors) + 1);
    Ancestors[High(Ancestors)] := DocumentOrigin(Ancestor.ActiveDocument);
    Ancestor := Ancestor.FParent;
  end;
  Result := MayBeFramed(Url, Response.Headers.Combined('content-security-policy'),
    Response.Headers.Combined('x-frame-options'), Ancestors);
end;

{ ---- the joint session history ---- }

procedure TNavigable.AddFrameEntry(Frame: TNavigable);
var
  Entry, Current: TSessionHistoryEntry;
begin
  Current := FHistory.Current;
  if Current = nil then
    Exit;
  Entry := TSessionHistoryEntry.Create;
  Entry.Url := Current.Url;
  Entry.Title := Current.Title;
  Entry.DocumentId := FCurrentDocumentId;
  Entry.State := Current.State;
  Entry.FrameId := Frame.FId;
  Entry.FrameIndex := Frame.FHistory.Index;
  FHistory.Push(Entry);
  if FObserver <> nil then
    FObserver.HistoryChanged(Self);
end;

{ Traversing the top-level history to TargetIndex when only child
  navigables step (the same top-level document and URL): each child
  crossed goes to the entry the last crossed step names. False when it
  is not such a traversal. }
function TNavigable.TraverseFrames(TargetIndex: Integer): Boolean;
var
  Ids: array of QWord;
  Targets: array of Integer;
  Current, Index, Slot: Integer;
  Entry: TSessionHistoryEntry;
  Frame: TNavigable;

  procedure SetTarget(Id: QWord; Target: Integer);
  var
    Position: Integer;
  begin
    for Position := 0 to High(Ids) do
      if Ids[Position] = Id then
      begin
        Targets[Position] := Target;
        Exit;
      end;
    SetLength(Ids, Length(Ids) + 1);
    SetLength(Targets, Length(Targets) + 1);
    Ids[High(Ids)] := Id;
    Targets[High(Targets)] := Target;
  end;

begin
  Result := False;
  Ids := nil;
  Targets := nil;
  Current := FHistory.Index;
  if (TargetIndex = Current) or (FHistory.Current = nil) then
    Exit;
  for Index := Min(Current, TargetIndex) to Max(Current, TargetIndex) do
    if FHistory[Index].DocumentId <> FCurrentDocumentId then
      Exit;
  if FHistory[TargetIndex].UrlText <> FHistory[Current].UrlText then
    Exit;
  if TargetIndex < Current then
  begin
    for Index := Current downto TargetIndex + 1 do
    begin
      Entry := FHistory[Index];
      if Entry.FrameId <> 0 then
        SetTarget(Entry.FrameId, Entry.FrameIndex - 1);
    end;
  end
  else
    for Index := Current + 1 to TargetIndex do
    begin
      Entry := FHistory[Index];
      if Entry.FrameId <> 0 then
        SetTarget(Entry.FrameId, Entry.FrameIndex);
    end;
  if Length(Ids) = 0 then
    Exit;
  CancelNavigation;
  FHistory.Index := TargetIndex;
  for Slot := 0 to High(Ids) do
  begin
    Frame := FindById(Ids[Slot]);
    if Frame <> nil then
      Frame.TraverseToIndex(Targets[Slot]);
  end;
  if FObserver <> nil then
    FObserver.HistoryChanged(Self);
  Result := True;
end;

procedure TNavigable.TraverseToIndex(TargetIndex: Integer);
begin
  if (TargetIndex < 0) or (TargetIndex >= FHistory.Count) or (TargetIndex = FHistory.Index) then
    Exit;
  Traverse(TargetIndex - FHistory.Index);
end;

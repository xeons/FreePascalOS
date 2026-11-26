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
  bindings/Documents.webidl: Document (DOM and HTML) and
  DOMImplementation. document.write and friends go to the context's
  parser host; the HTML collections (images, links, forms ...) are
  THtmlCollection filters.
}
unit Web.Bindings.Documents;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Documents.Members.inc}

implementation

uses
  SysUtils,
  Js.Objects,
  Url.Records,
  Url.Parser,
  Web.Atoms,
  Web.Namespaces,
  Js.Engine,
  Js.Functions,
  Web.Dom,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.Exceptions,
  Web.Html.Markup,
  Web.Html.Parser,
  Web.Bindings.Context,
  Web.Bindings.Shadow,
  Web.Bindings.UrlResolution;

type
  TDocumentCollectionKind = (CollectionImages, CollectionEmbeds, CollectionLinks, CollectionForms,
    CollectionScripts);

  TDocumentCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
  public
    Kind: TDocumentCollectionKind;
  end;

function TDocumentCollection.Matches(Element: TElement): Boolean;
begin
  Result := False;
  if not Element.IsHtml then
    Exit;
  case Kind of
    CollectionImages:
      Result := Element.LocalNameAtom = AtomImg;
    CollectionEmbeds:
      Result := Element.LocalNameAtom = AtomEmbed;
    CollectionLinks:
      Result := ((Element.LocalNameAtom = AtomA) or (Element.LocalNameAtom = AtomArea)) and
        Element.HasAttributeAtom(AtomHref);
    CollectionForms:
      Result := Element.LocalNameAtom = AtomForm;
    CollectionScripts:
      Result := Element.LocalNameAtom = AtomScript;
  end;
end;

function ThisDocument(const Call: TBindingCall): TDocument; inline;
begin
  Result := TDocument(Call.Target);
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

{ A new document's wrapper: the wrapper's reference replaces the
  creator's. }
function AdoptNewDocument(const Call: TBindingCall; Document: TDocument): TJsValue;
begin
  try
    Result := Context(Call).WrapNode(Document);
  finally
    Document.Release;
  end;
end;

function Collection(const Call: TBindingCall; Kind: TDocumentCollectionKind): TJsValue;
var
  Items: TDocumentCollection;
begin
  Items := TDocumentCollection.Create(ThisDocument(Call));
  Items.Kind := Kind;
  Result := Context(Call).WrapObject(Items, InterfaceHTMLCollection, True, Call.This);
end;

{ Document.parseHTMLUnsafe(html): an HTML document of about:blank,
  scripting off, declarative shadow roots allowed. }
function Document_parseHTMLUnsafe(var Call: TBindingCall): TJsValue;
var
  Document: TDocument;
begin
  Document := ParseHtmlText(Call.Text(0), False, True);
  Document.ContentType := 'text/html';
  Document.Url := 'about:blank';
  Result := AdoptNewDocument(Call, Document);
end;

function Document_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := AdoptNewDocument(Call, TDocument.CreateDocument(False));
  Context(Call).AdjustConstructedPrototype(Result, Call);
end;

function Document_get_implementation(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisDocument(Call), InterfaceDOMImplementation, False, Call.This);
end;

function Document_get_URL(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(DocumentUrlText(ThisDocument(Call)));
end;

function Document_get_documentURI(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(DocumentUrlText(ThisDocument(Call)));
end;

function Document_get_compatMode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).CompatMode);
end;

function Document_get_characterSet(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).CharacterSet);
end;

function Document_get_charset(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).CharacterSet);
end;

function Document_get_inputEncoding(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).CharacterSet);
end;

function Document_get_contentType(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).ContentType);
end;

function Document_get_doctype(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).Doctype);
end;

function Document_get_documentElement(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).DocumentElement);
end;

function Document_getElementsByTagName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisDocument(Call).GetElementsByTagName(Call.Text(0)), InterfaceHTMLCollection,
    True, JsUndefined);
end;

function Document_getElementsByTagNameNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisDocument(Call).GetElementsByTagNameNS(Call.Text(0), Call.Text(1)),
    InterfaceHTMLCollection, True, JsUndefined);
end;

function Document_getElementsByClassName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisDocument(Call).GetElementsByClassName(Call.Text(0)),
    InterfaceHTMLCollection, True, JsUndefined);
end;

{ The is member of an ElementCreationOptions argument ('' none). }
function CreationIsValue(const Call: TBindingCall; Index: Integer): string;
begin
  Result := '';
  if (Index < Length(Call.Arguments)) and (Call.Arguments[Index].Kind = bvDictionary) and
    (Call.Arguments[Index].Items[ElementCreationOptions_is].Kind = bvString) then
    Result := Call.Arguments[Index].Items[ElementCreationOptions_is].Text;
end;

function Document_createElement(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateElement(Call.Text(0), CreationIsValue(Call, 1)));
end;

function Document_createElementNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateElementNS(Call.Text(0), Call.Text(1),
    CreationIsValue(Call, 2)));
end;

function Document_createDocumentFragment(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateDocumentFragment);
end;

function Document_createTextNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateTextNode(Call.Text(0)));
end;

function Document_createCDATASection(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateCDataSection(Call.Text(0)));
end;

function Document_createComment(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateComment(Call.Text(0)));
end;

function Document_createProcessingInstruction(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateProcessingInstruction(Call.Text(0), Call.Text(1)));
end;

function Document_importNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).ImportNode(TNode(Call.Native(0)), Call.Flag(1)));
end;

function Document_adoptNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).AdoptNode(TNode(Call.Native(0))));
end;

function Document_createAttribute(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateAttribute(Call.Text(0)));
end;

function Document_createAttributeNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateAttributeNS(Call.Text(0), Call.Text(1)));
end;

{ createEvent of the event interfaces the platform scripts define
  (MessageEvent, StorageEvent ...): a new one of type "", made by its
  constructor; NotSupportedError for any other name. }
function ScriptEventInterface(const Call: TBindingCall; const Name: string): TJsValue;
const
  Names: array[0..9] of string = ('beforeunloadevent', 'compositionevent', 'devicemotionevent',
    'deviceorientationevent', 'dragevent', 'hashchangeevent', 'messageevent', 'storageevent', 'textevent',
    'touchevent');
  Interfaces: array[0..9] of string = ('BeforeUnloadEvent', 'CompositionEvent', 'DeviceMotionEvent',
    'DeviceOrientationEvent', 'DragEvent', 'HashChangeEvent', 'MessageEvent', 'StorageEvent', 'TextEvent',
    'TouchEvent');
var
  Index: Integer;
  Constructor_: TJsValue;
  Engine: TJsEngine;
begin
  Engine := Context(Call).Engine;
  for Index := Low(Names) to High(Names) do
    if Names[Index] = Name then
    begin
      Constructor_ := Engine.GetProperty(JsObjectValue(Engine.GlobalObject), Interfaces[Index]);
      if not JsIsCallable(Constructor_) then
        Break;
      try
        Exit(Engine.Construct(Constructor_, [Engine.NewString('')]));
      except
        on EJsError do
          Break;
      end;
    end;
  raise EDomException.CreateError(NotSupportedError, 'no event interface ' + Call.Text(0));
end;

function Document_createEvent(var Call: TBindingCall): TJsValue;
var
  Name: string;
  Event: TEvent;
begin
  Name := AsciiLowerCase(Call.Text(0));
  if (Name = 'event') or (Name = 'events') or (Name = 'htmlevents') or (Name = 'svgevents') then
    Event := TEvent.Create('')
  else if Name = 'customevent' then
    Event := TCustomEvent.Create('')
  else if (Name = 'uievent') or (Name = 'uievents') then
    Event := TUiEvent.Create('')
  else if (Name = 'mouseevent') or (Name = 'mouseevents') then
    Event := TMouseEvent.Create('')
  else if Name = 'keyboardevent' then
    Event := TKeyboardEvent.Create('')
  else if Name = 'focusevent' then
    Event := TFocusEvent.Create('')
  else
    Exit(ScriptEventInterface(Call, Name));
  try
    Result := Context(Call).WrapEvent(Event);
  finally
    Event.Release;
  end;
end;

function Document_get_location(var Call: TBindingCall): TJsValue;
begin
  if ThisDocument(Call) <> Context(Call).Document then
    Exit(JsNull);
  Result := Context(Call).Engine.GetProperty(JsObjectValue(Context(Call).Engine.GlobalObject), 'location');
end;

function Document_get_domain(var Call: TBindingCall): TJsValue;
var
  Url: TUrlRecord;
begin
  if ParseUrl(DocumentUrlText(ThisDocument(Call)), Url) then
    Result := Context(Call).TextValue(SerializeHost(Url.Host))
  else
    Result := Context(Call).TextValue('');
end;

function Document_set_domain(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
  raise EDomException.CreateError('SecurityError', 'document.domain cannot be set');
end;

function Document_get_referrer(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).Referrer);
end;

function Document_get_cookie(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(Context(Call).Environment.GetCookies(Context(Call),
    DocumentUrlText(ThisDocument(Call))));
end;

function Document_set_cookie(var Call: TBindingCall): TJsValue;
begin
  Context(Call).Environment.SetCookie(Context(Call), DocumentUrlText(ThisDocument(Call)), Call.Text(0));
  Result := JsUndefined;
end;

function Document_get_lastModified(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(FormatDateTime('mm"/"dd"/"yyyy hh":"nn":"ss', Now));
end;

function Document_get_readyState(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(Context(Call).ReadyState(ThisDocument(Call)));
end;

function Document_get_title(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisDocument(Call).Title);
end;

function FindTitleElement(Document: TDocument): TElement;
var
  Node: TNode;
begin
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomTitle) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Document);
  end;
  Result := nil;
end;

function Document_set_title(var Call: TBindingCall): TJsValue;
var
  Document: TDocument;
  Title: TElement;
begin
  Result := JsUndefined;
  Document := ThisDocument(Call);
  Title := FindTitleElement(Document);
  if Title = nil then
  begin
    if Document.Head = nil then
      Exit;
    Title := Document.CreateElement('title');
    Document.Head.AppendChild(Title);
  end;
  Title.TextContent := Call.Text(0);
end;

function Document_get_dir(var Call: TBindingCall): TJsValue;
var
  Root: TElement;
  Value: string;
begin
  Root := ThisDocument(Call).DocumentElement;
  Value := '';
  if (Root <> nil) and Root.IsHtml then
  begin
    Value := AsciiLowerCase(Root.AttributeValueOf(AtomDir));
    if (Value <> 'ltr') and (Value <> 'rtl') and (Value <> 'auto') then
      Value := '';
  end;
  Result := Context(Call).TextValue(Value);
end;

function Document_set_dir(var Call: TBindingCall): TJsValue;
var
  Root: TElement;
begin
  Root := ThisDocument(Call).DocumentElement;
  if (Root <> nil) and Root.IsHtml then
    Root.SetAttributeAtom(AtomDir, NamespaceNone, Call.Text(0));
  Result := JsUndefined;
end;

function Document_get_body(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).Body);
end;

function Document_set_body(var Call: TBindingCall): TJsValue;
var
  NewBody, OldBody, Root: TElement;
begin
  Result := JsUndefined;
  NewBody := TElement(Call.Native(0));
  if (NewBody = nil) or not (NewBody.IsHtmlElement(AtomBody) or NewBody.IsHtmlElement(AtomFrameset)) then
    RaiseDomError(HierarchyRequestError, 'the new body must be a body or frameset element');
  OldBody := ThisDocument(Call).Body;
  if OldBody = NewBody then
    Exit;
  if OldBody <> nil then
  begin
    OldBody.ParentNode.ReplaceChild(NewBody, OldBody);
    Exit;
  end;
  Root := ThisDocument(Call).DocumentElement;
  if Root = nil then
    RaiseDomError(HierarchyRequestError, 'the document has no root element');
  Root.AppendChild(NewBody);
end;

function Document_get_head(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).Head);
end;

function Document_get_images(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionImages);
end;

function Document_get_embeds(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionEmbeds);
end;

function Document_get_plugins(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionEmbeds);
end;

function Document_get_links(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionLinks);
end;

function Document_get_forms(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionForms);
end;

function Document_get_scripts(var Call: TBindingCall): TJsValue;
begin
  Result := Collection(Call, CollectionScripts);
end;

function Document_getElementsByName(var Call: TBindingCall): TJsValue;
var
  Nodes: TNodeArray;
  Count: Integer;
  Node: TNode;
  Name: string;
begin
  Nodes := nil;
  Count := 0;
  Name := Call.Text(0);
  Node := ThisDocument(Call).FirstChild;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtml and TElement(Node).HasAttributeAtom(AtomName) and
      (TElement(Node).AttributeValueOf(AtomName) = Name) then
    begin
      SetLength(Nodes, Count + 1);
      Nodes[Count] := Node;
      Inc(Count);
    end;
    Node := Node.NextInTree(ThisDocument(Call));
  end;
  Result := Context(Call).WrapObject(TStaticNodeList.Create(Nodes), InterfaceNodeList, True, JsUndefined);
end;

function Document_get_currentScript(var Call: TBindingCall): TJsValue;
begin
  if (Context(Call).CurrentScript <> nil) and (Context(Call).CurrentScript.NodeDocument = ThisDocument(Call)) then
    Result := Context(Call).WrapNode(Context(Call).CurrentScript)
  else
    Result := JsNull;
end;

function Document_open(var Call: TBindingCall): TJsValue;
begin
  Context(Call).DocumentOpen(ThisDocument(Call));
  Result := Call.This;
end;

function Document_close(var Call: TBindingCall): TJsValue;
begin
  Context(Call).DocumentClose(ThisDocument(Call));
  Result := JsUndefined;
end;

function JoinedText(const Call: TBindingCall): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to Call.Count - 1 do
    Result := Result + Call.Arguments[Index].Text;
end;

function Document_write(var Call: TBindingCall): TJsValue;
begin
  Context(Call).DocumentWrite(ThisDocument(Call), JoinedText(Call));
  Result := JsUndefined;
end;

function Document_writeln(var Call: TBindingCall): TJsValue;
begin
  Context(Call).DocumentWrite(ThisDocument(Call), JoinedText(Call) + #10);
  Result := JsUndefined;
end;

function Document_get_defaultView(var Call: TBindingCall): TJsValue;
begin
  if ThisDocument(Call) = Context(Call).Document then
    Result := JsObjectValue(Context(Call).Engine.GlobalObject)
  else
    Result := JsNull;
end;

function Document_hasFocus(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

function Document_get_activeElement(var Call: TBindingCall): TJsValue;
begin
  if ThisDocument(Call).FocusedElement <> nil then
    { Retargeted: the host of a focused element in a shadow tree. }
    Result := Context(Call).WrapNode(RetargetNode(ThisDocument(Call).FocusedElement, ThisDocument(Call)))
  else if ThisDocument(Call).Body <> nil then
    Result := Context(Call).WrapNode(ThisDocument(Call).Body)
  else
    Result := JsNull;
end;

function Document_get_hidden(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function Document_get_visibilityState(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue('visible');
end;

{ DOMImplementation: its native object is the document. }

function DOMImplementation_createDocumentType(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisDocument(Call).CreateDocumentType(Call.Text(0), Call.Text(1), Call.Text(2)));
end;

function DOMImplementation_createDocument(var Call: TBindingCall): TJsValue;
var
  Document: TDocument;
  Element: TElement;
  Namespace: string;
begin
  Document := TDocument.CreateDocument(False);
  try
    Document.IsXmlDocumentObject := True;
    Namespace := Call.Text(0);
    if Call.Native(2) <> nil then
      Document.AppendChild(TNode(Call.Native(2)));
    if Call.Text(1) <> '' then
    begin
      Element := Document.CreateElementNS(Namespace, Call.Text(1));
      Document.AppendChild(Element);
    end;
    if Namespace = 'http://www.w3.org/1999/xhtml' then
      Document.ContentType := 'application/xhtml+xml'
    else if Namespace = 'http://www.w3.org/2000/svg' then
      Document.ContentType := 'image/svg+xml';
    Result := Context(Call).WrapNode(Document);
  finally
    Document.Release;
  end;
end;

function DOMImplementation_createHTMLDocument(var Call: TBindingCall): TJsValue;
var
  Document: TDocument;
  Root, Head, Title: TElement;
begin
  Document := TDocument.CreateDocument(True);
  try
    Document.AppendChild(Document.CreateDocumentType('html', '', ''));
    Root := Document.CreateElement('html');
    Document.AppendChild(Root);
    Head := Document.CreateElement('head');
    Root.AppendChild(Head);
    if Call.Present(0) then
    begin
      Title := Document.CreateElement('title');
      Head.AppendChild(Title);
      Title.AppendChild(Document.CreateTextNode(Call.Text(0)));
    end;
    Root.AppendChild(Document.CreateElement('body'));
    Result := Context(Call).WrapNode(Document);
  finally
    Document.Release;
  end;
end;

function DOMImplementation_hasFeature(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

type
  { DOMParser keeps no state. }
  TDomParserData = class
  end;

function DOMParser_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).ConstructedObject(Call, TDomParserData.Create);
end;

function DOMParser_parseFromString(var Call: TBindingCall): TJsValue;
begin
  Result := AdoptNewDocument(Call, ParseMarkupDocument(Call.Text(0), Call.Text(1),
    DocumentUrlText(Context(Call).Document)));
end;

end.

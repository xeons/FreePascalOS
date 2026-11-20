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
  The DOM: the mutation algorithms and their validity checks, text and
  UTF-16 offsets, attributes and Attr nodes, ids, live collections,
  DOMTokenList, cloning and comparison, namespaces, the observer hooks,
  node lifetime (references and collection), and the parser's script
  hook with document.write.
}
unit WebTest.Dom;

{$mode objfpc}
{$H+}

interface

procedure RunDomTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Html.Markup,
  Web.Html.TreeDump;

function ChildNames(Node: TNode): string;
var
  Child: TNode;
begin
  Result := '';
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    if Result <> '' then
      Result := Result + ',';
    if Child.NodeType = NodeTypeElement then
      Result := Result + TElement(Child).LocalName
    else
      Result := Result + Child.NodeName;
    Child := Child.NextSibling;
  end;
end;

procedure TestTreeMutation;
var
  Document: TDocument;
  Root, A, B, C: TElement;
  Fragment: TDocumentFragment;
  Error: string;
begin
  Document := TDocument.CreateDocument(True);
  try
    Root := Document.CreateElement('div');
    Document.AppendChild(Root);
    A := Document.CreateElement('a');
    B := Document.CreateElement('b');
    C := Document.CreateElement('c');
    Root.AppendChild(A);
    Root.AppendChild(C);
    Root.InsertBefore(B, C);
    Check(ChildNames(Root) = 'a,b,c', 'appendChild and insertBefore');
    Check((B.PreviousSibling = A) and (B.NextSibling = C) and (B.ParentNode = Root), 'sibling links');
    Root.InsertBefore(C, A);
    Check(ChildNames(Root) = 'c,a,b', 'insertBefore moves a node');
    Root.InsertBefore(A, A);
    Check(ChildNames(Root) = 'c,a,b', 'insertBefore a node before itself');
    Root.RemoveChild(A);
    Check((ChildNames(Root) = 'c,b') and (A.ParentNode = nil), 'removeChild');
    Root.ReplaceChild(A, C);
    Check((ChildNames(Root) = 'a,b') and (C.ParentNode = nil), 'replaceChild');
    Check(A.IsConnected and not C.IsConnected, 'isConnected');
    Fragment := Document.CreateDocumentFragment;
    Fragment.AppendChild(C);
    Fragment.AppendChild(Document.CreateTextNode('t'));
    Root.AppendChild(Fragment);
    Check((ChildNames(Root) = 'a,b,c,#text') and (Fragment.FirstChild = nil), 'inserting a fragment moves its children');
    Root.Prepend([Document.CreateComment('x')]);
    Check(ChildNames(Root) = '#comment,a,b,c,#text', 'prepend');
    B.Before([Document.CreateElement('p'), Document.CreateElement('q')]);
    Check(ChildNames(Root) = '#comment,a,p,q,b,c,#text', 'before with several nodes');
    B.After([Document.CreateElement('r')]);
    B.ReplaceWith([Document.CreateElement('s')]);
    Check(ChildNames(Root) = '#comment,a,p,q,s,r,c,#text', 'after and replaceWith');
    Root.LastChild.Remove;
    Root.ReplaceChildren([Document.CreateElement('z')]);
    Check(ChildNames(Root) = 'z', 'remove and replaceChildren');

    Error := '';
    try
      Root.FirstChild.AppendChild(Root);
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'appending an ancestor is a HierarchyRequestError');
    Error := '';
    try
      Document.AppendChild(Document.CreateTextNode('x'));
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'text in a document is a HierarchyRequestError');
    Error := '';
    try
      Document.AppendChild(Document.CreateElement('second'));
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'a second document element is a HierarchyRequestError');
    Error := '';
    try
      Document.AppendChild(Document.CreateDocumentType('html', '', ''));
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'a doctype after the element is a HierarchyRequestError');
    Document.InsertBefore(Document.CreateDocumentType('html', '', ''), Root);
    Check((Document.Doctype <> nil) and (Document.DocumentElement = Root), 'a doctype before the element');
    Error := '';
    try
      Root.InsertBefore(Document.CreateElement('x'), A);
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NotFoundError, 'insertBefore a node that is not a child is a NotFoundError');
    Error := '';
    try
      Root.RemoveChild(A);
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NotFoundError, 'removeChild of a non-child is a NotFoundError');
    Error := '';
    try
      Document.CreateTextNode('a').AppendChild(Document.CreateTextNode('b'));
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'text cannot have children');
    Error := '';
    try
      Fragment := Document.CreateDocumentFragment;
      Fragment.AppendChild(Document.CreateElement('e1'));
      Fragment.AppendChild(Document.CreateElement('e2'));
      Document.ReplaceChild(Fragment, Root);
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = HierarchyRequestError, 'a fragment with two elements cannot replace the document element');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestText;
var
  Document: TDocument;
  Div1: TElement;
  Text, Second: TText;
begin
  Document := ParseHtmlText('<div>a<b>b</b>c</div>');
  try
    Div1 := TElement(Document.Body.FirstChild);
    Check(Div1.TextContent = 'abc', 'textContent');
    Div1.TextContent := 'x<y';
    Check((ChildNames(Div1) = '#text') and (Div1.FirstChild.NodeValue = 'x<y'), 'setting textContent');
    Div1.TextContent := '';
    Check(Div1.FirstChild = nil, 'setting textContent to nothing');
    Text := Document.CreateTextNode('a'#$C3#$A9#$F0#$9F#$98#$80'b');
    Div1.AppendChild(Text);
    Check(Text.Length = 5, 'length in UTF-16 code units');
    Check(Text.SubstringData(1, 3) = #$C3#$A9#$F0#$9F#$98#$80, 'substringData in UTF-16 offsets');
    Text.InsertData(1, 'X');
    Check(Text.Data = 'aX'#$C3#$A9#$F0#$9F#$98#$80'b', 'insertData');
    Text.DeleteData(2, 1);
    Check(Text.Data = 'aX'#$F0#$9F#$98#$80'b', 'deleteData');
    Text.ReplaceData(2, 2, 'yz');
    Check(Text.Data = 'aXyzb', 'replaceData over a surrogate pair');
    Second := Text.SplitText(2);
    Check((Text.Data = 'aX') and (Second.Data = 'yzb') and (Text.NextSibling = Second), 'splitText');
    Check(Second.WholeText = 'aXyzb', 'wholeText');
    Div1.AppendChild(Document.CreateTextNode(''));
    Div1.AppendChild(Document.CreateTextNode('!'));
    Div1.Normalize;
    Check((ChildNames(Div1) = '#text') and (Div1.FirstChild.NodeValue = 'aXyzb!'), 'normalize');
    Text.AppendData('?');
    Check(Text.Data = 'aXyzb!?', 'appendData');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestAttributes;
var
  Document: TDocument;
  Element: TElement;
  Attr, Other: TAttr;
  Names: TStringArray;
  Error: string;
begin
  Document := TDocument.CreateDocument(True);
  try
    Element := Document.CreateElement('DIV');
    Document.AppendChild(Element);
    Check((Element.LocalName = 'div') and (Element.TagName = 'DIV') and
      (Element.NamespaceUri = 'http://www.w3.org/1999/xhtml'), 'createElement in an HTML document');
    Element.SetAttribute('Title', 'x');
    Check(Element.GetAttribute('TITLE') = 'x', 'attribute names are lower case in HTML');
    Check(Element.HasAttribute('title') and not Element.HasAttribute('other'), 'hasAttribute');
    Element.SetAttribute('title', 'y');
    Check((Element.AttributeCount = 1) and (Element.GetAttribute('title') = 'y'), 'setAttribute changes a value');
    Element.SetAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', 'h');
    Check(Element.GetAttributeNS('http://www.w3.org/1999/xlink', 'href') = 'h', 'setAttributeNS');
    Check(Element.GetAttribute('xlink:href') = 'h', 'getAttribute by qualified name');
    Names := Element.GetAttributeNames;
    Check((Length(Names) = 2) and (Names[0] = 'title') and (Names[1] = 'xlink:href'), 'getAttributeNames');
    Check(Element.ToggleAttribute('hidden') and Element.HasAttribute('hidden'), 'toggleAttribute adds');
    Check(not Element.ToggleAttribute('hidden') and not Element.HasAttribute('hidden'), 'toggleAttribute removes');
    Check(Element.ToggleAttribute('hidden', 1) and Element.ToggleAttribute('hidden', 1), 'toggleAttribute forced on');
    Element.RemoveAttribute('hidden');
    Attr := Element.GetAttributeNode('title');
    Check((Attr <> nil) and (Attr = Element.GetAttributeNode('title')) and (Attr = Element.Attributes[0]),
      'Attr nodes keep their identity');
    Check((Attr.OwnerElement = Element) and (Attr.Value = 'y') and (Attr.Name = 'title'), 'Attr properties');
    Attr.Value := 'z';
    Check(Element.GetAttribute('title') = 'z', 'setting an Attr value changes the attribute');
    Attr.Retain;
    Element.RemoveAttributeNode(Attr);
    Check((Attr.OwnerElement = nil) and (Attr.Value = 'z') and not Element.HasAttribute('title'),
      'removeAttributeNode detaches the Attr with its value');
    Other := Document.CreateElement('span').GetAttributeNode('none');
    Check(Other = nil, 'getAttributeNode of a missing attribute');
    Element.SetAttributeNode(Attr);
    Check(Element.GetAttribute('title') = 'z', 'setAttributeNode');
    Error := '';
    try
      Document.CreateElement('p').SetAttributeNode(Attr);
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = InUseAttributeError, 'an Attr of another element is an InUseAttributeError');
    Attr.Release;
    Error := '';
    try
      Element.SetAttribute('a b', 'x');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = InvalidCharacterError, 'an attribute name with a space is an InvalidCharacterError');
    Error := '';
    try
      Element.SetAttributeNS('', 'p:x', '1');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NamespaceError, 'a prefix without a namespace is a NamespaceError');
    Error := '';
    try
      Document.CreateElement('1a');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = InvalidCharacterError, 'createElement("1a") is an InvalidCharacterError');
    Check(Document.CreateElement('my-element:x').LocalName = 'my-element:x', 'relaxed element names');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestIdsAndCollections;
var
  Document: TDocument;
  Body, First, Second, Added: TElement;
  Collection, Classes: THtmlCollection;
  Children: TNodeList;
begin
  Document := ParseHtmlText('<!DOCTYPE html><p id=a class="x y">1</p><p id=a class=y>2</p><div class="X">3</div>');
  try
    Body := Document.Body;
    First := TElement(Body.FirstChild);
    Second := TElement(First.NextSibling);
    Check(Document.GetElementById('a') = First, 'getElementById: the first of two in tree order');
    Body.RemoveChild(First);
    Check(Document.GetElementById('a') = Second, 'getElementById after removing the first');
    Body.InsertBefore(First, nil);
    Check(Document.GetElementById('a') = Second, 'getElementById: tree order, not insertion order');
    Second.Id := 'b';
    Check((Document.GetElementById('a') = First) and (Document.GetElementById('b') = Second),
      'changing an id updates the map');
    Check(Document.GetElementById('none') = nil, 'getElementById of a missing id');

    Collection := Document.GetElementsByTagName('p');
    try
      Check(Collection.Length = 2, 'getElementsByTagName');
      Added := Document.CreateElement('p');
      Body.AppendChild(Added);
      Check((Collection.Length = 3) and (Collection[1] = First) and (Collection[2] = Added), 'the collection is live');
      Check(Collection.NamedItem('b') = Second, 'namedItem by id');
    finally
      Collection.Free;
    end;
    Classes := Body.GetElementsByClassName('y');
    try
      Check(Classes.Length = 2, 'getElementsByClassName');
      Second.ClassValue := 'z';
      Check(Classes.Length = 1, 'getElementsByClassName is live');
    finally
      Classes.Free;
    end;
    Classes := Body.GetElementsByClassName('x y');
    try
      Check((Classes.Length = 1) and (Classes[0] = First), 'getElementsByClassName with two classes');
    finally
      Classes.Free;
    end;
    Classes := Body.GetElementsByClassName('x');
    try
      { The div's class is X. }
      Check(Classes.Length = 1, 'class names are case-sensitive outside quirks mode');
    finally
      Classes.Free;
    end;
    Children := Body.ChildNodes;
    Check((Children = Body.ChildNodes) and (Children.Length = 4) and (Children[0] = Second), 'childNodes');
    Body.AppendChild(Document.CreateTextNode('t'));
    Check(Children.Length = 5, 'childNodes is live');
    Check((Body.Children.Length = 4) and (Body.ChildElementCount = 4), 'children');
    Check((Body.FirstElementChild = Second) and (Body.LastElementChild = Added), 'first and last element child');
    Check(First.ClassList.Contains('x') and (First.ClassList.Length = 2), 'classList');
    First.ClassList.Add(['w', 'x']);
    Check(First.ClassValue = 'x y w', 'classList.add');
    First.ClassList.Remove(['x']);
    Check(First.ClassValue = 'y w', 'classList.remove');
    Check(First.ClassList.Toggle('v') and (First.ClassValue = 'y w v'), 'classList.toggle adds');
    Check(not First.ClassList.Toggle('y') and (First.ClassValue = 'w v'), 'classList.toggle removes');
    Check(First.ClassList.Replace('w', 'v') and (First.ClassValue = 'v'), 'classList.replace dedupes');
    Check(First.HasClass(Atomize('v')) and not First.HasClass(Atomize('w')), 'class atoms for selectors');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestCloneAndCompare;
var
  Document: TDocument;
  Source, Copy: TNode;
  Body, A, B: TElement;
begin
  Document := ParseHtmlText('<div id=d><p class=c>x<b>y</b></p><template><i>t</i></template></div>');
  try
    Body := Document.Body;
    Source := Body.FirstChild;
    Copy := Source.CloneNode(True);
    Check(Copy.IsEqualNode(Source) and not Copy.IsSameNode(Source), 'deep clone is equal');
    Check(Copy.ParentNode = nil, 'a clone has no parent');
    Check(GetInnerHtml(TElement(Copy)) = '<p class="c">x<b>y</b></p><template><i>t</i></template>',
      'deep clone copies template contents');
    Check(not Source.CloneNode(False).IsEqualNode(Source), 'a shallow clone is not equal to a parent');
    TElement(Copy).SetAttribute('id', 'e');
    Check(not Copy.IsEqualNode(Source), 'isEqualNode compares attributes');
    A := TElement(Source.FirstChild);
    B := TElement(A.LastChild);
    Check(Source.CompareDocumentPosition(B) = DocumentPositionContainedBy or DocumentPositionFollowing,
      'compareDocumentPosition: contained');
    Check(B.CompareDocumentPosition(Source) = DocumentPositionContains or DocumentPositionPreceding,
      'compareDocumentPosition: contains');
    Check(A.CompareDocumentPosition(Source.LastChild) = DocumentPositionFollowing, 'compareDocumentPosition: following');
    Check((Source.CompareDocumentPosition(Copy) and DocumentPositionDisconnected) <> 0,
      'compareDocumentPosition: disconnected');
    Check(Source.Contains(B) and not B.Contains(Source), 'contains');
    Check(B.GetRootNode = Document, 'getRootNode');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestNamespaces;
var
  Document: TDocument;
  Element: TElement;
  Error: string;
begin
  Document := TDocument.CreateDocument(True);
  try
    Element := Document.CreateElementNS('http://www.w3.org/2000/svg', 'svg:rect');
    Check((Element.LocalName = 'rect') and (Element.Prefix = 'svg') and (Element.TagName = 'svg:rect'),
      'createElementNS with a prefix');
    Document.AppendChild(Element);
    Check(Element.LookupNamespaceUri('svg') = 'http://www.w3.org/2000/svg', 'lookupNamespaceURI');
    Check(Element.LookupPrefix('http://www.w3.org/2000/svg') = 'svg', 'lookupPrefix');
    Element.SetAttributeNS('http://www.w3.org/2000/xmlns/', 'xmlns:q', 'urn:q');
    Check(Element.LookupNamespaceUri('q') = 'urn:q', 'lookupNamespaceURI through an xmlns attribute');
    Check(Element.LookupNamespaceUri('xml') = 'http://www.w3.org/XML/1998/namespace', 'the xml prefix');
    Error := '';
    try
      Document.CreateElementNS('http://example.com/', 'xml:x');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NamespaceError, 'the xml prefix in another namespace is a NamespaceError');
    Error := '';
    try
      Document.CreateElementNS('http://www.w3.org/2000/xmlns/', 'x');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NamespaceError, 'the XMLNS namespace without xmlns is a NamespaceError');
    Check(Document.CreateElementNS('', 'plain').NamespaceUri = '', 'the null namespace');
  finally
    Document.Release;
  end;
end;

type
  TRecordingObserver = class(TDocumentObserver)
  public
    Log: string;
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling,
      NextSibling: TNode); override;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); override;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); override;
    procedure NodeConnected(Node: TNode); override;
  end;

procedure TRecordingObserver.TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling,
  NextSibling: TNode);
begin
  Log := Log + Format('tree(%s,+%d,-%d) ', [Target.NodeName, Length(Added), Length(Removed)]);
end;

procedure TRecordingObserver.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
begin
  Log := Log + 'attr(' + NameOfAtom(LocalName) + ',' + OldValue + ') ';
end;

procedure TRecordingObserver.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
begin
  Log := Log + 'text(' + OldValue + ') ';
end;

procedure TRecordingObserver.NodeConnected(Node: TNode);
begin
  Log := Log + 'connected(' + Node.NodeName + ') ';
end;

procedure TestObservers;
var
  Document: TDocument;
  Observer: TRecordingObserver;
  Root, Child: TElement;
  Text: TText;
begin
  Document := TDocument.CreateDocument(True);
  Observer := TRecordingObserver.Create;
  try
    Root := Document.CreateElement('div');
    Document.AppendChild(Root);
    Document.AddObserver(Observer);
    Child := Document.CreateElement('p');
    Text := Document.CreateTextNode('a');
    Child.AppendChild(Text);
    Root.AppendChild(Child);
    Child.SetAttribute('id', 'x');
    Child.SetAttribute('id', 'y');
    Text.Data := 'b';
    Root.TextContent := 'c';
    Check(Observer.Log = 'tree(P,+1,-0) tree(DIV,+1,-0) connected(P) connected(#text) attr(id,) attr(id,x) ' +
      'text(a) connected(#text) tree(DIV,+1,-1) ', 'observer: ' + Observer.Log);
    Document.RemoveObserver(Observer);
    Document.CollectGarbage;
  finally
    Observer.Free;
    Document.Release;
  end;
end;

procedure TestLifetime;
var
  Baseline: Int64;
  Document: TDocument;
  Kept, Dropped: TElement;
begin
  CollectGarbage;
  Baseline := LiveNodeCount;
  Document := ParseHtmlText('<div><p>a</p><p>b</p></div>');
  Check(LiveNodeCount > Baseline, 'parsing makes nodes');
  Dropped := TElement(Document.Body.FirstChild.FirstChild);
  Kept := TElement(Dropped.NextSibling);
  Kept.Retain;
  Dropped.Remove;
  Kept.Remove;
  Check(ListedNodeCount = 1, 'one unreferenced detached subtree is listed');
  Document.CollectGarbage;
  Check(ListedNodeCount = 0, 'collection frees it');
  Check(Kept.TextContent = 'b', 'a referenced detached node survives collection');
  Document.Release;
  Check(Kept.NodeDocument <> nil, 'a referenced node keeps its document alive');
  Kept.Release;
  CollectGarbage;
  Check(LiveNodeCount = Baseline, Format('every node is freed (%d left)', [LiveNodeCount - Baseline]));

  Document := TDocument.CreateDocument(True);
  Document.CreateElement('never-inserted').AppendChild(Document.CreateTextNode('x'));
  Document.Release;
  Check(LiveNodeCount = Baseline, 'a document frees its detached nodes when it goes');
end;

type
  TWritingScriptHost = class(TScriptHost)
  public
    Calls: Integer;
    Blocking: Boolean;
    function ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean; override;
  end;

function TWritingScriptHost.ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean;
begin
  Inc(Calls);
  if Script.TextContent = 'write' then
    Parser.DocumentWrite('<i>w</i>');
  Result := Blocking;
end;

procedure TestScriptHook;
var
  Document: TDocument;
  Parser: THtmlParser;
  Host: TWritingScriptHost;
begin
  Host := TWritingScriptHost.Create;
  Document := TDocument.CreateDocument(True);
  try
    Parser := THtmlParser.Create(Document);
    try
      Parser.ScriptHost := Host;
      Parser.WriteText('<p>a<script>write</script>b');
      Parser.Finish;
    finally
      Parser.Free;
    end;
    Check(Host.Calls = 1, 'the script host is called at the script end tag');
    Check(GetInnerHtml(Document.Body) = '<p>a<script>write</script><i>w</i>b</p>',
      'document.write inserts at the insertion point');
  finally
    Document.Release;
  end;

  Document := TDocument.CreateDocument(True);
  try
    Parser := THtmlParser.Create(Document);
    try
      Host.Blocking := True;
      Parser.ScriptHost := Host;
      Parser.WriteText('<p>a<script>x</script>b');
      Check(Parser.Paused and (Document.Body.TextContent = 'ax'), 'a blocking script pauses the parser');
      Parser.WriteText('c');
      Check(Document.Body.TextContent = 'ax', 'input waits while the parser is paused');
      Host.Blocking := False;
      Parser.Resume;
      Parser.Finish;
      Check(not Parser.Paused and (Document.Body.TextContent = 'axbc'), 'resume carries on');
    finally
      Parser.Free;
    end;
  finally
    Document.Release;
    Host.Free;
  end;
end;

procedure TestMarkup;
var
  Document: TDocument;
  Element: TElement;
  Error: string;
begin
  Document := ParseHtmlText('<div id=d><span>x</span></div><table id=t></table>');
  try
    Element := Document.GetElementById('d');
    Check(GetOuterHtml(Element) = '<div id="d"><span>x</span></div>', 'outerHTML');
    SetInnerHtml(Element, '<b>1</b>2&amp;');
    Check(GetInnerHtml(Element) = '<b>1</b>2&amp;', 'innerHTML');
    SetInnerHtml(Document.GetElementById('t'), '<tr><td>c');
    Check(GetInnerHtml(Document.GetElementById('t')) = '<tbody><tr><td>c</td></tr></tbody>',
      'innerHTML parses in the context of the element');
    InsertAdjacentHtml(Element, 'beforebegin', '<hr>');
    InsertAdjacentHtml(Element, 'afterbegin', '<i>a</i>');
    InsertAdjacentHtml(Element, 'beforeend', '<i>z</i>');
    InsertAdjacentHtml(Element, 'afterend', '<br>');
    Check(GetInnerHtml(Document.Body) = '<hr><div id="d"><i>a</i><b>1</b>2&amp;<i>z</i></div><br>' +
      '<table id="t"><tbody><tr><td>c</td></tr></tbody></table>', 'insertAdjacentHTML');
    SetOuterHtml(Element, '<p>new</p>');
    Check(Document.GetElementById('d') = nil, 'outerHTML replaces the element');
    Error := '';
    try
      SetOuterHtml(Document.DocumentElement, 'x');
    except
      on Failure: EDomException do
        Error := Failure.ErrorName;
    end;
    Check(Error = NoModificationAllowedError, 'outerHTML of the document element');
    Element := Document.CreateElement('template');
    SetInnerHtml(Element, '<td>x</td>');
    Check((Element.FirstChild = nil) and (GetInnerHtml(Element) = '<td>x</td>'),
      'innerHTML of a template goes into its contents');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure TestDocumentProperties;
var
  Document: TDocument;
begin
  Document := ParseHtmlText('<!DOCTYPE html><title> A  title </title><body>x');
  try
    Check(Document.Title = 'A title', 'title');
    Check(Document.CompatMode = 'CSS1Compat', 'compatMode');
    Check((Document.Head <> nil) and (Document.Body <> nil) and (Document.Doctype.Name = 'html'), 'head, body, doctype');
    Check(Document.NodeName = '#document', 'nodeName');
  finally
    Document.Release;
  end;
  Document := ParseHtmlText('x');
  try
    Check(Document.CompatMode = 'BackCompat', 'compatMode in quirks mode');
  finally
    Document.Release;
  end;
end;

procedure RunDomTests;
begin
  TestTreeMutation;
  TestText;
  TestAttributes;
  TestIdsAndCollections;
  TestCloneAndCompare;
  TestNamespaces;
  TestObservers;
  TestLifetime;
  TestScriptHook;
  TestMarkup;
  TestDocumentProperties;
end;

end.

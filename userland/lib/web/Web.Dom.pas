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
  The DOM Standard's node tree: Node and its kinds (Document,
  DocumentType, DocumentFragment, Element, Attr, Text, CDATASection,
  Comment, ProcessingInstruction), the tree mutation algorithms with
  their validity checks, live NodeList and HTMLCollection, DOMTokenList,
  NamedNodeMap, ids, and the hooks later phases build on.

  The classes refer to each other, so they share this unit; the code is
  spread over include files by concern (Web.Dom.*.inc).

  Memory
  ------
  Nodes are small: a node keeps its kind, flags, namespace id (namespace
  and prefix in 16 bits, Web.Namespaces) and local name atom in 8 bytes;
  the tree links; its document; a slot for layout data (computed style,
  boxes); and a pointer to rarely needed data (the script wrapper,
  reference counts, listeners, cached lists, Attr objects, template
  contents), made
  on demand. Only containers (documents, fragments, elements) have child
  links. On 64-bit machines an element object is 88 bytes and a text
  node 72 (plus the heap's header and the text's string): the reference
  counts, which few nodes need, are in the rare data. Attributes are an array of 16 byte records (value, local name
  atom, namespace id); Attr objects exist only when asked for.

  Text is kept as UTF-8. The DOM's offsets and lengths are in UTF-16 code
  units: CharacterData converts them (Web.Encoding.Utf8), and a node
  remembers whether its text is ASCII, in which case the offsets are the
  same and no scan is needed. A lone surrogate set from script is kept as
  generalized UTF-8 (WTF-8).

  Lifetime
  --------
  A node is kept alive by its parent, and by references: Retain/Release
  (the script bindings hold one per wrapper; Pascal code holds one while
  it keeps a node it might lose). A node counts the references of its
  whole subtree, so a detached subtree knows at once whether anything in
  it is referenced; a referenced detached subtree keeps its document
  alive. A document lives while it is referenced (its creator holds the
  first reference) or anything in its tree or detached from it is.
  Detached, unreferenced subtrees (removed nodes, nodes made and never
  inserted) are listed and freed by CollectGarbage, which the owner calls
  between script tasks (never in the middle of an algorithm), and when a
  document goes. So a node removed by an algorithm stays valid until the
  next collection.

  Hooks for later phases
  ----------------------
  TDocumentObserver gets the tree, attribute and text changes (the base
  of MutationObserver, style invalidation and the "becomes connected"
  steps of scripts); TDocument.ElementClassFor picks the element class
  (the bindings will add HTMLElement subclasses); LayoutData and
  ScriptWrapper are free for layout and the bindings.
}
unit Web.Dom;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Dom.Exceptions;

const
  NodeTypeElement = 1;
  NodeTypeAttribute = 2;
  NodeTypeText = 3;
  NodeTypeCDataSection = 4;
  NodeTypeProcessingInstruction = 7;
  NodeTypeComment = 8;
  NodeTypeDocument = 9;
  NodeTypeDocumentType = 10;
  NodeTypeDocumentFragment = 11;

  { compareDocumentPosition }
  DocumentPositionDisconnected = $01;
  DocumentPositionPreceding = $02;
  DocumentPositionFollowing = $04;
  DocumentPositionContains = $08;
  DocumentPositionContainedBy = $10;
  DocumentPositionImplementationSpecific = $20;

  { Node flags. }
  NodeFlagContainer = $01;
  NodeFlagConnected = $02;
  NodeFlagAsciiKnown = $04;
  NodeFlagAscii = $08;
  NodeFlagHasId = $10;
  NodeFlagHasClass = $20;

  { Element state flags (in the rare data). }
  ElementStateParserInserted = $0001;
  ElementStateAlreadyStarted = $0002;
  ElementStateForceAsync = $0004;
  ElementStateFromDocumentWrite = $0008;

type
  TNode = class;
  TContainerNode = class;
  TCharacterData = class;
  TText = class;
  TCDataSection = class;
  TComment = class;
  TProcessingInstruction = class;
  TDocumentType = class;
  TElement = class;
  TAttr = class;
  TDocumentFragment = class;
  TDocument = class;
  TNodeList = class;
  THtmlCollection = class;
  TDomTokenList = class;
  TNamedNodeMap = class;
  TNodeRareData = class;

  TNodeArray = array of TNode;
  TElementArray = array of TElement;
  TAttrArray = array of TAttr;
  TElementClass = class of TElement;

  TDocumentMode = (DocumentModeNoQuirks, DocumentModeQuirks, DocumentModeLimitedQuirks);
  { document.readyState (HTML Standard 3.1.5). }
  TDocumentReadyState = (ReadyStateLoading, ReadyStateInteractive, ReadyStateComplete);
  TDocumentNotifyEvent = procedure(Sender: TObject) of object;

  TAttributeRecord = record
    Value: string;
    LocalName: TAtom;
    NamespaceId: TNamespaceId;
  end;
  PAttributeRecord = ^TAttributeRecord;
  TAttributeArray = array of TAttributeRecord;

  { Told about the changes in a document's trees (including detached
    nodes of the document), after each change. TreeMutated gets exactly
    the tree mutation records MutationObserver would queue. }
  TDocumentObserver = class
  public
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray;
      PreviousSibling, NextSibling: TNode); virtual;
    { The "children changed steps" of Parent. }
    procedure ChildrenChanged(Parent: TNode); virtual;
    { Node (and each inclusive descendant, one call each, in tree order)
      became connected, or disconnected. }
    procedure NodeConnected(Node: TNode); virtual;
    procedure NodeDisconnected(Node: TNode); virtual;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); virtual;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); virtual;
    { A form control's value, checkedness, selectedness or selection
      changed (state that is not in its attributes). }
    procedure ControlStateChanged(Element: TElement); virtual;
    { The document's focused element changed (either may be nil). }
    procedure FocusChanged(Old, New: TElement); virtual;
  end;

  TDocumentObserverArray = array of TDocumentObserver;

  TNode = class(TEventTarget)
  private
    FNodeType: Byte;
    FFlags: Byte;
    FNamespaceId: TNamespaceId;
    FLocalName: TAtom;
    FParent: TContainerNode;
    FPreviousSibling: TNode;
    FNextSibling: TNode;
    FOwnerDocument: TDocument;
    FLayoutData: Pointer;
    FRareData: TNodeRareData;
    function GetFirstChild: TNode; inline;
    function GetLastChild: TNode; inline;
    function GetParentElement: TElement;
    function GetIsConnected: Boolean; inline;
    function GetChildNodes: TNodeList;
    function GetOwnerDocumentForScript: TDocument;
    function GetPreviousElementSibling: TElement;
    function GetNextElementSibling: TElement;
    function GetRareData: TNodeRareData;
    function GetSubtreeReferences: LongWord;
    function GetScriptWrapper: Pointer;
    procedure SetScriptWrapper(Value: Pointer);
  protected
    function GetNodeName: string; virtual; abstract;
    function GetNodeValue: string; virtual;
    procedure SetNodeValue(const Value: string); virtual;
    function GetTextContent: string; virtual;
    procedure SetTextContent(const Value: string); virtual;
    function GetListenerList(CreateIfMissing: Boolean): TEventListenerList; override;
    function GetTheParent(Event: TEvent): TEventTarget; override;
    { A copy of this node alone (the "clone a node" steps). }
    function CloneSelf(Document: TDocument): TNode; virtual; abstract;
    function IsEqualSelf(Other: TNode): Boolean; virtual;
    property RareData: TNodeRareData read GetRareData;
  public
    destructor Destroy; override;
    { The form control state object of the node (nil if none); the node
      owns it (Web.Dom.FormControls keeps it). }
    function FormStateObject: TObject;
    procedure SetFormStateObject(Value: TObject);
    procedure RetainTarget; override;
    procedure ReleaseTarget; override;
    { References: see the unit's description. }
    procedure Retain;
    procedure Release;
    function IsContainer: Boolean; inline;
    { The insert algorithm without the pre-insertion checks: for the
      parser, which only makes valid trees. Child nil appends. }
    procedure InsertNodeBefore(Node, Child: TNode);
    function IsElement: Boolean; inline;
    function IsText: Boolean; inline;
    function HasChildNodes: Boolean; inline;
    function GetRootNode: TNode;
    function Contains(Other: TNode): Boolean;
    function IsInclusiveAncestorOf(Other: TNode): Boolean;
    function CompareDocumentPosition(Other: TNode): Word;
    function IsSameNode(Other: TNode): Boolean;
    function IsEqualNode(Other: TNode): Boolean;
    function CloneNode(Deep: Boolean = False): TNode;
    procedure Normalize;
    { The first child, and the child at Index (0 based) of this node. }
    function ChildAt(Index: Integer): TNode;
    function ChildCount: Integer;
    { The index of this node among its siblings. }
    function IndexInParent: Integer;
    { Tree order iteration: the node after this one in Root's subtree. }
    function NextInTree(Root: TNode = nil): TNode;
    function NextInTreeSkippingChildren(Root: TNode = nil): TNode;
    function PreviousInTree: TNode;
    function LookupPrefix(const Namespace: string): string;
    function LookupNamespaceUri(const PrefixText: string): string;
    function IsDefaultNamespace(const Namespace: string): Boolean;
    { The mutation methods (Node). }
    function InsertBefore(Node, Child: TNode): TNode;
    function AppendChild(Node: TNode): TNode;
    function ReplaceChild(Node, Child: TNode): TNode;
    function RemoveChild(Child: TNode): TNode;
    { ParentNode }
    function FirstElementChild: TElement;
    function LastElementChild: TElement;
    function ChildElementCount: Integer;
    function Children: THtmlCollection;
    procedure Prepend(const Nodes: array of TNode);
    procedure Append(const Nodes: array of TNode);
    procedure ReplaceChildren(const Nodes: array of TNode);
    { ChildNode }
    procedure Before(const Nodes: array of TNode);
    procedure After(const Nodes: array of TNode);
    procedure ReplaceWith(const Nodes: array of TNode);
    procedure Remove;
    function GetElementsByTagName(const QualifiedName: string): THtmlCollection;
    function GetElementsByTagNameNS(const Namespace, LocalNameText: string): THtmlCollection;
    function GetElementsByClassName(const ClassNames: string): THtmlCollection;
    property NodeType: Byte read FNodeType;
    property NodeName: string read GetNodeName;
    property NodeValue: string read GetNodeValue write SetNodeValue;
    property TextContent: string read GetTextContent write SetTextContent;
    property ParentNode: TContainerNode read FParent;
    property ParentElement: TElement read GetParentElement;
    property FirstChild: TNode read GetFirstChild;
    property LastChild: TNode read GetLastChild;
    property PreviousSibling: TNode read FPreviousSibling;
    property NextSibling: TNode read FNextSibling;
    property PreviousElementSibling: TElement read GetPreviousElementSibling;
    property NextElementSibling: TElement read GetNextElementSibling;
    property ChildNodes: TNodeList read GetChildNodes;
    { The node document (a document's is itself). }
    property NodeDocument: TDocument read FOwnerDocument;
    { ownerDocument: nil for a document. }
    property OwnerDocument: TDocument read GetOwnerDocumentForScript;
    property IsConnected: Boolean read GetIsConnected;
    property Flags: Byte read FFlags;
    property LocalNameAtom: TAtom read FLocalName;
    property NamespaceId: TNamespaceId read FNamespaceId;
    property LayoutData: Pointer read FLayoutData write FLayoutData;
    { The script binding's wrapper (kept with the rare data: most nodes
      never get one). }
    property ScriptWrapper: Pointer read GetScriptWrapper write SetScriptWrapper;
    property SubtreeReferences: LongWord read GetSubtreeReferences;
  end;

  TContainerNode = class(TNode)
  private
    FFirstChild: TNode;
    FLastChild: TNode;
  public
    destructor Destroy; override;
  end;

  TCharacterData = class(TNode)
  private
    FData: string;
    function GetLength: Integer;
    function IsAscii: Boolean;
  protected
    function GetNodeValue: string; override;
    procedure SetNodeValue(const Value: string); override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function IsEqualSelf(Other: TNode): Boolean; override;
  public
    { Offsets and counts in UTF-16 code units, as in the standard. }
    function SubstringData(Offset, Count: Integer): string;
    procedure AppendData(const Text: string);
    procedure InsertData(Offset: Integer; const Text: string);
    procedure DeleteData(Offset, Count: Integer);
    procedure ReplaceData(Offset, Count: Integer; const Text: string);
    { Replaces the data (UTF-8). }
    procedure SetData(const Text: string);
    { Appends without notifying anyone: only for the parser, on a node
      it is building. }
    procedure AppendDataFromParser(const Text: string);
    property Data: string read FData write SetData;
    { The length in UTF-16 code units. }
    property Length: Integer read GetLength;
  end;

  TText = class(TCharacterData)
  protected
    function GetNodeName: string; override;
    function CloneSelf(Document: TDocument): TNode; override;
  public
    function SplitText(Offset: Integer): TText;
    function WholeText: string;
  end;

  TCDataSection = class(TText)
  protected
    function GetNodeName: string; override;
    function CloneSelf(Document: TDocument): TNode; override;
  end;

  TComment = class(TCharacterData)
  protected
    function GetNodeName: string; override;
    function CloneSelf(Document: TDocument): TNode; override;
  end;

  TProcessingInstruction = class(TCharacterData)
  private
    FTarget: string;
  protected
    function GetNodeName: string; override;
    function CloneSelf(Document: TDocument): TNode; override;
    function IsEqualSelf(Other: TNode): Boolean; override;
  public
    property Target: string read FTarget;
  end;

  TDocumentType = class(TNode)
  private
    FName: string;
    FPublicId: string;
    FSystemId: string;
  protected
    function GetNodeName: string; override;
    function CloneSelf(Document: TDocument): TNode; override;
    function IsEqualSelf(Other: TNode): Boolean; override;
  public
    property Name: string read FName;
    property PublicId: string read FPublicId;
    property SystemId: string read FSystemId;
  end;

  TElement = class(TContainerNode)
  private
    FAttributes: TAttributeArray;
    function GetLocalName: string;
    function GetNamespaceUri: string;
    function GetPrefix: string;
    function GetTagName: string;
    function GetId: string;
    procedure SetId(const Value: string);
    function GetClassValue: string;
    procedure SetClassValue(const Value: string);
    function GetClassList: TDomTokenList;
    function GetAttributeMap: TNamedNodeMap;
    function GetAttributeCount: Integer; inline;
    function GetTemplateContent: TDocumentFragment;
    function GetElementState: Word;
    procedure SetElementState(Value: Word);
    procedure ChangeAttributeValue(Index: Integer; const Value: string);
    procedure AppendAttributeRecord(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
    procedure RemoveAttributeAt(Index: Integer);
    procedure AttributeChangeSteps(LocalAtom: TAtom; Namespace: TNamespaceId; const OldValue: string;
      HadValue: Boolean);
    function FindAttributeByQualifiedName(const QualifiedName: string): Integer;
    function AttrNodeFor(Index: Integer; CreateIfMissing: Boolean): TAttr;
    procedure DetachAttrNode(Index: Integer);
  protected
    function GetNodeName: string; override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function CloneSelf(Document: TDocument): TNode; override;
    function IsEqualSelf(Other: TNode): Boolean; override;
  public
    destructor Destroy; override;
    { Atoms and namespace ids (the fast path for the parser and CSS). }
    function IsHtml: Boolean; inline;
    function IsHtmlElement(Name: TAtom): Boolean; inline;
    function NamespaceAtom: TAtom; inline;
    function AttributeIndexOf(LocalAtom: TAtom; Namespace: TNamespaceId = NamespaceNone): Integer;
    function AttributeAt(Index: Integer): PAttributeRecord; inline;
    function AttributeValueOf(LocalAtom: TAtom; Namespace: TNamespaceId = NamespaceNone): string;
    function HasAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId = NamespaceNone): Boolean;
    procedure SetAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
    procedure RemoveAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId = NamespaceNone);
    { Adds an attribute without the change steps: only for the parser, on
      an element it has just made. }
    procedure AddAttributeFromParser(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
    { The class names as atoms, cached until the class attribute changes. }
    function ClassAtoms: TAtomArray;
    function HasClass(ClassAtom: TAtom): Boolean;
    { Element }
    function HasAttributes: Boolean; inline;
    function GetAttributeNames: TStringArray;
    function GetAttribute(const QualifiedName: string): string;
    function GetAttributeNS(const Namespace, LocalNameText: string): string;
    function HasAttribute(const QualifiedName: string): Boolean;
    function HasAttributeNS(const Namespace, LocalNameText: string): Boolean;
    procedure SetAttribute(const QualifiedName, Value: string);
    procedure SetAttributeNS(const Namespace, QualifiedName, Value: string);
    procedure RemoveAttribute(const QualifiedName: string);
    procedure RemoveAttributeNS(const Namespace, LocalNameText: string);
    function ToggleAttribute(const QualifiedName: string; Force: Integer = -1): Boolean;
    function GetAttributeNode(const QualifiedName: string): TAttr;
    function GetAttributeNodeNS(const Namespace, LocalNameText: string): TAttr;
    function SetAttributeNode(Attr: TAttr): TAttr;
    function RemoveAttributeNode(Attr: TAttr): TAttr;
    function Closest(Name: TAtom): TElement;
    property LocalName: string read GetLocalName;
    property NamespaceUri: string read GetNamespaceUri;
    property Prefix: string read GetPrefix;
    property TagName: string read GetTagName;
    property Id: string read GetId write SetId;
    { className }
    property ClassValue: string read GetClassValue write SetClassValue;
    property ClassList: TDomTokenList read GetClassList;
    property Attributes: TNamedNodeMap read GetAttributeMap;
    property AttributeCount: Integer read GetAttributeCount;
    { The template contents of an HTML template element. }
    property TemplateContent: TDocumentFragment read GetTemplateContent;
    { Script element state for the script processing of later phases. }
    property ElementState: Word read GetElementState write SetElementState;
  end;

  TAttr = class(TNode)
  private
    FOwnerElement: TElement;
    FDetachedValue: string;
    function GetValue: string;
    procedure SetValue(const NewValue: string);
    function GetLocalName: string;
    function GetNamespaceUri: string;
    function GetPrefix: string;
    function GetName: string;
  protected
    function GetNodeName: string; override;
    function GetNodeValue: string; override;
    procedure SetNodeValue(const Value: string); override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function CloneSelf(Document: TDocument): TNode; override;
    function IsEqualSelf(Other: TNode): Boolean; override;
  public
    property OwnerElement: TElement read FOwnerElement;
    property Value: string read GetValue write SetValue;
    property LocalName: string read GetLocalName;
    property NamespaceUri: string read GetNamespaceUri;
    property Prefix: string read GetPrefix;
    property Name: string read GetName;
  end;

  TDocumentFragment = class(TContainerNode)
  private
    FHost: TElement;
  protected
    function GetNodeName: string; override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function CloneSelf(Document: TDocument): TNode; override;
  public
    { The template element whose contents this is, if any. }
    property Host: TElement read FHost;
  end;

  TDocument = class(TContainerNode)
  private
    FMode: TDocumentMode;
    FIsHtmlDocument: Boolean;
    FContentType: string;
    FCharacterSet: string;
    FUrl: string;
    FObservers: TDocumentObserverArray;
    FIdMap: TObject;
    FTemplateContentsOwner: TDocument;
    FIsTemplateContentsOwner: Boolean;
    FScriptingEnabled: Boolean;
    FReadyState: TDocumentReadyState;
    FDefaultView: TEventTarget;
    FTargetElement: TElement;
    FFocusedElement: TElement;
    FBrowsingContext: TObject;
    FOnReadyStateChange: TDocumentNotifyEvent;
    procedure SetReadyState(Value: TDocumentReadyState);
    function GetReadyStateText: string;
    function GetDocumentElement: TElement;
    function GetDoctype: TDocumentType;
    function GetHead: TElement;
    function GetBody: TElement;
    function GetCompatMode: string;
    function GetTitle: string;
    procedure NotifyTreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousNode,
      NextNode: TNode);
    procedure NotifyChildrenChanged(Parent: TNode);
    procedure NotifyAttributeChanged(Element: TElement; LocalAtom: TAtom; Namespace: TNamespaceId;
      const OldValue: string; HadValue: Boolean);
    procedure NotifyCharacterDataChanged(Node: TCharacterData; const OldValue: string);
    procedure SubtreeConnected(Root: TNode);
    procedure NotifySubtreeConnected(Root: TNode);
    procedure SubtreeDisconnected(Root: TNode);
    procedure RegisterId(Element: TElement; const IdValue: string);
    procedure UnregisterId(Element: TElement; const IdValue: string);
    procedure FreeListedNodes;
  protected
    function GetNodeName: string; override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function CloneSelf(Document: TDocument): TNode; override;
    function GetTheParent(Event: TEvent): TEventTarget; override;
  public
    { Tells the observers a form control's state changed (Web.Dom.FormControls). }
    procedure NotifyControlStateChanged(Element: TElement);
    { A new document; the caller holds its first reference (Release). }
    constructor CreateDocument(HtmlDocument: Boolean = True);
    destructor Destroy; override;
    { The element class for a name (the bindings' HTML element classes). }
    function ElementClassFor(LocalAtom: TAtom; Namespace: TNamespaceId): TElementClass; virtual;
    { Makes nodes that the caller inserts at once (the parser): they are
      not listed for collection. }
    function NewElement(LocalAtom: TAtom; Namespace: TNamespaceId): TElement;
    function NewText(const Text: string): TText;
    function NewComment(const Text: string): TComment;
    function NewDocumentType(const DoctypeName, PublicIdText, SystemIdText: string): TDocumentType;
    { Document }
    function CreateElement(const LocalNameText: string): TElement;
    function CreateElementNS(const Namespace, QualifiedName: string): TElement;
    function CreateDocumentFragment: TDocumentFragment;
    function CreateTextNode(const Text: string): TText;
    function CreateCDataSection(const Text: string): TCDataSection;
    function CreateComment(const Text: string): TComment;
    function CreateProcessingInstruction(const TargetText, Text: string): TProcessingInstruction;
    function CreateAttribute(const LocalNameText: string): TAttr;
    function CreateAttributeNS(const Namespace, QualifiedName: string): TAttr;
    function CreateDocumentType(const QualifiedName, PublicIdText, SystemIdText: string): TDocumentType;
    function ImportNode(Node: TNode; Deep: Boolean = False): TNode;
    function AdoptNode(Node: TNode): TNode;
    function GetElementById(const IdValue: string): TElement;
    { The appropriate template contents owner document. }
    function TemplateContentsOwner: TDocument;
    procedure AddObserver(Observer: TDocumentObserver);
    procedure RemoveObserver(Observer: TDocumentObserver);
    { Frees the detached, unreferenced nodes (of all documents). }
    procedure CollectGarbage;
    property Mode: TDocumentMode read FMode write FMode;
    property CompatMode: string read GetCompatMode;
    property IsHtmlDocument: Boolean read FIsHtmlDocument;
    property ContentType: string read FContentType write FContentType;
    property CharacterSet: string read FCharacterSet write FCharacterSet;
    property Url: string read FUrl write FUrl;
    property DocumentElement: TElement read GetDocumentElement;
    property Doctype: TDocumentType read GetDoctype;
    property Head: TElement read GetHead;
    property Body: TElement read GetBody;
    property Title: string read GetTitle;
    property ScriptingEnabled: Boolean read FScriptingEnabled write FScriptingEnabled;
    { Set by the loader (Web.Loading); fires readystatechange itself. }
    property ReadyState: TDocumentReadyState read FReadyState write SetReadyState;
    property ReadyStateText: string read GetReadyStateText;
    { The window (an event target the loader makes): events other than
      load bubble from the document to it. Not owned. }
    property DefaultView: TEventTarget read FDefaultView write FDefaultView;
    { The element the URL's fragment indicates (:target), or nil. }
    property TargetElement: TElement read FTargetElement write FTargetElement;
    { The focused area of the document (HTML 6.6.4: nil is its viewport);
      Web.Dom.Focus runs the focusing steps. A focused element that
      leaves the document is unfocused (the focus fixup). }
    property FocusedElement: TElement read FFocusedElement;
    procedure SetFocusedElementOnly(Element: TElement);
    { The loading side's object for this document (Web.Loading). }
    property BrowsingContext: TObject read FBrowsingContext write FBrowsingContext;
    { Called after ReadyState changed (and readystatechange fired). }
    property OnReadyStateChange: TDocumentNotifyEvent read FOnReadyStateChange write FOnReadyStateChange;
  end;

  { NodeList: live (a node's children) or a fixed list. }
  TNodeList = class
  public
    function GetLength: Integer; virtual; abstract;
    function Item(Index: Integer): TNode; virtual; abstract;
    property Length: Integer read GetLength;
    property Items[Index: Integer]: TNode read Item; default;
  end;

  TStaticNodeList = class(TNodeList)
  private
    FNodes: TNodeArray;
  public
    constructor Create(const Nodes: TNodeArray);
    destructor Destroy; override;
    function GetLength: Integer; override;
    function Item(Index: Integer): TNode; override;
  end;

  TChildNodeList = class(TNodeList)
  private
    FParent: TNode;
    FVersion: LongWord;
    FCachedLength: Integer;
    FCursorIndex: Integer;
    FCursorNode: TNode;
    procedure Refresh;
  public
    constructor Create(Parent: TNode);
    function GetLength: Integer; override;
    function Item(Index: Integer): TNode; override;
  end;

  { A live HTMLCollection over the elements of a subtree that match. }
  THtmlCollection = class
  private
    FRoot: TNode;
    FVersion: LongWord;
    FElements: TElementArray;
    FCount: Integer;
    FValid: Boolean;
    FOwnedByRoot: Boolean;
    procedure Refresh;
  protected
    function Matches(Element: TElement): Boolean; virtual; abstract;
    { Children only (element.children) rather than all descendants. }
    function ChildrenOnly: Boolean; virtual;
  public
    { OwnedByRoot: kept by the root itself (element.children), so it
      does not keep the root alive. }
    constructor Create(Root: TNode; OwnedByRoot: Boolean = False);
    destructor Destroy; override;
    function GetLength: Integer;
    function Item(Index: Integer): TElement;
    function NamedItem(const Name: string): TElement;
    property Length: Integer read GetLength;
    property Items[Index: Integer]: TElement read Item; default;
    property Root: TNode read FRoot;
  end;

  TDomTokenList = class
  private
    FElement: TElement;
    FAttributeName: TAtom;
    FSource: string;
    FTokens: TStringArray;
    FParsed: Boolean;
    procedure Update;
    procedure WriteBack;
    function GetValue: string;
    procedure SetValue(const NewValue: string);
    function GetLength: Integer;
  public
    constructor Create(Element: TElement; AttributeName: TAtom);
    function Item(Index: Integer): string;
    function Contains(const Token: string): Boolean;
    procedure Add(const Tokens: array of string);
    procedure Remove(const Tokens: array of string);
    function Toggle(const Token: string; Force: Integer = -1): Boolean;
    function Replace(const Token, NewToken: string): Boolean;
    property Value: string read GetValue write SetValue;
    property Length: Integer read GetLength;
    property Items[Index: Integer]: string read Item; default;
  end;

  TNamedNodeMap = class
  private
    FElement: TElement;
    function GetLength: Integer;
  public
    constructor Create(Element: TElement);
    function Item(Index: Integer): TAttr;
    function GetNamedItem(const QualifiedName: string): TAttr;
    function GetNamedItemNS(const Namespace, LocalNameText: string): TAttr;
    function SetNamedItem(Attr: TAttr): TAttr;
    function RemoveNamedItem(const QualifiedName: string): TAttr;
    function RemoveNamedItemNS(const Namespace, LocalNameText: string): TAttr;
    property Length: Integer read GetLength;
    property Items[Index: Integer]: TAttr read Item; default;
  end;

  TNodeRareData = class
  public
    ScriptWrapper: Pointer;
    { References to the node and its descendants (Retain/Release). }
    SubtreeReferences: LongWord;
    { Where the node is in the list of nodes to collect, plus one. }
    CollectorSlot: LongWord;
    Listeners: TEventListenerList;
    ChildNodeList: TChildNodeList;
    ChildrenCollection: THtmlCollection;
    ClassList: TDomTokenList;
    ClassAtoms: TAtomArray;
    ClassSource: string;
    ClassAtomsValid: Boolean;
    AttrNodes: TAttrArray;
    AttributeMap: TNamedNodeMap;
    TemplateContent: TDocumentFragment;
    ElementState: Word;
    { A form control's state beyond its attributes (Web.Dom.FormControls). }
    FormState: TObject;
    destructor Destroy; override;
  end;

{ Frees detached, unreferenced nodes (see the unit's description). }
procedure CollectGarbage;
{ Bumped by every change (in any document) that can change a live
  collection. }
function DomVersion: LongWord; inline;
{ How many nodes are listed for the next collection. }
function ListedNodeCount: Integer;
{ How many node objects exist (for tests and statistics). }
function LiveNodeCount: Int64;

{ Name checks of the DOM Standard (as relaxed in 2025). }
function IsValidElementLocalName(const Name: string): Boolean;
function IsValidAttributeLocalName(const Name: string): Boolean;
function IsValidNamespacePrefix(const Name: string): Boolean;
function IsValidDoctypeName(const Name: string): Boolean;

{ The "string replace all" helper for text content: the text of all
  Text descendants. }
function DescendantTextContent(Node: TNode): string;

implementation

uses
  Web.Encoding.Utf8;

{$I Web.Dom.Lifetime.inc}
{$I Web.Dom.Node.inc}
{$I Web.Dom.Mutation.inc}
{$I Web.Dom.CharacterData.inc}
{$I Web.Dom.Element.inc}
{$I Web.Dom.Attributes.inc}
{$I Web.Dom.Document.inc}
{$I Web.Dom.Collections.inc}

end.

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
  { An element that is or may become a custom element (a valid custom
    element name or an is value): the reactions only look at these. }
  NodeFlagCustomCandidate = $40;

  { Element state flags (in the rare data). }
  ElementStateParserInserted = $0001;
  ElementStateAlreadyStarted = $0002;
  ElementStateForceAsync = $0004;
  ElementStateFromDocumentWrite = $0008;
  { The style attribute was last written by the CSSOM (element.style),
    which CSP does not block; ElementStateCssomWriting is set while the
    CSSOM writes it. }
  ElementStateStyleFromCssom = $0010;
  ElementStateCssomWriting = $0020;

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
  TShadowRoot = class;
  TDocument = class;
  TNodeList = class;
  THtmlCollection = class;
  TDomTokenList = class;
  TNamedNodeMap = class;
  TNodeRareData = class;
  TLiveRange = class;
  TDocumentSelection = class;

  TNodeArray = array of TNode;
  TElementArray = array of TElement;
  TAttrArray = array of TAttr;
  TElementClass = class of TElement;

  TDocumentMode = (DocumentModeNoQuirks, DocumentModeQuirks, DocumentModeLimitedQuirks);
  { document.readyState (HTML Standard 3.1.5). }
  TDocumentReadyState = (ReadyStateLoading, ReadyStateInteractive, ReadyStateComplete);
  TDocumentNotifyEvent = procedure(Sender: TObject) of object;

  { Shadow roots (DOM Standard 4.8). }
  TShadowRootMode = (ShadowRootOpen, ShadowRootClosed);
  TSlotAssignmentMode = (SlotAssignmentNamed, SlotAssignmentManual);

  { An element's custom element state (DOM Standard 4.9); the zero
    value is "uncustomized". }
  TCustomElementState = (CustomElementUncustomized, CustomElementUndefined, CustomElementFailed,
    CustomElementPrecustomized, CustomElementCustom);

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
    { The document's selection (its range or direction) changed. }
    procedure SelectionChanged(Document: TDocument); virtual;
    { A shadow root was attached to Host (its tree is still empty). }
    procedure ShadowRootAttached(Host: TElement); virtual;
    { DOM Standard "signal a slot change": slotchange is due at Slot
      at the next mutation observer microtask. }
    procedure SlotChangeSignaled(Slot: TElement); virtual;
    { The nodes assigned to Slot changed (the flat tree under it). }
    procedure SlotAssignmentChanged(Slot: TElement); virtual;
    { Element's custom element state changed (:defined), or its custom
      states (:state()). }
    procedure CustomElementStateChanged(Element: TElement); virtual;
    { The fullscreen element or the pointer lock element left the
      document (it is no longer either): script exits the mode. }
    procedure ScreenModeElementRemoved(Element: TElement; Fullscreen: Boolean); virtual;
  end;

  { What the DOM asks of the custom element machinery (the script
    bindings implement it; nil without scripts). The DOM calls it only
    for elements flagged NodeFlagCustomCandidate. }
  TCustomElementHost = class
  public
    { Element (and the inclusive descendants it was inserted with)
      became connected: connectedCallback or an upgrade attempt. }
    procedure ElementConnected(Element: TElement); virtual; abstract;
    procedure ElementDisconnected(Element: TElement); virtual; abstract;
    procedure ElementAdopted(Element: TElement; OldDocument, NewDocument: TDocument); virtual; abstract;
    procedure ElementAttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue, NewValue: string; HadOldValue, HasNewValue: Boolean); virtual; abstract;
    { The "create an element" algorithm of the DOM Standard for Document
      when a definition may apply; nil when no custom element is
      involved (the caller makes a plain element). Synchronous: the
      constructor runs now (the parser's "will execute script"). }
    function CreateElement(Document: TDocument; LocalName: TAtom; NamespaceId: TNamespaceId;
      const IsValue: string; Synchronous: Boolean): TElement; virtual; abstract;
    { Whether Document's window has any custom element definition (the
      parser's quick check). }
    function HasDefinitions(Document: TDocument): Boolean; virtual; abstract;
    { The parser's custom element reactions scope around an insertion. }
    procedure PushReactionsScope; virtual; abstract;
    procedure PopReactionsScope; virtual; abstract;
    { A definition's reference was let go by an element (the element
      went or was customized again). }
    procedure ReleaseDefinition(Definition: TObject); virtual; abstract;
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
    { An img's current image request (nil if none); the node owns it
      (Web.Dom.ImageRequests keeps it, the image loader fills it). }
    function ImageRequestObject: TObject;
    procedure SetImageRequestObject(Value: TObject);
    { A canvas's bitmap and context (nil if none); the node owns it
      (Web.Canvas.Elements keeps it). }
    function CanvasStateObject: TObject;
    procedure SetCanvasStateObject(Value: TObject);
    procedure RetainTarget; override;
    procedure ReleaseTarget; override;
    function HeldByEvents: Boolean; override;
    { Event dispatch through shadow trees (Web.Dom.Shadow.inc). }
    function IsNodeTarget: Boolean; override;
    function TargetRoot: TEventTarget; override;
    function IsShadowIncludingInclusiveAncestorOf(Other: TEventTarget): Boolean; override;
    function AssignedSlotTarget: TEventTarget; override;
    { The shadow-including root (getRootNode({composed: true})). }
    function GetShadowIncludingRoot: TNode;
    { The shadow root this node is in (its root), nil outside one. }
    function ContainingShadowRoot: TShadowRoot;
    function IsShadowIncludingInclusiveAncestorOfNode(Other: TNode): Boolean;
    { Shadow-including tree order: the node after this one in Root's
      shadow-including subtree (an element, then its shadow root and the
      shadow tree, then its children). }
    function NextInShadowIncludingTree(Root: TNode): TNode;
    { The slot this slottable (element or text) is assigned to, nil if
      none (in any shadow root mode: callers check closed trees). }
    function AssignedSlot: TElement;
    { References: see the unit's description. }
    procedure Retain;
    procedure Release;
    { Pending activity (an image loading, its load or error event still
      to fire): the node is retained, and its script wrapper, with the
      listeners waiting for that event, kept alive even outside the
      document. Begin and End come in pairs. }
    procedure BeginPendingActivity;
    procedure EndPendingActivity;
    function HasPendingActivity: Boolean; inline;
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
    { Shadow trees (Web.Dom.Shadow.inc). The shadow root attached to
      the element in any mode, nil if none. }
    function ShadowRoot: TShadowRoot;
    { attachShadow's checks and steps (NotSupportedError for elements
      that cannot be hosts or already are, unless declarative). }
    function AttachShadow(Mode: TShadowRootMode; Clonable, Serializable, DelegatesFocus: Boolean;
      SlotAssignment: TSlotAssignmentMode): TShadowRoot;
    { Whether the element is an HTML slot element. }
    function IsSlot: Boolean; inline;
    { A slot's name (its name attribute, '' when missing). }
    function SlotName: string;
    { A slottable's name (its slot attribute, '' when missing). }
    function SlottableName: string;
    { A slot's assigned nodes (Web.Dom.Slots.inc). }
    function AssignedNodes: TNodeArray;
    { "Find flattened slottables". }
    function FlattenedAssignedNodes: TNodeArray;
    { HTMLSlotElement.assign(): the manually assigned nodes. }
    procedure AssignNodesManually(const Nodes: TNodeArray);
    { The part attribute's tokens (Element.part). }
    function PartList: TDomTokenList;
    { Custom elements (Web.Dom.CustomElements.inc). }
    function CustomElementState: TCustomElementState;
    procedure SetCustomElementState(Value: TCustomElementState);
    { The is value ('' none). }
    function IsValue: string;
    procedure SetIsValue(const Value: string);
    { The custom element definition (the bindings' object), nil if none;
      setting one holds it until the element goes. }
    function CustomElementDefinition: TObject;
    procedure SetCustomElementDefinition(Definition: TObject);
    { What the bindings keep with the element (reaction queue, element
      internals); owned by the element. }
    function CustomElementData: TObject;
    procedure SetCustomElementData(Data: TObject);
    { Web Animations' effects on the element (Web.Style.ScriptAnimations
      keeps them), owned; nil when none. }
    function GetAnimationEffects: TObject;
    procedure SetAnimationEffects(Value: TObject);
    property AnimationEffects: TObject read GetAnimationEffects write SetAnimationEffects;
    { The element is "defined" (:defined): uncustomized or custom. }
    function IsDefinedElement: Boolean;
    { A custom element's states (CustomStateSet, :state()). }
    function HasCustomState(const Name: string): Boolean;
    function CustomStates: TStringArray;
    procedure SetCustomStates(const States: TStringArray);
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
    { The template element whose contents this is, or the shadow host
      of a shadow root; nil otherwise. }
    property Host: TElement read FHost;
  end;

  { A shadow root (DOM Standard 4.8): a fragment whose host is its
    shadow host. The host owns it; references into the shadow tree keep
    the host alive. }
  TShadowRoot = class(TDocumentFragment)
  private
    FMode: TShadowRootMode;
    FDelegatesFocus: Boolean;
    FSlotAssignment: TSlotAssignmentMode;
    FClonable: Boolean;
    FSerializable: Boolean;
    FDeclarative: Boolean;
    FAvailableToElementInternals: Boolean;
    FStyleSheets: TObject;
    FStyleScope: TObject;
    FMayHaveSlots: Boolean;
    function GetModeText: string;
  protected
    function GetTheParent(Event: TEvent): TEventTarget; override;
    function CloneSelf(Document: TDocument): TNode; override;
  public
    destructor Destroy; override;
    function ShadowHostTarget: TEventTarget; override;
    function IsClosedShadowRoot: Boolean; override;
    { getElementById on the shadow tree. }
    function GetElementById(const IdValue: string): TElement;
    property Mode: TShadowRootMode read FMode;
    property ModeText: string read GetModeText;
    property DelegatesFocus: Boolean read FDelegatesFocus write FDelegatesFocus;
    property SlotAssignment: TSlotAssignmentMode read FSlotAssignment;
    property Clonable: Boolean read FClonable write FClonable;
    property Serializable: Boolean read FSerializable write FSerializable;
    property Declarative: Boolean read FDeclarative write FDeclarative;
    property AvailableToElementInternals: Boolean read FAvailableToElementInternals
      write FAvailableToElementInternals;
    { The shadow root's style sheet objects (Web.Style.DocumentSheets),
      owned. }
    property StyleSheets: TObject read FStyleSheets write FStyleSheets;
    { The styler's data for the shadow tree's scope (owned). }
    property StyleScope: TObject read FStyleScope write FStyleScope;
    { Whether a slot element was ever inserted in the shadow tree (if
      not, slot assignment has nothing to look for). }
    property MayHaveSlots: Boolean read FMayHaveSlots;
  end;

  TDocument = class(TContainerNode)
  private
    FMode: TDocumentMode;
    FIsHtmlDocument: Boolean;
    FContentType: string;
    FCharacterSet: string;
    FUrl: string;
    FReferrer: string;
    FLastModified: string;
    FObservers: TDocumentObserverArray;
    FIdMap: TObject;
    FTemplateContentsOwner: TDocument;
    FIsTemplateContentsOwner: Boolean;
    FScriptingEnabled: Boolean;
    FReadyState: TDocumentReadyState;
    FDefaultView: TEventTarget;
    FTargetElement: TElement;
    FFocusedElement: TElement;
    FPendingPointerCapture: TElement;
    FPointerCapture: TElement;
    FBrowsingContext: TObject;
    FOriginText: string;
    FOnReadyStateChange: TDocumentNotifyEvent;
    { The live ranges whose boundary points are in this document's
      trees (Web.Dom.Ranges.inc). }
    FLiveRanges: array of TLiveRange;
    FLiveRangeCount: Integer;
    FSelection: TDocumentSelection;
    FStyleSheets: TObject;
    FHasShadowRoots: Boolean;
    FFullscreenElement: TElement;
    FPointerLockElement: TElement;
    FSecurityPolicy: TObject;
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
    procedure AddLiveRange(Range: TLiveRange);
    procedure RemoveLiveRange(Range: TLiveRange);
    procedure RangesChildrenInserted(Parent: TNode; Index, Count: Integer);
    procedure RangesNodeRemoving(Node: TNode);
    procedure RangesDataReplaced(Node: TNode; Offset, Count, InsertedLength: Integer);
    procedure RangesTextSplit(Node, NewNode: TNode; Offset: Integer);
    procedure RangesTextMerged(Sibling, Node: TNode; LengthBefore: Integer);
    function GetSelection: TDocumentSelection;
  protected
    function GetNodeName: string; override;
    function GetTextContent: string; override;
    procedure SetTextContent(const Value: string); override;
    function CloneSelf(Document: TDocument): TNode; override;
    function GetTheParent(Event: TEvent): TEventTarget; override;
  public
    { Tells the observers the selection changed. }
    procedure NotifySelectionChanged;
    { The document's selection (made when first asked for). }
    property Selection: TDocumentSelection read GetSelection;
    { The document's style sheet objects (Web.Style.DocumentSheets makes
      them); freed with the document. }
    property StyleSheets: TObject read FStyleSheets write FStyleSheets;
    { Whether a shadow root was ever attached to an element of the
      document (the mutation algorithms skip slot assignment if not). }
    property HasShadowRoots: Boolean read FHasShadowRoots;
    { The Fullscreen API's fullscreen element (the top of the top layer's
      fullscreen elements; Web.Dom.Fullscreen) and the Pointer Lock
      API's element. Not references: an element leaving the document
      loses them. }
    property FullscreenElement: TElement read FFullscreenElement write FFullscreenElement;
    property PointerLockElement: TElement read FPointerLockElement write FPointerLockElement;
    { Tells the observers a custom element's state changed. }
    procedure NotifyCustomElementStateChanged(Element: TElement);
    { Tells the observers about slots (Web.Dom.Slots.inc). }
    procedure NotifySlotChangeSignaled(Slot: TElement);
    procedure NotifySlotAssignmentChanged(Slot: TElement);
    { What enforces the document's Content Security Policy: its fetch
      client (Web.Fetch.Requests; Web.Fetch.CspChecks checks against
      it), set by its loader. Not owned; nil: no policy. }
    property SecurityPolicy: TObject read FSecurityPolicy write FSecurityPolicy;
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
    { createElement and createElementNS (IsValue: the options' is). }
    function CreateElement(const LocalNameText: string; const IsValue: string = ''): TElement;
    function CreateElementNS(const Namespace, QualifiedName: string; const IsValue: string = ''): TElement;
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
    { The URL of the document that led here ('' none), and the
      response's Last-Modified field as sent ('' none): set by the
      navigation that made the document. }
    property Referrer: string read FReferrer write FReferrer;
    property LastModified: string read FLastModified write FLastModified;
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
    { The mouse pointer's capture (Pointer Events 3: the pending pointer
      capture target override and the pointer capture target override;
      Web.Dom.PointerCapture). Not references: an element that leaves
      the document loses them. }
    property PendingPointerCapture: TElement read FPendingPointerCapture write FPendingPointerCapture;
    property PointerCapture: TElement read FPointerCapture write FPointerCapture;
    { The loading side's object for this document (Web.Loading). }
    property BrowsingContext: TObject read FBrowsingContext write FBrowsingContext;
    { The document's origin when it is not its URL's (Web.Origins writes
      and reads it): a creator's (about:blank, srcdoc) or an opaque one
      (a sandboxed frame); '' for the URL's. }
    property OriginText: string read FOriginText write FOriginText;
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
    property Element: TElement read FElement;
    property AttributeName: TAtom read FAttributeName;
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

  { A live range (DOM Standard 5.5): two boundary points in one tree,
    kept valid as the tree changes (the mutation algorithms adjust
    every live range of the document). Reference counted: script
    wrappers and the document's selection hold it. It holds references
    to its boundary nodes, except while it is a document's selection
    (a selection's range is always in its document, and the document
    must not keep itself alive through it). Offsets are in UTF-16 code
    units for character data, children otherwise. }
  TLiveRange = class
  private
    FStartContainer: TNode;
    FStartOffset: Integer;
    FEndContainer: TNode;
    FEndOffset: Integer;
    FDocument: TDocument;
    FReferences: Integer;
    FRetainsNodes: Boolean;
    FSelection: TDocumentSelection;
    procedure AttachTo(Document: TDocument);
    procedure Detach;
    procedure SetBoundary(IsStart: Boolean; Node: TNode; Offset: Integer);
    procedure SetRetainsNodes(Value: Boolean);
    procedure Changed;
    { After a boundary point was set: a selection's range taken out of
      its document's tree stops being the selection (it does not hold
      its nodes while it is one), then Changed. }
    procedure Moved;
    function GetCollapsed: Boolean;
  public
    { The script binding's wrapper (Web.Bindings.Ranges), nil if none. }
    ScriptWrapper: Pointer;
    { A range collapsed at the start of Document; the caller holds the
      first reference. }
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    procedure Retain;
    procedure Release;
    { The standard's "set the start or end" (validity checks; the other
      end follows when the range would be inverted or span two trees). }
    procedure SetStart(Node: TNode; Offset: Integer);
    procedure SetEnd(Node: TNode; Offset: Integer);
    { Both ends, without checks other than Node's kind and offsets. }
    procedure SetRange(StartNode: TNode; StartOffset: Integer; EndNode: TNode; EndOffset: Integer);
    procedure Collapse(ToStart: Boolean);
    procedure SelectNode(Node: TNode);
    procedure SelectNodeContents(Node: TNode);
    { The root of the range's tree. }
    function Root: TNode;
    property StartContainer: TNode read FStartContainer;
    property StartOffset: Integer read FStartOffset;
    property EndContainer: TNode read FEndContainer;
    property EndOffset: Integer read FEndOffset;
    property Collapsed: Boolean read GetCollapsed;
    { The selection it is the range of, nil if none. }
    property Selection: TDocumentSelection read FSelection;
  end;

  TSelectionDirection = (SelectionDirectionNone, SelectionDirectionForwards, SelectionDirectionBackwards);

  { A document's selection (Selection API): empty or one range, and a
    direction; the anchor and focus are the range's ends as the
    direction says. The document owns it. }
  TDocumentSelection = class
  private
    FDocument: TDocument;
    FRange: TLiveRange;
    FDirection: TSelectionDirection;
    function GetAnchorNode: TNode;
    function GetAnchorOffset: Integer;
    function GetFocusNode: TNode;
    function GetFocusOffset: Integer;
  public
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    { Makes Range the selection's range (nil empties it). }
    procedure SetRange(Range: TLiveRange; Direction: TSelectionDirection);
    procedure RemoveAllRanges;
    { collapse(): a new collapsed range at the point. }
    procedure CollapseAt(Node: TNode; Offset: Integer);
    { setBaseAndExtent(): a new range from the anchor to the focus (in
      either order) with its direction. }
    procedure SetBaseAndExtent(AnchorNode: TNode; AnchorOffset: Integer; FocusNode: TNode; FocusOffset: Integer);
    { extend(): the focus moves, the anchor stays (a new range). }
    procedure Extend(Node: TNode; Offset: Integer);
    procedure Changed;
    { The document goes: the range (which may live on in script) lets
      go of its nodes without touching them. }
    procedure OrphanRange;
    property Document: TDocument read FDocument;
    property Range: TLiveRange read FRange;
    property Direction: TSelectionDirection read FDirection;
    property AnchorNode: TNode read GetAnchorNode;
    property AnchorOffset: Integer read GetAnchorOffset;
    property FocusNode: TNode read GetFocusNode;
    property FocusOffset: Integer read GetFocusOffset;
  end;

  TNodeRareData = class
  public
    ScriptWrapper: Pointer;
    { References to the node and its descendants (Retain/Release). }
    SubtreeReferences: LongWord;
    { Where the node is in the list of nodes to collect, plus one. }
    CollectorSlot: LongWord;
    { BeginPendingActivity calls not yet ended. }
    PendingActivity: LongWord;
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
    { An img's image request (Web.Dom.ImageRequests). }
    ImageRequest: TObject;
    { Shadow trees: an element's shadow root (owned); a slottable's
      assigned slot and manual slot assignment, a slot's assigned and
      manually assigned nodes (weak both ways: a node going takes
      itself out, Web.Dom.Slots.inc). }
    ShadowRoot: TShadowRoot;
    AssignedSlot: TElement;
    ManualSlotAssignment: TElement;
    SlotAssignedNodes: TNodeArray;
    SlotManualNodes: TNodeArray;
    PartList: TDomTokenList;
    { Custom elements: state, is value, definition (held through the
      custom element host) and the bindings' data (owned). }
    CustomState: TCustomElementState;
    IsValue: string;
    CustomDefinition: TObject;
    CustomData: TObject;
    CustomStates: TStringArray;
    { Web Animations' keyframe effects targeting the element
      (Web.Style.ScriptAnimations), owned. }
    AnimationEffects: TObject;
    { A canvas's surface (Web.Canvas.Elements). }
    CanvasState: TObject;
    destructor Destroy; override;
  end;

var
  { The custom element machinery (Web.Bindings.CustomElements sets it),
    nil when no scripts run. }
  CustomElementHost: TCustomElementHost = nil;
  { Copies a form control's state to its clone (HTML's cloning steps of
    input and textarea: the value, checkedness and their dirty flags);
    Web.Dom.FormControls sets it. }
  FormStateCloning: procedure(Source, Copy: TElement) = nil;

type
  { Walks the children of a node in the flat tree (FlatTreeFirstChild,
    FlatTreeNextChild). }
  TFlatTreeCursor = record
    Nodes: TNodeArray;
    Index: Integer;
    Current: TNode;
  end;

{ The flat tree (CSS Scoping): a node's parent there (a slottable's
  slot, a shadow tree's host), nil for nodes outside it (a host's
  unassigned children); and its children (a host's are its shadow
  root's, a slot's its assigned nodes or else its own). }
function FlatTreeParent(Node: TNode): TNode;
function FlatTreeFirstChild(Node: TNode; out Cursor: TFlatTreeCursor): TNode;
function FlatTreeNextChild(var Cursor: TFlatTreeCursor): TNode;
function HasFlatTreeChildren(Node: TNode): Boolean;

{ Frees detached, unreferenced nodes (see the unit's description). }
procedure CollectGarbage;
{ Bumped by every change (in any document) that can change a live
  collection. }
function DomVersion: LongWord; inline;
{ How many nodes are listed for the next collection. }
function ListedNodeCount: Integer;
{ How many node objects exist (for tests and statistics). }
function LiveNodeCount: Int64;

{ HTML's valid custom element name, and the same for an atom. }
function IsValidCustomElementName(const Name: string): Boolean;
function IsCustomElementNameAtom(Atom: TAtom): Boolean;

{ Name checks of the DOM Standard (as relaxed in 2025). }
function IsValidElementLocalName(const Name: string): Boolean;
function IsValidAttributeLocalName(const Name: string): Boolean;
function IsValidNamespacePrefix(const Name: string): Boolean;
function IsValidDoctypeName(const Name: string): Boolean;

{ The "string replace all" helper for text content: the text of all
  Text descendants. }
function DescendantTextContent(Node: TNode): string;

{ A node's length (DOM Standard): characters of character data (UTF-16
  code units), 0 for a doctype, else its children. }
function NodeLength(Node: TNode): Integer;
{ The position of boundary point A against B in one tree: -1 before,
  0 equal, 1 after. }
function CompareBoundaryPoints(NodeA: TNode; OffsetA: Integer; NodeB: TNode; OffsetB: Integer): Integer;

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
{$I Web.Dom.Ranges.inc}
{$I Web.Dom.Selection.inc}
{$I Web.Dom.Shadow.inc}
{$I Web.Dom.Slots.inc}
{$I Web.Dom.CustomElements.inc}

end.

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
  The ACPI namespace: the tree of named objects the AML tables define.

  Every node has a four character name, a parent and children, and a
  kind: a scope or device (holding other nodes), a name holding a value,
  a method (its AML), an operation region, a field (bits of a region,
  or reached through an index and a data field, or a bank), a buffer
  field (bits of a buffer), an alias, and the rest (mutexes, events,
  processors, power resources, thermal zones), which only hold names.

  Name strings are AML's: "\" for the root, "^" for each parent, then
  one segment, two (a dual name) or several (a multi name), or none.
  A name of one segment with no prefix is searched for in its scope,
  then in each scope above it (ACPI's search rule); longer names are
  only looked up where they say.
}
unit Firmware.AmlNamespace;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlValues;

const
  MaximumNameSegments = 16;

  { Field rules (the field's flags). }
  FieldAccessAny = 0;
  UpdatePreserve = 0;
  UpdateWriteAsOnes = 1;
  UpdateWriteAsZeros = 2;

type
  TAmlNameSegment = array[0..3] of Char;

  TAmlNodeKind = (NodeScope, NodeDevice, NodeName, NodeMethod, NodeRegion, NodeField, NodeIndexField,
    NodeBankField, NodeBufferField, NodeAlias, NodeMutex, NodeEvent, NodeProcessor, NodePowerResource,
    NodeThermalZone, NodeExternal);

  PAmlNode = ^TAmlNode;

  { A method the interpreter itself provides (\_OSI). }
  TAmlNativeMethod = function(Arguments: PAmlValue; Count: Integer; out Result: TAmlValue): Boolean;

  TAmlNode = record
    Name: TAmlNameSegment;
    Parent: PAmlNode;
    FirstChild: PAmlNode;
    NextSibling: PAmlNode;
    Kind: TAmlNodeKind;
    { Names. }
    Value: TAmlValue;
    { Methods: their code, and how many arguments they take. }
    Code: PByte;
    CodeLength: LongWord;
    ArgumentCount: Byte;
    Native: TAmlNativeMethod;
    { Operation regions. For PCI configuration space, the device's
      address (without the register), found on first use. }
    Space: Byte;
    RegionOffset: QWord;
    RegionLength: QWord;
    PciAddressKnown: Boolean;
    PciAddress: QWord;
    { Fields: their region (or index and data fields, or bank field and
      value), their bits, and how they are accessed. }
    Region: PAmlNode;
    IndexField: PAmlNode;
    DataField: PAmlNode;
    BankField: PAmlNode;
    BankValue: QWord;
    BitOffset: QWord;
    BitLength: QWord;
    AccessBytes: Byte;
    UpdateRule: Byte;
    { Buffer fields: the buffer's storage (one count held). }
    FieldBytes: PAmlBytes;
    { Aliases. }
    Target: PAmlNode;
  end;

  TAmlNamePath = record
    Absolute: Boolean;
    ParentCount: Integer;
    SegmentCount: Integer;
    Segments: array[0..MaximumNameSegments - 1] of TAmlNameSegment;
  end;

  TAmlNodeVisitor = procedure(Node: PAmlNode; Context: Pointer);

{ Makes the root and the predefined scopes (\_SB, \_GPE, \_PR, \_TZ,
  \_SI) and names (\_OS, \_REV). False if memory is short. }
function InitializeNamespace: Boolean;
function NamespaceRoot: PAmlNode;

{ Decodes the name string at Data (at most Limit bytes); Length is how
  many bytes it took. }
function DecodeNameString(Data: PByte; Limit: LongWord; out Path: TAmlNamePath; out Length: LongWord): Boolean;
{ The node Path names from Scope (nil if none), following aliases. }
function LookupPath(Scope: PAmlNode; const Path: TAmlNamePath): PAmlNode;
{ The same for a name string in AML form, and for text like
  "\_SB.PCI0._PRT" or "_STA". }
function LookupNameString(Scope: PAmlNode; Data: PByte; Limit: LongWord): PAmlNode;
function LookupText(Scope: PAmlNode; Text: PChar): PAmlNode;
{ The scope a new object named by Path goes in, and its own segment;
  nil if the scope does not exist. }
function ScopeForNewName(Scope: PAmlNode; const Path: TAmlNamePath; out Segment: TAmlNameSegment): PAmlNode;

function FindChild(Parent: PAmlNode; const Segment: TAmlNameSegment): PAmlNode;
{ The child Segment of Parent: made with Kind, or the existing one
  turned into Kind (a scope or device stays one). }
function CreateChild(Parent: PAmlNode; const Segment: TAmlNameSegment; Kind: TAmlNodeKind): PAmlNode;
{ Lets go of what a node holds (its value, buffer storage) before it is
  given a new meaning. }
procedure ClearNodeContents(Node: PAmlNode);
function SegmentOf(Text: PChar): TAmlNameSegment;

{ Calls Visit for every node under Parent, parents before children. }
procedure VisitNodes(Parent: PAmlNode; Visit: TAmlNodeVisitor; Context: Pointer);
{ The node's absolute path ("\_SB_.PCI0") into Text (Capacity bytes). }
procedure NodePathText(Node: PAmlNode; Text: PChar; Capacity: Integer);
function CountNodes: LongWord;

implementation

uses
  Runtime.Memory,
  Firmware.AmlHost;

const
  RootPrefix = $5C;
  ParentPrefix = $5E;
  DualNamePrefix = $2E;
  MultiNamePrefix = $2F;
  NullName = $00;

var
  Root: PAmlNode;
  NodeCount: LongWord;

function SegmentOf(Text: PChar): TAmlNameSegment;
var
  Index: Integer;
begin
  { Short names are padded with underscores. }
  for Index := 0 to 3 do
    Result[Index] := '_';
  Index := 0;
  while (Index < 4) and (Text[Index] <> #0) do
  begin
    Result[Index] := Text[Index];
    Inc(Index);
  end;
end;

function SameSegment(const First, Second: TAmlNameSegment): Boolean;
begin
  Result := (First[0] = Second[0]) and (First[1] = Second[1]) and (First[2] = Second[2]) and
    (First[3] = Second[3]);
end;

function FindChild(Parent: PAmlNode; const Segment: TAmlNameSegment): PAmlNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  Result := Parent^.FirstChild;
  while (Result <> nil) and not SameSegment(Result^.Name, Segment) do
    Result := Result^.NextSibling;
end;

procedure ClearNodeContents(Node: PAmlNode);
var
  Bytes: TAmlValue;
begin
  ReleaseValue(Node^.Value);
  if Node^.FieldBytes <> nil then
  begin
    { Released the way a value holding it would be. }
    ZeroMemory(@Bytes, SizeOf(Bytes));
    Bytes.Kind := AmlBuffer;
    Bytes.Bytes := Node^.FieldBytes;
    ReleaseValue(Bytes);
    Node^.FieldBytes := nil;
  end;
end;

function CreateChild(Parent: PAmlNode; const Segment: TAmlNameSegment; Kind: TAmlNodeKind): PAmlNode;
begin
  Result := FindChild(Parent, Segment);
  if Result <> nil then
  begin
    { A scope (or device, processor...) defined again keeps its
      children; anything else is replaced. }
    if (Kind = NodeScope) or ((Kind = NodeExternal) and (Result^.Kind <> NodeExternal)) then
      Exit;
    ClearNodeContents(Result);
    Result^.Kind := Kind;
    Exit;
  end;
  Result := PAmlNode(AmlHost.Allocate(SizeOf(TAmlNode)));
  if Result = nil then
    Exit;
  Result^.Name := Segment;
  Result^.Parent := Parent;
  Result^.Kind := Kind;
  if Parent <> nil then
  begin
    Result^.NextSibling := Parent^.FirstChild;
    Parent^.FirstChild := Result;
  end;
  Inc(NodeCount);
end;

function NamespaceRoot: PAmlNode;
begin
  Result := Root;
end;

function CountNodes: LongWord;
begin
  Result := NodeCount;
end;

function InitializeNamespace: Boolean;
var
  Node: PAmlNode;
begin
  NodeCount := 0;
  Root := CreateChild(nil, SegmentOf('\'), NodeScope);
  if Root = nil then
    Exit(False);
  CreateChild(Root, SegmentOf('_SB_'), NodeDevice);
  CreateChild(Root, SegmentOf('_GPE'), NodeScope);
  CreateChild(Root, SegmentOf('_PR_'), NodeScope);
  CreateChild(Root, SegmentOf('_TZ_'), NodeScope);
  CreateChild(Root, SegmentOf('_SI_'), NodeScope);
  Node := CreateChild(Root, SegmentOf('_OS_'), NodeName);
  if Node <> nil then
    Node^.Value := MakeStringFromText('Microsoft Windows NT');
  Node := CreateChild(Root, SegmentOf('_REV'), NodeName);
  if Node <> nil then
    Node^.Value := MakeInteger(2);
  Result := True;
end;

{ --- Name strings ---------------------------------------------------------------- }

function IsLeadCharacter(Character: Byte): Boolean;
begin
  Result := (Character = Ord('_')) or ((Character >= Ord('A')) and (Character <= Ord('Z')));
end;

function DecodeNameString(Data: PByte; Limit: LongWord; out Path: TAmlNamePath; out Length: LongWord): Boolean;
var
  Count: LongWord;
  Index: LongWord;
begin
  Result := False;
  ZeroMemory(@Path, SizeOf(Path));
  Length := 0;
  if Limit = 0 then
    Exit;
  if Data[0] = RootPrefix then
  begin
    Path.Absolute := True;
    Length := 1;
  end
  else
    while (Length < Limit) and (Data[Length] = ParentPrefix) do
    begin
      Inc(Path.ParentCount);
      Inc(Length);
    end;
  if Length >= Limit then
    Exit;
  case Data[Length] of
    NullName:
      begin
        Count := 0;
        Inc(Length);
      end;
    DualNamePrefix:
      begin
        Count := 2;
        Inc(Length);
      end;
    MultiNamePrefix:
      begin
        if Length + 1 >= Limit then
          Exit;
        Count := Data[Length + 1];
        Inc(Length, 2);
      end;
  else
    begin
      if not IsLeadCharacter(Data[Length]) then
        Exit;
      Count := 1;
    end;
  end;
  if (Count > MaximumNameSegments) or (Length + Count * 4 > Limit) then
    Exit;
  Path.SegmentCount := Count;
  for Index := 1 to Count do
  begin
    CopyMemory(@Path.Segments[Index - 1][0], Data + Length, 4);
    Inc(Length, 4);
  end;
  Result := True;
end;

function FollowAlias(Node: PAmlNode): PAmlNode;
var
  Hops: Integer;
begin
  Result := Node;
  Hops := 0;
  while (Result <> nil) and (Result^.Kind = NodeAlias) and (Hops < 8) do
  begin
    Result := Result^.Target;
    Inc(Hops);
  end;
end;

{ Where Path starts: the root, or Scope moved up its parent prefixes. }
function StartingScope(Scope: PAmlNode; const Path: TAmlNamePath): PAmlNode;
var
  Index: Integer;
begin
  if Path.Absolute or (Scope = nil) then
    Exit(Root);
  Result := Scope;
  for Index := 1 to Path.ParentCount do
    if (Result <> nil) and (Result^.Parent <> nil) then
      Result := Result^.Parent;
end;

function LookupPath(Scope: PAmlNode; const Path: TAmlNamePath): PAmlNode;
var
  Start: PAmlNode;
  Index: Integer;
begin
  Start := StartingScope(Scope, Path);
  if Path.SegmentCount = 0 then
    Exit(Start);
  if (Path.SegmentCount = 1) and not Path.Absolute and (Path.ParentCount = 0) then
  begin
    { The search rule: this scope, then each one above. }
    while Start <> nil do
    begin
      Result := FindChild(Start, Path.Segments[0]);
      if Result <> nil then
        Exit(FollowAlias(Result));
      Start := Start^.Parent;
    end;
    Exit(nil);
  end;
  Result := Start;
  for Index := 0 to Path.SegmentCount - 1 do
  begin
    Result := FollowAlias(FindChild(Result, Path.Segments[Index]));
    if Result = nil then
      Exit;
  end;
end;

function LookupNameString(Scope: PAmlNode; Data: PByte; Limit: LongWord): PAmlNode;
var
  Path: TAmlNamePath;
  Length: LongWord;
begin
  if not DecodeNameString(Data, Limit, Path, Length) then
    Exit(nil);
  Result := LookupPath(Scope, Path);
end;

function LookupText(Scope: PAmlNode; Text: PChar): PAmlNode;
var
  Path: TAmlNamePath;
  Position: Integer;
  Length: Integer;
begin
  ZeroMemory(@Path, SizeOf(Path));
  Position := 0;
  if Text[0] = '\' then
  begin
    Path.Absolute := True;
    Position := 1;
  end;
  while Text[Position] = '^' do
  begin
    Inc(Path.ParentCount);
    Inc(Position);
  end;
  while (Text[Position] <> #0) and (Path.SegmentCount < MaximumNameSegments) do
  begin
    Length := 0;
    while (Text[Position + Length] <> #0) and (Text[Position + Length] <> '.') do
      Inc(Length);
    if (Length = 0) or (Length > 4) then
      Exit(nil);
    Path.Segments[Path.SegmentCount] := SegmentOf(Text + Position);
    { SegmentOf reads up to four characters: cut at the dot. }
    while Length < 4 do
    begin
      Path.Segments[Path.SegmentCount][Length] := '_';
      Inc(Length);
    end;
    Inc(Path.SegmentCount);
    while (Text[Position] <> #0) and (Text[Position] <> '.') do
      Inc(Position);
    if Text[Position] = '.' then
      Inc(Position);
  end;
  Result := LookupPath(Scope, Path);
end;

function ScopeForNewName(Scope: PAmlNode; const Path: TAmlNamePath; out Segment: TAmlNameSegment): PAmlNode;
var
  Index: Integer;
begin
  Segment := SegmentOf('____');
  if Path.SegmentCount = 0 then
    Exit(nil);
  Result := StartingScope(Scope, Path);
  for Index := 0 to Path.SegmentCount - 2 do
  begin
    Result := FollowAlias(FindChild(Result, Path.Segments[Index]));
    if Result = nil then
      Exit;
  end;
  Segment := Path.Segments[Path.SegmentCount - 1];
end;

{ --- Walking -------------------------------------------------------------------- }

procedure VisitNodes(Parent: PAmlNode; Visit: TAmlNodeVisitor; Context: Pointer);
var
  Child: PAmlNode;
begin
  if Parent = nil then
    Exit;
  Child := Parent^.FirstChild;
  while Child <> nil do
  begin
    Visit(Child, Context);
    VisitNodes(Child, Visit, Context);
    Child := Child^.NextSibling;
  end;
end;

procedure NodePathText(Node: PAmlNode; Text: PChar; Capacity: Integer);
var
  Chain: array[0..31] of PAmlNode;
  Depth: Integer;
  Position: Integer;
  Index: Integer;
  Character: Integer;
begin
  Depth := 0;
  while (Node <> nil) and (Node <> Root) and (Depth < 32) do
  begin
    Chain[Depth] := Node;
    Inc(Depth);
    Node := Node^.Parent;
  end;
  Position := 0;
  if Capacity < 2 then
    Exit;
  Text[Position] := '\';
  Inc(Position);
  for Index := Depth - 1 downto 0 do
  begin
    if (Index < Depth - 1) and (Position < Capacity - 1) then
    begin
      Text[Position] := '.';
      Inc(Position);
    end;
    for Character := 0 to 3 do
      if Position < Capacity - 1 then
      begin
        Text[Position] := Chain[Index]^.Name[Character];
        Inc(Position);
      end;
  end;
  Text[Position] := #0;
end;

end.

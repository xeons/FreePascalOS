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
  The flattened device tree (the "DTB" a Raspberry Pi's firmware or QEMU
  hands a kernel it boots directly): reading the blob in place.

  The blob is a header, a memory reservation block (address and size
  pairs the kernel must not touch), a structure block and a strings
  block. The structure block is a stream of big endian 32-bit tokens:
  BEGIN_NODE (followed by the node's name), PROP (length, the offset of
  its name in the strings block, the value), END_NODE, NOP and END.

  A node is named by the offset of its BEGIN_NODE token in the structure
  block (NoNode for none), as libfdt does; nothing is allocated and
  nothing is copied. A node knows no parent, so ParentNode walks down
  from the root. Every value is read a byte at a time: the native boot
  stub reads the tree with the MMU off, where an unaligned access
  faults.

  Plain Pascal (no other unit): the native boot stub, the kernel and the
  host test (tools/DeviceTreeTest) all build it.
}
unit DeviceTree.Blob;

{$mode objfpc}
{$pointermath on}

interface

const
  DeviceTreeMagic = LongWord($D00DFEED);
  NoNode = -1;
  { The deepest nesting ParentNode follows. }
  MaximumDeviceTreeDepth = 32;
  DeviceTreeHeaderSize = 40;

type
  TDeviceTree = record
    Base: PByte;
    TotalSize: LongWord;
    StructureOffset: LongWord;
    StructureSize: LongWord;
    StringsOffset: LongWord;
    StringsSize: LongWord;
    ReservationOffset: LongWord;
  end;
  PDeviceTree = ^TDeviceTree;

  TDeviceTreeProperty = record
    Name: PChar;
    Value: PByte;
    Length: LongWord;
  end;

{ Big endian values, read a byte at a time. }
function ReadBigEndian32(Data: PByte): LongWord;
function ReadBigEndian64(Data: PByte): QWord;
{ CellCount cells at Data as one number (the low 64 bits of more). }
function ReadCells(Data: PByte; CellCount: LongWord): QWord;

{ The size the header at Base claims, or 0 if Base holds no tree. }
function DeviceTreeTotalSize(Base: Pointer): LongWord;
{ Checks the header at Base (magic, version 16 or later, blocks inside
  the blob). }
function OpenDeviceTree(Base: Pointer; out Tree: TDeviceTree): Boolean;

{ The entries of the memory reservation block (/memreserve/). }
function GetMemoryReservation(constref Tree: TDeviceTree; Index: LongWord;
  out Address, Size: QWord): Boolean;

{ --- Nodes --- }
function RootNode(constref Tree: TDeviceTree): LongInt;
{ "serial@7d001000" (the root's name is empty). }
function NodeName(constref Tree: TDeviceTree; Node: LongInt): PChar;
function FirstChildNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
function NextSiblingNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
function ParentNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
{ The node after Node in depth-first order (RootNode first), or NoNode
  at the end. Depth follows the nesting, relative to where the walk
  began (from the root: the root's children are at 1). }
function NextNode(constref Tree: TDeviceTree; Node: LongInt; var Depth: Integer): LongInt;
{ The child of Node called Name (NameLength characters):
  "memory@40000000", or "memory" for the first whose name before '@' is
  that. }
function FindChildNode(constref Tree: TDeviceTree; Node: LongInt; Name: PChar; NameLength: LongWord): LongInt;
{ A path ("/soc/serial@7d001000"), or an alias of /aliases ("serial0")
  with an optional path after it; anything from ':' on (the options of
  stdout-path) is ignored. }
function FindNodeByPath(constref Tree: TDeviceTree; Path: PChar): LongInt;
function NodePhandle(constref Tree: TDeviceTree; Node: LongInt): LongWord;
function FindNodeByPhandle(constref Tree: TDeviceTree; Phandle: LongWord): LongInt;

{ --- Properties --- }
function FindProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar;
  out Prop: TDeviceTreeProperty): Boolean;
function NodeHasProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar): Boolean;
{ Property Index of Node in the order they are written, for listing. }
function GetPropertyAt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Prop: TDeviceTreeProperty): Boolean;
{ A property of one cell (or the first cell of a longer one). }
function ReadCellProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar;
  out Value: LongWord): Boolean;
{ A text property's value, or nil. }
function ReadTextProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar): PChar;
{ Cell Index of a property's value (0 past its end). }
function PropertyCell(constref Prop: TDeviceTreeProperty; Index: LongWord): LongWord;
function PropertyCellCount(constref Prop: TDeviceTreeProperty): LongWord;
{ String Index of a string list ("compatible"), or nil. }
function PropertyString(constref Prop: TDeviceTreeProperty; Index: LongWord): PChar;

{ --- Matching --- }
{ One of the strings of Node's "compatible" is Compatible. }
function NodeIsCompatible(constref Tree: TDeviceTree; Node: LongInt; Compatible: PChar): Boolean;
{ The next node after StartAfter (NoNode: from the start) that is
  compatible with Compatible and enabled. }
function FindCompatibleNode(constref Tree: TDeviceTree; StartAfter: LongInt; Compatible: PChar): LongInt;
{ "status" is missing, "okay" or "ok". }
function NodeIsEnabled(constref Tree: TDeviceTree; Node: LongInt): Boolean;
{ "device_type" is Kind ("memory", "cpu", "pci"). }
function NodeHasDeviceType(constref Tree: TDeviceTree; Node: LongInt; Kind: PChar): Boolean;

{ Text helpers the tree's units share. }
function DeviceTreeTextIsEqual(First, Second: PChar): Boolean;
function DeviceTreeTextLength(Text: PChar): LongWord;

implementation

const
  TokenBeginNode = 1;
  TokenEndNode = 2;
  TokenProperty = 3;
  TokenNop = 4;
  TokenEnd = 9;

  HeaderMagic = 0;
  HeaderTotalSize = 4;
  HeaderStructureOffset = 8;
  HeaderStringsOffset = 12;
  HeaderReservationOffset = 16;
  HeaderVersion = 20;
  HeaderStringsSize = 32;
  HeaderStructureSize = 36;

  MinimumVersion = 16;
  ReservationEntrySize = 16;
  MaximumReservations = 256;

function ReadBigEndian32(Data: PByte): LongWord;
begin
  Result := (LongWord(Data[0]) shl 24) or (LongWord(Data[1]) shl 16) or
    (LongWord(Data[2]) shl 8) or LongWord(Data[3]);
end;

function ReadBigEndian64(Data: PByte): QWord;
begin
  Result := (QWord(ReadBigEndian32(Data)) shl 32) or ReadBigEndian32(Data + 4);
end;

function ReadCells(Data: PByte; CellCount: LongWord): QWord;
begin
  case CellCount of
    0: Result := 0;
    1: Result := ReadBigEndian32(Data);
  else
    Result := ReadBigEndian64(Data + (CellCount - 2) * 4);
  end;
end;

function DeviceTreeTextLength(Text: PChar): LongWord;
begin
  Result := 0;
  if Text = nil then
    Exit;
  while Text[Result] <> #0 do
    Inc(Result);
end;

function DeviceTreeTextIsEqual(First, Second: PChar): Boolean;
var
  Index: LongWord;
begin
  if (First = nil) or (Second = nil) then
    Exit(First = Second);
  Index := 0;
  while (First[Index] <> #0) and (First[Index] = Second[Index]) do
    Inc(Index);
  Result := First[Index] = Second[Index];
end;

function DeviceTreeTotalSize(Base: Pointer): LongWord;
begin
  Result := 0;
  if Base = nil then
    Exit;
  if ReadBigEndian32(PByte(Base) + HeaderMagic) <> DeviceTreeMagic then
    Exit;
  Result := ReadBigEndian32(PByte(Base) + HeaderTotalSize);
end;

function OpenDeviceTree(Base: Pointer; out Tree: TDeviceTree): Boolean;
var
  Bytes: PByte;
begin
  Result := False;
  Tree.Base := nil;
  Tree.TotalSize := 0;
  Tree.StructureOffset := 0;
  Tree.StructureSize := 0;
  Tree.StringsOffset := 0;
  Tree.StringsSize := 0;
  Tree.ReservationOffset := 0;
  if Base = nil then
    Exit;
  Bytes := PByte(Base);
  if ReadBigEndian32(Bytes + HeaderMagic) <> DeviceTreeMagic then
    Exit;
  if ReadBigEndian32(Bytes + HeaderVersion) < MinimumVersion then
    Exit;
  Tree.TotalSize := ReadBigEndian32(Bytes + HeaderTotalSize);
  Tree.StructureOffset := ReadBigEndian32(Bytes + HeaderStructureOffset);
  Tree.StructureSize := ReadBigEndian32(Bytes + HeaderStructureSize);
  Tree.StringsOffset := ReadBigEndian32(Bytes + HeaderStringsOffset);
  Tree.StringsSize := ReadBigEndian32(Bytes + HeaderStringsSize);
  Tree.ReservationOffset := ReadBigEndian32(Bytes + HeaderReservationOffset);
  if (Tree.TotalSize < DeviceTreeHeaderSize) or
     (QWord(Tree.StructureOffset) + Tree.StructureSize > Tree.TotalSize) or
     (QWord(Tree.StringsOffset) + Tree.StringsSize > Tree.TotalSize) or
     (Tree.ReservationOffset >= Tree.TotalSize) or ((Tree.StructureOffset and 3) <> 0) then
    Exit;
  Tree.Base := Bytes;
  Result := True;
end;

function GetMemoryReservation(constref Tree: TDeviceTree; Index: LongWord;
  out Address, Size: QWord): Boolean;
var
  Entry: LongWord;
  Position: LongWord;
begin
  Address := 0;
  Size := 0;
  Result := False;
  if Tree.Base = nil then
    Exit;
  { The block ends with an entry of zeros. }
  Entry := 0;
  while Entry <= Index do
  begin
    if Entry >= MaximumReservations then
      Exit;
    Position := Tree.ReservationOffset + Entry * ReservationEntrySize;
    if Position + ReservationEntrySize > Tree.TotalSize then
      Exit;
    Address := ReadBigEndian64(Tree.Base + Position);
    Size := ReadBigEndian64(Tree.Base + Position + 8);
    if (Address = 0) and (Size = 0) then
      Exit;
    Inc(Entry);
  end;
  Result := True;
end;

{ --- The token stream ---------------------------------------------------------- }

function TokenAt(constref Tree: TDeviceTree; Offset: LongInt): LongWord;
begin
  if (Offset < 0) or (QWord(Offset) + 4 > Tree.StructureSize) then
    Exit(TokenEnd);
  Result := ReadBigEndian32(Tree.Base + Tree.StructureOffset + LongWord(Offset));
end;

function StructureAt(constref Tree: TDeviceTree; Offset: LongInt): PByte;
begin
  Result := Tree.Base + Tree.StructureOffset + LongWord(Offset);
end;

function AlignToCell(Offset: LongWord): LongWord;
begin
  Result := (Offset + 3) and not LongWord(3);
end;

{ The offset after the token at Offset (a BEGIN_NODE's name, a
  property's value included), or -1 at the end or if the stream is
  damaged. }
function SkipToken(constref Tree: TDeviceTree; Offset: LongInt): LongInt;
var
  Position: LongWord;
  Length: LongWord;
begin
  Result := -1;
  case TokenAt(Tree, Offset) of
    TokenBeginNode:
      begin
        Position := LongWord(Offset) + 4;
        while (Position < Tree.StructureSize) and (StructureAt(Tree, Position)^ <> 0) do
          Inc(Position);
        if Position >= Tree.StructureSize then
          Exit;
        Result := LongInt(AlignToCell(Position + 1));
      end;
    TokenProperty:
      begin
        if QWord(Offset) + 12 > Tree.StructureSize then
          Exit;
        Length := ReadBigEndian32(StructureAt(Tree, Offset + 4));
        if QWord(Offset) + 12 + Length > Tree.StructureSize then
          Exit;
        Result := LongInt(AlignToCell(LongWord(Offset) + 12 + Length));
      end;
    TokenEndNode, TokenNop:
      Result := Offset + 4;
  end;
end;

{ The offset of the first token after Node's properties: its first
  child's BEGIN_NODE or its END_NODE. }
function SkipNodeHeader(constref Tree: TDeviceTree; Node: LongInt): LongInt;
var
  Token: LongWord;
begin
  Result := SkipToken(Tree, Node);
  while Result >= 0 do
  begin
    Token := TokenAt(Tree, Result);
    if (Token <> TokenProperty) and (Token <> TokenNop) then
      Exit;
    Result := SkipToken(Tree, Result);
  end;
end;

{ The offset after Node's END_NODE. }
function SkipSubtree(constref Tree: TDeviceTree; Node: LongInt): LongInt;
var
  Depth: Integer;
begin
  Depth := 0;
  Result := Node;
  repeat
    case TokenAt(Tree, Result) of
      TokenBeginNode: Inc(Depth);
      TokenEndNode: Dec(Depth);
      TokenProperty, TokenNop: ;
    else
      Exit(-1);
    end;
    Result := SkipToken(Tree, Result);
    if Result < 0 then
      Exit;
  until Depth = 0;
end;

function SkipNops(constref Tree: TDeviceTree; Offset: LongInt): LongInt;
begin
  Result := Offset;
  while (Result >= 0) and (TokenAt(Tree, Result) = TokenNop) do
    Result := SkipToken(Tree, Result);
end;

{ --- Nodes ------------------------------------------------------------------------- }

function RootNode(constref Tree: TDeviceTree): LongInt;
begin
  if Tree.Base = nil then
    Exit(NoNode);
  Result := SkipNops(Tree, 0);
  if (Result < 0) or (TokenAt(Tree, Result) <> TokenBeginNode) then
    Result := NoNode;
end;

function NodeName(constref Tree: TDeviceTree; Node: LongInt): PChar;
begin
  if Node < 0 then
    Exit(nil);
  Result := PChar(StructureAt(Tree, Node + 4));
end;

function FirstChildNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
begin
  if Node < 0 then
    Exit(NoNode);
  Result := SkipNodeHeader(Tree, Node);
  if (Result < 0) or (TokenAt(Tree, Result) <> TokenBeginNode) then
    Result := NoNode;
end;

function NextSiblingNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
begin
  if Node < 0 then
    Exit(NoNode);
  Result := SkipNops(Tree, SkipSubtree(Tree, Node));
  if (Result < 0) or (TokenAt(Tree, Result) <> TokenBeginNode) then
    Result := NoNode;
end;

function NextNode(constref Tree: TDeviceTree; Node: LongInt; var Depth: Integer): LongInt;
var
  Offset: LongInt;
begin
  if Node < 0 then
    Exit(NoNode);
  Offset := SkipToken(Tree, Node);
  Inc(Depth);
  while Offset >= 0 do
  begin
    case TokenAt(Tree, Offset) of
      TokenBeginNode:
        Exit(Offset);
      TokenEndNode:
        Dec(Depth);
      TokenProperty, TokenNop: ;
    else
      Break;
    end;
    Offset := SkipToken(Tree, Offset);
  end;
  Result := NoNode;
end;

function ParentNode(constref Tree: TDeviceTree; Node: LongInt): LongInt;
var
  Path: array[0..MaximumDeviceTreeDepth] of LongInt;
  Current: LongInt;
  Depth: Integer;
begin
  Result := NoNode;
  Current := RootNode(Tree);
  if (Current = NoNode) or (Node = Current) then
    Exit;
  Depth := 0;
  while Current <> NoNode do
  begin
    if (Depth < 0) or (Depth > MaximumDeviceTreeDepth) then
      Exit;
    Path[Depth] := Current;
    if Current = Node then
    begin
      if Depth > 0 then
        Result := Path[Depth - 1];
      Exit;
    end;
    Current := NextNode(Tree, Current, Depth);
  end;
end;

{ Name matches Wanted (WantedLength characters): exactly, or the part
  before '@' if Wanted has no '@'. }
function NodeNameMatches(Name: PChar; Wanted: PChar; WantedLength: LongWord): Boolean;
var
  Index: LongWord;
  WantedHasUnitAddress: Boolean;
begin
  WantedHasUnitAddress := False;
  Index := 0;
  while Index < WantedLength do
  begin
    if Wanted[Index] = '@' then
      WantedHasUnitAddress := True;
    if Name[Index] <> Wanted[Index] then
      Exit(False);
    Inc(Index);
  end;
  Result := (Name[Index] = #0) or ((Name[Index] = '@') and not WantedHasUnitAddress);
end;

function FindChildNode(constref Tree: TDeviceTree; Node: LongInt; Name: PChar; NameLength: LongWord): LongInt;
begin
  Result := FirstChildNode(Tree, Node);
  while Result <> NoNode do
  begin
    if NodeNameMatches(NodeName(Tree, Result), Name, NameLength) then
      Exit;
    Result := NextSiblingNode(Tree, Result);
  end;
end;

function PathComponentEnd(Path: PChar; Start: LongWord): LongWord;
begin
  Result := Start;
  while (Path[Result] <> #0) and (Path[Result] <> '/') and (Path[Result] <> ':') do
    Inc(Result);
end;

{ Follows the components of Path from Position on, starting at Node. }
function FollowPath(constref Tree: TDeviceTree; Node: LongInt; Path: PChar; Position: LongWord): LongInt;
var
  ComponentEnd: LongWord;
begin
  Result := Node;
  while (Result <> NoNode) and (Path[Position] <> #0) and (Path[Position] <> ':') do
  begin
    if Path[Position] = '/' then
    begin
      Inc(Position);
      Continue;
    end;
    ComponentEnd := PathComponentEnd(Path, Position);
    Result := FindChildNode(Tree, Result, Path + Position, ComponentEnd - Position);
    Position := ComponentEnd;
  end;
end;

function FindAliasNode(constref Tree: TDeviceTree; Alias: PChar; AliasLength: LongWord): LongInt;
var
  Aliases: LongInt;
  Index: LongWord;
  Prop: TDeviceTreeProperty;
begin
  Result := NoNode;
  Aliases := FindChildNode(Tree, RootNode(Tree), 'aliases', 7);
  if Aliases = NoNode then
    Exit;
  Index := 0;
  while GetPropertyAt(Tree, Aliases, Index, Prop) do
  begin
    if (DeviceTreeTextLength(Prop.Name) = AliasLength) and NodeNameMatches(Prop.Name, Alias, AliasLength) and
       (Prop.Length > 1) and (PChar(Prop.Value)[0] = '/') then
      Exit(FollowPath(Tree, RootNode(Tree), PChar(Prop.Value), 0));
    Inc(Index);
  end;
end;

function FindNodeByPath(constref Tree: TDeviceTree; Path: PChar): LongInt;
var
  AliasEnd: LongWord;
begin
  Result := NoNode;
  if (Path = nil) or (Path[0] = #0) or (Tree.Base = nil) then
    Exit;
  if Path[0] = '/' then
    Exit(FollowPath(Tree, RootNode(Tree), Path, 0));
  AliasEnd := PathComponentEnd(Path, 0);
  Result := FindAliasNode(Tree, Path, AliasEnd);
  if Result <> NoNode then
    Result := FollowPath(Tree, Result, Path, AliasEnd);
end;

function NodePhandle(constref Tree: TDeviceTree; Node: LongInt): LongWord;
begin
  if not ReadCellProperty(Tree, Node, 'phandle', Result) then
    if not ReadCellProperty(Tree, Node, 'linux,phandle', Result) then
      Result := 0;
end;

function FindNodeByPhandle(constref Tree: TDeviceTree; Phandle: LongWord): LongInt;
var
  Depth: Integer;
begin
  Result := NoNode;
  if (Phandle = 0) or (Phandle = $FFFFFFFF) then
    Exit;
  Depth := 0;
  Result := RootNode(Tree);
  while Result <> NoNode do
  begin
    if NodePhandle(Tree, Result) = Phandle then
      Exit;
    Result := NextNode(Tree, Result, Depth);
  end;
end;

{ --- Properties ------------------------------------------------------------- }

procedure ClearProperty(out Prop: TDeviceTreeProperty);
begin
  Prop.Name := nil;
  Prop.Value := nil;
  Prop.Length := 0;
end;

function ReadPropertyAt(constref Tree: TDeviceTree; Offset: LongInt; out Prop: TDeviceTreeProperty): Boolean;
var
  NameOffset: LongWord;
begin
  Prop.Length := ReadBigEndian32(StructureAt(Tree, Offset + 4));
  NameOffset := ReadBigEndian32(StructureAt(Tree, Offset + 8));
  Prop.Value := StructureAt(Tree, Offset + 12);
  if NameOffset >= Tree.StringsSize then
  begin
    Prop.Name := nil;
    Exit(False);
  end;
  Prop.Name := PChar(Tree.Base + Tree.StringsOffset + NameOffset);
  Result := True;
end;

function GetPropertyAt(constref Tree: TDeviceTree; Node: LongInt; Index: LongWord;
  out Prop: TDeviceTreeProperty): Boolean;
var
  Offset: LongInt;
  Token: LongWord;
  Seen: LongWord;
begin
  ClearProperty(Prop);
  Result := False;
  if Node < 0 then
    Exit;
  Seen := 0;
  Offset := SkipToken(Tree, Node);
  while Offset >= 0 do
  begin
    Token := TokenAt(Tree, Offset);
    if Token = TokenProperty then
    begin
      if Seen = Index then
        Exit(ReadPropertyAt(Tree, Offset, Prop));
      Inc(Seen);
    end
    else if Token <> TokenNop then
      Exit;
    Offset := SkipToken(Tree, Offset);
  end;
end;

function FindProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar;
  out Prop: TDeviceTreeProperty): Boolean;
var
  Offset: LongInt;
  Token: LongWord;
begin
  ClearProperty(Prop);
  Result := False;
  if Node < 0 then
    Exit;
  Offset := SkipToken(Tree, Node);
  while Offset >= 0 do
  begin
    Token := TokenAt(Tree, Offset);
    if Token = TokenProperty then
    begin
      if ReadPropertyAt(Tree, Offset, Prop) and DeviceTreeTextIsEqual(Prop.Name, Name) then
        Exit(True);
    end
    else if Token <> TokenNop then
      Break;
    Offset := SkipToken(Tree, Offset);
  end;
  ClearProperty(Prop);
end;

function NodeHasProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar): Boolean;
var
  Prop: TDeviceTreeProperty;
begin
  Result := FindProperty(Tree, Node, Name, Prop);
end;

function ReadCellProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar;
  out Value: LongWord): Boolean;
var
  Prop: TDeviceTreeProperty;
begin
  Value := 0;
  Result := FindProperty(Tree, Node, Name, Prop) and (Prop.Length >= 4);
  if Result then
    Value := ReadBigEndian32(Prop.Value);
end;

function ReadTextProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar): PChar;
var
  Prop: TDeviceTreeProperty;
begin
  Result := nil;
  if FindProperty(Tree, Node, Name, Prop) and (Prop.Length > 0) and (Prop.Value[Prop.Length - 1] = 0) then
    Result := PChar(Prop.Value);
end;

function PropertyCellCount(constref Prop: TDeviceTreeProperty): LongWord;
begin
  Result := Prop.Length div 4;
end;

function PropertyCell(constref Prop: TDeviceTreeProperty; Index: LongWord): LongWord;
begin
  if Index >= PropertyCellCount(Prop) then
    Exit(0);
  Result := ReadBigEndian32(Prop.Value + Index * 4);
end;

function PropertyString(constref Prop: TDeviceTreeProperty; Index: LongWord): PChar;
var
  Position: LongWord;
  Current: LongWord;
begin
  Result := nil;
  if (Prop.Value = nil) or (Prop.Length = 0) or (Prop.Value[Prop.Length - 1] <> 0) then
    Exit;
  Position := 0;
  Current := 0;
  while Position < Prop.Length do
  begin
    if Current = Index then
      Exit(PChar(Prop.Value + Position));
    while (Position < Prop.Length) and (Prop.Value[Position] <> 0) do
      Inc(Position);
    Inc(Position);
    Inc(Current);
  end;
end;

{ --- Matching -------------------------------------------------------------------- }

function NodeIsCompatible(constref Tree: TDeviceTree; Node: LongInt; Compatible: PChar): Boolean;
var
  Prop: TDeviceTreeProperty;
  Index: LongWord;
  Item: PChar;
begin
  Result := False;
  if not FindProperty(Tree, Node, 'compatible', Prop) then
    Exit;
  Index := 0;
  repeat
    Item := PropertyString(Prop, Index);
    if (Item <> nil) and DeviceTreeTextIsEqual(Item, Compatible) then
      Exit(True);
    Inc(Index);
  until Item = nil;
end;

function NodeIsEnabled(constref Tree: TDeviceTree; Node: LongInt): Boolean;
var
  Status: PChar;
begin
  Status := ReadTextProperty(Tree, Node, 'status');
  Result := (Status = nil) or DeviceTreeTextIsEqual(Status, 'okay') or DeviceTreeTextIsEqual(Status, 'ok');
end;

function NodeHasDeviceType(constref Tree: TDeviceTree; Node: LongInt; Kind: PChar): Boolean;
begin
  Result := DeviceTreeTextIsEqual(ReadTextProperty(Tree, Node, 'device_type'), Kind);
end;

function FindCompatibleNode(constref Tree: TDeviceTree; StartAfter: LongInt; Compatible: PChar): LongInt;
var
  Depth: Integer;
begin
  Depth := 0;
  if StartAfter = NoNode then
    Result := RootNode(Tree)
  else
    Result := NextNode(Tree, StartAfter, Depth);
  while Result <> NoNode do
  begin
    if NodeIsCompatible(Tree, Result, Compatible) and NodeIsEnabled(Tree, Result) then
      Exit;
    Result := NextNode(Tree, Result, Depth);
  end;
end;

end.

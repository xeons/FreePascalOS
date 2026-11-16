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
  Decoding a JPEG XL modular sub-bitstream (ISO/IEC 18181-1 annex H):
  a group header (whether the frame's global tree is used, the weighted
  predictor's parameters, the transforms), then, unless the global tree
  is used, a tree and its entropy code, then the channels one after the
  other, each sample predicted and its residual decoded in the context
  of the tree leaf its properties lead to.

  Channels larger than MaximumChannelSize (the group size, in the
  frame's global stream) stop the decoding there: they and those after
  them are decoded group by group later.
}
unit Image.Jxl.Modular.Decoding;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy,
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Tree,
  Image.Jxl.Modular.Weighted,
  Image.Jxl.Modular.Transforms;

type
  { What a stream's header said, kept to undo its transforms later. }
  TJxlModularStreamState = record
    WeightedHeader: TJxlWeightedHeader;
    Transforms: TJxlTransformList;
  end;

{ Decodes a modular stream into Image (its channels already at their
  sizes before transforms). GlobalTree may be nil. With UndoTransforms
  the transforms are undone at the end; otherwise State keeps them for
  JxlUndoModularTransforms. }
procedure DecodeJxlModularStream(Reader: TJxlBitReader; Image: TJxlModularImage; StreamId: LongInt;
  MaximumChannelSize: Int64; GlobalTree: TJxlModularTreeCode; UndoTransforms: Boolean;
  out State: TJxlModularStreamState);
procedure JxlUndoModularTransforms(Image: TJxlModularImage; const State: TJxlModularStreamState);
{ True when channel Index of Image is decoded by a stream whose
  channels may be at most MaximumChannelSize a side. }
function JxlChannelDecodedHere(Image: TJxlModularImage; Index: LongInt; MaximumChannelSize: Int64): Boolean;

implementation

uses
  Image.Jxl.Modular.Predictors;

const
  MaximumProperties = 256 + JxlNonReferenceProperties;

type
  TPropertyArray = array[0..MaximumProperties - 1] of Int64;

  { The tree with its leaves' contexts already clustered. }
  TDecodingTree = record
    Nodes: TJxlTreeNodes;
    Clusters: array of LongInt;
    PropertyCount: LongInt;
    UsesWeighted: Boolean;
    ReferenceChannels: LongInt;
  end;

procedure RaiseBadModular(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL modular: ' + Detail);
end;

function JxlChannelDecodedHere(Image: TJxlModularImage; Index: LongInt; MaximumChannelSize: Int64): Boolean;
var
  Channel: LongInt;
begin
  for Channel := Image.MetaChannelCount to Index do
    if (Image[Channel].Width > MaximumChannelSize) or (Image[Channel].Height > MaximumChannelSize) then
      Exit(False);
  Result := True;
end;

procedure PrepareTree(const Nodes: TJxlTreeNodes; Code: TJxlEntropyCode; out Tree: TDecodingTree);
var
  Index: LongInt;
  Highest: LongInt;
begin
  Tree.Nodes := Nodes;
  SetLength(Tree.Clusters, Length(Nodes));
  Highest := -1;
  Tree.UsesWeighted := False;
  for Index := 0 to High(Nodes) do
    if Nodes[Index].PropertyIndex < 0 then
    begin
      if Nodes[Index].Context >= Code.ContextCount then
        RaiseBadModular('tree leaf without a context');
      Tree.Clusters[Index] := Code.Cluster[Nodes[Index].Context];
      if Nodes[Index].Predictor = JxlPredictorWeighted then
        Tree.UsesWeighted := True;
    end
    else
    begin
      if Nodes[Index].PropertyIndex > Highest then
        Highest := Nodes[Index].PropertyIndex;
      if Nodes[Index].PropertyIndex = JxlWeightedPredictorProperty then
        Tree.UsesWeighted := True;
    end;
  Tree.PropertyCount := Highest + 1;
  if Tree.PropertyCount > JxlNonReferenceProperties then
    Tree.ReferenceChannels := (Tree.PropertyCount - JxlNonReferenceProperties + JxlPropertiesPerReference - 1)
      div JxlPropertiesPerReference
  else
    Tree.ReferenceChannels := 0;
end;

{ The properties from earlier channels of the same size and shifts,
  for every sample of line Y (four per channel, as many channels as the
  tree looks at). References[X * Stride + k]. }
procedure ComputeReferenceProperties(Image: TJxlModularImage; ChannelIndex, Y, Count: LongInt;
  var References: array of Int64);
var
  Channel: TJxlChannel;
  Other: TJxlChannel;
  Previous: LongInt;
  Offset: LongInt;
  Stride: LongInt;
  X: LongInt;
  Line: PLongInt;
  Above: PLongInt;
  Value: Int64;
  Left: Int64;
  Top: Int64;
  TopLeft: Int64;
  Predicted: Int64;
  Position: PtrInt;
begin
  Channel := Image[ChannelIndex];
  Stride := Count * JxlPropertiesPerReference;
  FillChar(References[0], SizeOf(Int64) * Length(References), 0);
  Offset := 0;
  Previous := ChannelIndex - 1;
  while (Previous >= 0) and (Offset < Stride) do
  begin
    Other := Image[Previous];
    Dec(Previous);
    if (Other.Width <> Channel.Width) or (Other.Height <> Channel.Height) or
      (Other.HorizontalShift <> Channel.HorizontalShift) or (Other.VerticalShift <> Channel.VerticalShift) then
      Continue;
    Line := Other.Row(Y);
    if Y > 0 then
      Above := Other.Row(Y - 1)
    else
      Above := Line;
    for X := 0 to Channel.Width - 1 do
    begin
      Value := Line[X];
      if X > 0 then
        Left := Line[X - 1]
      else
        Left := 0;
      if Y > 0 then
        Top := Above[X]
      else
        Top := Left;
      if (X > 0) and (Y > 0) then
        TopLeft := Above[X - 1]
      else
        TopLeft := Left;
      Predicted := JxlClampedGradient(Left, Top, TopLeft);
      Position := PtrInt(X) * Stride + Offset;
      References[Position] := Abs(Value);
      References[Position + 1] := Value;
      References[Position + 2] := Abs(Value - Predicted);
      References[Position + 3] := Value - Predicted;
    end;
    Inc(Offset, JxlPropertiesPerReference);
  end;
end;

procedure DecodeChannel(SymbolReader: TJxlSymbolReader; const Tree: TDecodingTree;
  const WeightedHeader: TJxlWeightedHeader; Image: TJxlModularImage; ChannelIndex, StreamId: LongInt);
var
  Channel: TJxlChannel;
  Width: LongInt;
  X: LongInt;
  Y: LongInt;
  Line: PLongInt;
  Neighbours: TJxlNeighbours;
  Properties: TPropertyArray;
  References: array of Int64;
  ReferenceStride: LongInt;
  Weighted: TJxlWeightedPredictor;
  WeightedPrediction: Int64;
  MaximumError: Int64;
  NodeIndex: LongInt;
  Node: ^TJxlTreeNode;
  Value: LongWord;
  Residual: Int64;
  PreviousGradient: Int64;
  Index: LongInt;
  SingleLeaf: Boolean;
  NeedProperties: Boolean;
begin
  Channel := Image[ChannelIndex];
  Width := Channel.Width;
  if (Width = 0) or (Channel.Height = 0) then
    Exit;
  Weighted := nil;
  if Tree.UsesWeighted then
    Weighted := TJxlWeightedPredictor.Create(WeightedHeader, Width);
  try
    ReferenceStride := Tree.ReferenceChannels * JxlPropertiesPerReference;
    if ReferenceStride > 0 then
      SetLength(References, PtrInt(Width) * ReferenceStride);
    SingleLeaf := Length(Tree.Nodes) = 1;
    NeedProperties := not SingleLeaf;
    FillChar(Properties, SizeOf(Int64) * (JxlNonReferenceProperties + ReferenceStride), 0);
    Properties[0] := ChannelIndex;
    Properties[1] := StreamId;
    for Y := 0 to Channel.Height - 1 do
    begin
      Line := Channel.Row(Y);
      if NeedProperties and (ReferenceStride > 0) then
        ComputeReferenceProperties(Image, ChannelIndex, Y, Tree.ReferenceChannels, References);
      Properties[2] := Y;
      PreviousGradient := 0;
      for X := 0 to Width - 1 do
      begin
        GetJxlNeighbours(Line, Width, X, Y, Neighbours);
        if NeedProperties then
        begin
          Properties[3] := X;
          Properties[4] := Abs(Neighbours.North);
          Properties[5] := Abs(Neighbours.West);
          Properties[6] := Neighbours.North;
          Properties[7] := Neighbours.West;
          Properties[8] := Neighbours.West - PreviousGradient;
          PreviousGradient := Neighbours.West + Neighbours.North - Neighbours.NorthWest;
          Properties[9] := PreviousGradient;
          Properties[10] := Neighbours.West - Neighbours.NorthWest;
          Properties[11] := Neighbours.NorthWest - Neighbours.North;
          Properties[12] := Neighbours.North - Neighbours.NorthEast;
          Properties[13] := Neighbours.North - Neighbours.NorthNorth;
          Properties[14] := Neighbours.West - Neighbours.WestWest;
        end;
        WeightedPrediction := 0;
        if Weighted <> nil then
        begin
          WeightedPrediction := Weighted.Predict(X, Y, Neighbours.North, Neighbours.West, Neighbours.NorthEast,
            Neighbours.NorthWest, Neighbours.NorthNorth, MaximumError);
          Properties[JxlWeightedPredictorProperty] := MaximumError;
        end;
        if NeedProperties and (ReferenceStride > 0) then
          for Index := 0 to ReferenceStride - 1 do
            Properties[JxlNonReferenceProperties + Index] := References[PtrInt(X) * ReferenceStride + Index];
        NodeIndex := 0;
        Node := @Tree.Nodes[0];
        while Node^.PropertyIndex >= 0 do
        begin
          if Properties[Node^.PropertyIndex] > Node^.SplitValue then
            NodeIndex := Node^.LeftChild
          else
            NodeIndex := Node^.RightChild;
          Node := @Tree.Nodes[NodeIndex];
        end;
        Value := SymbolReader.ReadUintClustered(Tree.Clusters[NodeIndex]);
        Residual := Int64(JxlUnpackSigned(Value)) * Node^.Multiplier + Node^.Offset
          + JxlPredict(Node^.Predictor, Neighbours, WeightedPrediction);
        Line[X] := LongInt(Residual and $FFFFFFFF);
        if Weighted <> nil then
          Weighted.Update(Line[X], X, Y);
      end;
    end;
  finally
    Weighted.Free;
  end;
end;

procedure ReadGroupHeader(Reader: TJxlBitReader; out UseGlobalTree: Boolean; out State: TJxlModularStreamState);
var
  Count: LongWord;
  Index: LongWord;
begin
  UseGlobalTree := Reader.ReadBool;
  State.WeightedHeader := ReadJxlWeightedHeader(Reader);
  Count := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlBitsOffset(4, 2), JxlBitsOffset(8, 18));
  SetLength(State.Transforms, Count);
  for Index := 1 to Count do
    State.Transforms[Index - 1] := ReadJxlTransform(Reader);
end;

procedure JxlUndoModularTransforms(Image: TJxlModularImage; const State: TJxlModularStreamState);
var
  Index: LongInt;
begin
  for Index := High(State.Transforms) downto 0 do
    InvertJxlTransform(Image, State.Transforms[Index], State.WeightedHeader);
end;

procedure DecodeJxlModularStream(Reader: TJxlBitReader; Image: TJxlModularImage; StreamId: LongInt;
  MaximumChannelSize: Int64; GlobalTree: TJxlModularTreeCode; UndoTransforms: Boolean;
  out State: TJxlModularStreamState);
var
  UseGlobalTree: Boolean;
  Index: LongInt;
  Channel: TJxlChannel;
  DecodedCount: LongInt;
  DistanceMultiplier: LongWord;
  TreeSizeLimit: Int64;
  OwnTree: TJxlModularTreeCode;
  TreeCode: TJxlModularTreeCode;
  Tree: TDecodingTree;
  SymbolReader: TJxlSymbolReader;
  ChannelCount: LongInt;
begin
  State.Transforms := nil;
  State.WeightedHeader := DefaultJxlWeightedHeader;
  if Image.ChannelCount = 0 then
    Exit;
  ReadGroupHeader(Reader, UseGlobalTree, State);
  for Index := 0 to High(State.Transforms) do
    ApplyJxlTransformToChannels(Image, State.Transforms[Index]);
  ChannelCount := Image.ChannelCount;
  DecodedCount := 0;
  DistanceMultiplier := 0;
  TreeSizeLimit := 1024;
  for Index := 0 to ChannelCount - 1 do
  begin
    Channel := Image[Index];
    if (Index >= Image.MetaChannelCount) and
      ((Channel.Width > MaximumChannelSize) or (Channel.Height > MaximumChannelSize)) then
      Break;
    Inc(TreeSizeLimit, Int64(Channel.Width) * Channel.Height);
    if (Channel.Width = 0) or (Channel.Height = 0) then
      Continue;
    if LongWord(Channel.Width) > DistanceMultiplier then
      DistanceMultiplier := Channel.Width;
    Inc(DecodedCount);
  end;
  if DecodedCount > 0 then
  begin
    if TreeSizeLimit > 1 shl 20 then
      TreeSizeLimit := 1 shl 20;
    OwnTree := nil;
    try
      if UseGlobalTree then
      begin
        if (GlobalTree = nil) or (Length(GlobalTree.Nodes) = 0) then
          RaiseBadModular('global tree used but not given');
        TreeCode := GlobalTree;
      end
      else
      begin
        OwnTree := ReadJxlModularTreeCode(Reader, TreeSizeLimit);
        TreeCode := OwnTree;
      end;
      PrepareTree(TreeCode.Nodes, TreeCode.Code, Tree);
      SymbolReader := TJxlSymbolReader.Create(TreeCode.Code, Reader, DistanceMultiplier);
      try
        for Index := 0 to ChannelCount - 1 do
        begin
          Channel := Image[Index];
          if (Index >= Image.MetaChannelCount) and
            ((Channel.Width > MaximumChannelSize) or (Channel.Height > MaximumChannelSize)) then
            Break;
          DecodeChannel(SymbolReader, Tree, State.WeightedHeader, Image, Index, StreamId);
        end;
        SymbolReader.CheckFinalState;
      finally
        SymbolReader.Free;
      end;
    finally
      OwnTree.Free;
    end;
  end;
  if UndoTransforms then
  begin
    JxlUndoModularTransforms(Image, State);
    State.Transforms := nil;
  end;
end;

end.

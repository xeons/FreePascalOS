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
  JPEG XL's meta-adaptive (MA) trees (ISO/IEC 18181-1 annex H.4).

  A decision node compares one property of the sample being decoded
  (its position, its neighbours, gradients, the weighted predictor's
  error, the same position in earlier channels...) with a split value
  and goes left when the property is greater. A leaf says which
  predictor to use, an offset and a multiplier for the residual, and
  is the context the residual is entropy coded in (leaves are numbered
  in the order they are read).

  The tree is itself entropy coded, in six contexts, breadth first.
  TJxlModularTreeCode is a tree with the entropy code of the residuals
  its leaves select: the global one of a frame, or a group's own.
}
unit Image.Jxl.Modular.Tree;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy;

const
  JxlPredictorZero = 0;
  JxlPredictorLeft = 1;
  JxlPredictorTop = 2;
  JxlPredictorAverage0 = 3;
  JxlPredictorSelect = 4;
  JxlPredictorGradient = 5;
  JxlPredictorWeighted = 6;
  JxlPredictorTopRight = 7;
  JxlPredictorTopLeft = 8;
  JxlPredictorLeftLeft = 9;
  JxlPredictorAverage1 = 10;
  JxlPredictorAverage2 = 11;
  JxlPredictorAverage3 = 12;
  JxlPredictorAverage4 = 13;
  JxlPredictorCount = 14;

  { Properties: 0 channel, 1 stream, 2 y, 3 x, 4 |N|, 5 |W|, 6 N, 7 W,
    8 W minus the gradient at W, 9 gradient (W + N - NW), 10 W - NW,
    11 NW - N, 12 N - NE, 13 N - NN, 14 W - WW, 15 the weighted
    predictor's largest error; then four per earlier channel of the
    same size. }
  JxlNonReferenceProperties = 16;
  JxlPropertiesPerReference = 4;
  JxlWeightedPredictorProperty = 15;

type
  TJxlTreeNode = record
    { The property tested, or -1 for a leaf. }
    PropertyIndex: LongInt;
    SplitValue: LongInt;
    LeftChild: LongInt;
    RightChild: LongInt;
    { Leaves only. }
    Predictor: LongInt;
    Offset: Int64;
    Multiplier: LongInt;
    Context: LongInt;
  end;

  TJxlTreeNodes = array of TJxlTreeNode;

  TJxlModularTreeCode = class
  public
    Nodes: TJxlTreeNodes;
    Code: TJxlEntropyCode;
    destructor Destroy; override;
  end;

{ Reads a tree of at most SizeLimit nodes. }
function ReadJxlModularTree(Reader: TJxlBitReader; SizeLimit: Int64): TJxlTreeNodes;
{ Reads a tree and the entropy code of its leaves' residuals. }
function ReadJxlModularTreeCode(Reader: TJxlBitReader; SizeLimit: Int64): TJxlModularTreeCode;

implementation

const
  SplitValueContext = 0;
  PropertyContext = 1;
  PredictorContext = 2;
  OffsetContext = 3;
  MultiplierLogContext = 4;
  MultiplierBitsContext = 5;
  TreeContextCount = 6;

procedure RaiseBadTree(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL tree: ' + Detail);
end;

destructor TJxlModularTreeCode.Destroy;
begin
  Code.Free;
  inherited Destroy;
end;

function ReadJxlModularTree(Reader: TJxlBitReader; SizeLimit: Int64): TJxlTreeNodes;
var
  Code: TJxlEntropyCode;
  SymbolReader: TJxlSymbolReader;
  Count: LongInt;
  ToDecode: LongInt;
  LeafCount: LongInt;
  PropertyValue: LongWord;
  Node: TJxlTreeNode;
  MultiplierLog: LongWord;
  MultiplierBits: LongWord;
begin
  Result := nil;
  Code := ReadJxlEntropyCode(Reader, TreeContextCount);
  try
    SymbolReader := TJxlSymbolReader.Create(Code, Reader);
    try
      Count := 0;
      ToDecode := 1;
      LeafCount := 0;
      while ToDecode > 0 do
      begin
        if Count > SizeLimit then
          RaiseBadTree('too large');
        Dec(ToDecode);
        PropertyValue := SymbolReader.ReadUint(PropertyContext);
        if PropertyValue > 256 then
          RaiseBadTree('bad property');
        Node := Default(TJxlTreeNode);
        Node.PropertyIndex := LongInt(PropertyValue) - 1;
        if Node.PropertyIndex = -1 then
        begin
          Node.Predictor := LongInt(SymbolReader.ReadUint(PredictorContext));
          if Node.Predictor >= JxlPredictorCount then
            RaiseBadTree('bad predictor');
          Node.Offset := JxlUnpackSigned64(SymbolReader.ReadUint(OffsetContext));
          MultiplierLog := SymbolReader.ReadUint(MultiplierLogContext);
          if MultiplierLog >= 31 then
            RaiseBadTree('bad multiplier');
          MultiplierBits := SymbolReader.ReadUint(MultiplierBitsContext);
          if QWord(MultiplierBits) >= (QWord(1) shl (31 - MultiplierLog)) - 1 then
            RaiseBadTree('bad multiplier');
          Node.Multiplier := LongInt((MultiplierBits + 1) shl MultiplierLog);
          Node.Context := LeafCount;
          Inc(LeafCount);
        end
        else
        begin
          Node.SplitValue := JxlUnpackSigned(SymbolReader.ReadUint(SplitValueContext));
          Node.LeftChild := Count + ToDecode + 1;
          Node.RightChild := Count + ToDecode + 2;
          Inc(ToDecode, 2);
        end;
        if Count >= Length(Result) then
          SetLength(Result, Count * 2 + 16);
        Result[Count] := Node;
        Inc(Count);
      end;
      SymbolReader.CheckFinalState;
    finally
      SymbolReader.Free;
    end;
  finally
    Code.Free;
  end;
  SetLength(Result, Count);
end;

function ReadJxlModularTreeCode(Reader: TJxlBitReader; SizeLimit: Int64): TJxlModularTreeCode;
begin
  Result := TJxlModularTreeCode.Create;
  try
    Result.Nodes := ReadJxlModularTree(Reader, SizeLimit);
    Result.Code := ReadJxlEntropyCode(Reader, (Length(Result.Nodes) + 1) div 2);
  except
    Result.Free;
    raise;
  end;
end;

end.

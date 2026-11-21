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
  Web.Dom: CharacterData (Text, CDATASection, Comment,
  ProcessingInstruction) with UTF-16 offsets over UTF-8 data, and
  DocumentType.
}

function TCharacterData.IsAscii: Boolean;
begin
  if (FFlags and NodeFlagAsciiKnown) = 0 then
  begin
    FFlags := FFlags or NodeFlagAsciiKnown;
    if IsAsciiText(FData) then
      FFlags := FFlags or NodeFlagAscii
    else
      FFlags := FFlags and not NodeFlagAscii;
  end;
  Result := (FFlags and NodeFlagAscii) <> 0;
end;

function TCharacterData.GetLength: Integer;
begin
  if IsAscii then
    Result := System.Length(FData)
  else
    Result := Utf16Length(FData);
end;

function TCharacterData.GetNodeValue: string;
begin
  Result := FData;
end;

procedure TCharacterData.SetNodeValue(const Value: string);
begin
  SetData(Value);
end;

function TCharacterData.GetTextContent: string;
begin
  Result := FData;
end;

procedure TCharacterData.SetTextContent(const Value: string);
begin
  SetData(Value);
end;

function TCharacterData.IsEqualSelf(Other: TNode): Boolean;
begin
  Result := (Other.FNodeType = FNodeType) and (TCharacterData(Other).FData = FData);
end;

function TCharacterData.SubstringData(Offset, Count: Integer): string;
var
  Total, StartByte, EndByte: Integer;
begin
  Total := GetLength;
  if (Offset < 0) or (Offset > Total) then
    RaiseDomError(IndexSizeError, 'the offset is past the end of the data');
  if (Count < 0) or (Offset + Count > Total) then
    Count := Total - Offset;
  if IsAscii then
    Exit(Copy(FData, Offset + 1, Count));
  StartByte := Utf16OffsetToByteOffset(FData, Offset);
  EndByte := Utf16OffsetToByteOffset(FData, Offset + Count);
  Result := Copy(FData, StartByte + 1, EndByte - StartByte);
end;

procedure TCharacterData.ReplaceData(Offset, Count: Integer; const Text: string);
var
  Total, StartByte, EndByte: Integer;
  OldValue: string;
begin
  Total := GetLength;
  if (Offset < 0) or (Offset > Total) then
    RaiseDomError(IndexSizeError, 'the offset is past the end of the data');
  if (Count < 0) or (Offset + Count > Total) then
    Count := Total - Offset;
  if IsAscii then
  begin
    StartByte := Offset;
    EndByte := Offset + Count;
  end
  else
  begin
    StartByte := Utf16OffsetToByteOffset(FData, Offset);
    EndByte := Utf16OffsetToByteOffset(FData, Offset + Count);
  end;
  OldValue := FData;
  FData := Copy(OldValue, 1, StartByte) + Text + Copy(OldValue, EndByte + 1, MaxInt);
  FFlags := FFlags and not NodeFlagAsciiKnown;
  if FOwnerDocument.FLiveRangeCount > 0 then
    FOwnerDocument.RangesDataReplaced(Self, Offset, Count, Utf16Length(Text));
  if DocumentHasObservers(FOwnerDocument) then
  begin
    FOwnerDocument.NotifyCharacterDataChanged(Self, OldValue);
    if FParent <> nil then
      FOwnerDocument.NotifyChildrenChanged(FParent);
  end;
end;

procedure TCharacterData.SetData(const Text: string);
var
  OldValue: string;
  OldLength: Integer;
begin
  OldValue := FData;
  OldLength := GetLength;
  FData := Text;
  FFlags := FFlags and not NodeFlagAsciiKnown;
  if FOwnerDocument.FLiveRangeCount > 0 then
    FOwnerDocument.RangesDataReplaced(Self, 0, OldLength, Utf16Length(Text));
  if DocumentHasObservers(FOwnerDocument) then
  begin
    FOwnerDocument.NotifyCharacterDataChanged(Self, OldValue);
    if FParent <> nil then
      FOwnerDocument.NotifyChildrenChanged(FParent);
  end;
end;

procedure TCharacterData.AppendData(const Text: string);
begin
  ReplaceData(GetLength, 0, Text);
end;

procedure TCharacterData.InsertData(Offset: Integer; const Text: string);
begin
  ReplaceData(Offset, 0, Text);
end;

procedure TCharacterData.DeleteData(Offset, Count: Integer);
begin
  ReplaceData(Offset, Count, '');
end;

procedure TCharacterData.AppendDataFromParser(const Text: string);
begin
  FData := FData + Text;
  FFlags := FFlags and not NodeFlagAsciiKnown;
end;

function TText.GetNodeName: string;
begin
  Result := '#text';
end;

function TText.CloneSelf(Document: TDocument): TNode;
begin
  Result := Document.NewText(FData);
end;

function TText.SplitText(Offset: Integer): TText;
var
  Total, Count: Integer;
  NewData: string;
begin
  Total := GetLength;
  if (Offset < 0) or (Offset > Total) then
    RaiseDomError(IndexSizeError, 'the offset is past the end of the data');
  Count := Total - Offset;
  NewData := SubstringData(Offset, Count);
  if FNodeType = NodeTypeCDataSection then
    Result := FOwnerDocument.CreateCDataSection(NewData)
  else
    Result := FOwnerDocument.CreateTextNode(NewData);
  if FParent <> nil then
    InsertNode(Result, FParent, FNextSibling, False);
  if FOwnerDocument.FLiveRangeCount > 0 then
    FOwnerDocument.RangesTextSplit(Self, Result, Offset);
  ReplaceData(Offset, Count, '');
end;

function TText.WholeText: string;
var
  First, Node: TNode;
begin
  First := Self;
  while (First.FPreviousSibling <> nil) and First.FPreviousSibling.IsText do
    First := First.FPreviousSibling;
  Result := '';
  Node := First;
  while (Node <> nil) and Node.IsText do
  begin
    Result := Result + TText(Node).FData;
    Node := Node.FNextSibling;
  end;
end;

function TCDataSection.GetNodeName: string;
begin
  Result := '#cdata-section';
end;

function TCDataSection.CloneSelf(Document: TDocument): TNode;
var
  Copy: TCDataSection;
begin
  Copy := TCDataSection.Create;
  InitializeNode(Copy, NodeTypeCDataSection, Document);
  Copy.FData := FData;
  Result := Copy;
end;

function TComment.GetNodeName: string;
begin
  Result := '#comment';
end;

function TComment.CloneSelf(Document: TDocument): TNode;
begin
  Result := Document.NewComment(FData);
end;

function TProcessingInstruction.GetNodeName: string;
begin
  Result := FTarget;
end;

function TProcessingInstruction.CloneSelf(Document: TDocument): TNode;
var
  Copy: TProcessingInstruction;
begin
  Copy := TProcessingInstruction.Create;
  InitializeNode(Copy, NodeTypeProcessingInstruction, Document);
  Copy.FTarget := FTarget;
  Copy.FData := FData;
  Result := Copy;
end;

function TProcessingInstruction.IsEqualSelf(Other: TNode): Boolean;
begin
  Result := inherited IsEqualSelf(Other) and (TProcessingInstruction(Other).FTarget = FTarget);
end;

function TDocumentType.GetNodeName: string;
begin
  Result := FName;
end;

function TDocumentType.CloneSelf(Document: TDocument): TNode;
begin
  Result := Document.NewDocumentType(FName, FPublicId, FSystemId);
end;

function TDocumentType.IsEqualSelf(Other: TNode): Boolean;
begin
  Result := (Other.FNodeType = NodeTypeDocumentType) and (TDocumentType(Other).FName = FName) and
    (TDocumentType(Other).FPublicId = FPublicId) and (TDocumentType(Other).FSystemId = FSystemId);
end;

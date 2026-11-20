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
  The QPACK decoder (RFC 9204): it keeps the dynamic table the peer's
  encoder builds through the encoder stream, decodes field sections
  (the HEADERS of HTTP/3) against the static and dynamic tables, and
  says what it did on the decoder stream.

    encoder stream   Set Dynamic Table Capacity  001 capacity(5)
                     Insert With Name Reference  1 T index(6) value
                     Insert With Literal Name    01 H length(5) name value
                     Duplicate                   000 index(5)
    field section    Required Insert Count(8), S + Delta Base(7), then
                     Indexed                     1 T index(6)
                     Indexed Post-Base           0001 index(4)
                     Literal Name Reference      01 N T index(4) value
                     Literal Post-Base Name      0000 N index(3) value
                     Literal Literal Name        001 N H length(3) name value
    decoder stream   Section Acknowledgment      1 stream(7)
                     Stream Cancellation         01 stream(6)
                     Insert Count Increment      00 increment(6)

  A section whose Required Insert Count is above the entries received
  so far is blocked: DecodeFieldSection says so and the caller tries
  again when the encoder stream has brought more (at most
  MaximumBlockedStreams streams wait at a time). Errors are QPACK's
  codes: QPACK_DECOMPRESSION_FAILED (0x200) for a section,
  QPACK_ENCODER_STREAM_ERROR (0x201) for the encoder stream.
}
unit Qpack.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Qpack.DynamicTable,
  Qpack.Primitives,
  Qpack.StaticTable;

const
  QpackDecompressionFailed = $200;
  QpackEncoderStreamError = $201;
  QpackDecoderStreamError = $202;

type
  TQpackDecodeResult = (DecodeDone, DecodeBlocked, DecodeFailed);

  TQpackDecoder = class
  private
    FTable: TQpackDynamicTable;
    FMaximumBlockedStreams: Integer;
    FMaximumSectionSize: QWord;
    { Encoder stream bytes not yet a whole instruction. }
    FPending: array of Byte;
    FPendingLength: Integer;
    { What goes out on the decoder stream. }
    FOutput: TQpackOutput;
    { Inserts the encoder knows arrived (acknowledged sections and
      increments sent). }
    FKnownReceivedCount: QWord;
    FBlockedStreams: array of QWord;
    function MaximumEntries: QWord;
    function DecodeRequiredInsertCount(Encoded: QWord; out Required: QWord): Boolean;
    function ProcessInstruction(var Input: TQpackInput): Boolean;
    procedure NoteBlocked(StreamId: QWord; Blocked: Boolean);
  public
    { MaximumCapacity is the SETTINGS_QPACK_MAX_TABLE_CAPACITY given to
      the peer, BlockedStreams its SETTINGS_QPACK_BLOCKED_STREAMS. }
    constructor Create(MaximumCapacity: QWord; BlockedStreams: Integer);
    { Encoder stream bytes, in any pieces: 0, or QPACK_ENCODER_STREAM_ERROR. }
    function ProcessEncoderStream(Data: PByte; Length: PtrUInt): QWord;
    { A whole field section of StreamId. DecodeBlocked: call again once
      more has come on the encoder stream; DecodeFailed: Error says
      why (QPACK_DECOMPRESSION_FAILED). }
    function DecodeFieldSection(StreamId: QWord; Data: PByte; Length: PtrUInt; out Fields: TQpackFieldList;
      out Error: QWord): TQpackDecodeResult;
    { The stream was reset or abandoned before its section was read. }
    procedure CancelStream(StreamId: QWord);
    { Bytes for the decoder stream, taken once (with an Insert Count
      Increment for entries no acknowledgment covered). }
    function TakeDecoderStreamBytes: TBytes;
    property Table: TQpackDynamicTable read FTable;
    property InsertCount: QWord read FTable.InsertCount;
    { The sum of the field lines' sizes a section may decode to. }
    property MaximumSectionSize: QWord read FMaximumSectionSize write FMaximumSectionSize;
  end;

implementation

constructor TQpackDecoder.Create(MaximumCapacity: QWord; BlockedStreams: Integer);
begin
  inherited Create;
  FTable.Initialize(MaximumCapacity);
  FMaximumBlockedStreams := BlockedStreams;
  FMaximumSectionSize := 65536;
end;

function TQpackDecoder.MaximumEntries: QWord;
begin
  Result := FTable.MaximumCapacity div 32;
end;

function TQpackDecoder.DecodeRequiredInsertCount(Encoded: QWord; out Required: QWord): Boolean;
var
  FullRange, MaxValue, MaxWrapped: QWord;
begin
  { RFC 9204 section 4.5.1.1. }
  Required := 0;
  if Encoded = 0 then
    Exit(True);
  FullRange := 2 * MaximumEntries;
  if Encoded > FullRange then
    Exit(False);
  MaxValue := FTable.InsertCount + MaximumEntries;
  MaxWrapped := (MaxValue div FullRange) * FullRange;
  Required := MaxWrapped + Encoded - 1;
  if Required > MaxValue then
  begin
    if Required <= FullRange then
      Exit(False);
    Required := Required - FullRange;
  end;
  Result := Required <> 0;
end;

function TQpackDecoder.ProcessInstruction(var Input: TQpackInput): Boolean;
var
  First: Byte;
  Index, Capacity: QWord;
  Name, Value: string;
  Field: TQpackField;
begin
  Result := False;
  if not PeekByte(Input, First) then
    Exit;
  if (First and $80) <> 0 then
  begin
    { Insert With Name Reference. }
    if not ReadPrefixedInteger(Input, 6, Index) or not ReadStringLiteral(Input, 7, Value) then
      Exit;
    if (First and $40) <> 0 then
    begin
      if not StaticEntry(Integer(Index), Field) then
      begin
        Input.Malformed := True;
        Exit;
      end;
    end
    else if (Index >= FTable.InsertCount) or not FTable.Get(FTable.InsertCount - 1 - Index, Field) then
    begin
      Input.Malformed := True;
      Exit;
    end;
    if not FTable.Insert(Field.Name, Value) then
      Input.Malformed := True;
    Exit(not Input.Malformed);
  end;
  if (First and $40) <> 0 then
  begin
    { Insert With Literal Name. }
    if not ReadStringLiteral(Input, 5, Name) or not ReadStringLiteral(Input, 7, Value) then
      Exit;
    if not FTable.Insert(Name, Value) then
      Input.Malformed := True;
    Exit(not Input.Malformed);
  end;
  if (First and $20) <> 0 then
  begin
    { Set Dynamic Table Capacity. }
    if not ReadPrefixedInteger(Input, 5, Capacity) then
      Exit;
    if not FTable.SetCapacity(Capacity) then
      Input.Malformed := True;
    Exit(not Input.Malformed);
  end;
  { Duplicate. }
  if not ReadPrefixedInteger(Input, 5, Index) then
    Exit;
  if (Index >= FTable.InsertCount) or not FTable.Get(FTable.InsertCount - 1 - Index, Field) or
     not FTable.Insert(Field.Name, Field.Value) then
  begin
    Input.Malformed := True;
    Exit;
  end;
  Result := True;
end;

function TQpackDecoder.ProcessEncoderStream(Data: PByte; Length: PtrUInt): QWord;
var
  Input: TQpackInput;
  Consumed: PtrUInt;
  Start: PByte;
begin
  Result := 0;
  if FPendingLength + Integer(Length) > System.Length(FPending) then
    SetLength(FPending, (FPendingLength + Integer(Length)) * 2 + 64);
  if Length > 0 then
    Move(Data^, FPending[FPendingLength], Length);
  FPendingLength := FPendingLength + Integer(Length);
  InitializeInput(Input, @FPending[0], FPendingLength);
  while InputRemaining(Input) > 0 do
  begin
    Start := Input.Position;
    if not ProcessInstruction(Input) then
    begin
      if Input.Malformed then
        Exit(QpackEncoderStreamError);
      { Not whole yet: it is read again when the rest comes. }
      Input.Position := Start;
      Break;
    end;
  end;
  Consumed := PtrUInt(Input.Position - PByte(@FPending[0]));
  if Consumed > 0 then
  begin
    if Consumed < PtrUInt(FPendingLength) then
      Move(FPending[Consumed], FPending[0], PtrUInt(FPendingLength) - Consumed);
    FPendingLength := FPendingLength - Integer(Consumed);
  end;
end;

procedure TQpackDecoder.NoteBlocked(StreamId: QWord; Blocked: Boolean);
var
  Index: Integer;
begin
  for Index := 0 to High(FBlockedStreams) do
    if FBlockedStreams[Index] = StreamId then
    begin
      if not Blocked then
        Delete(FBlockedStreams, Index, 1);
      Exit;
    end;
  if Blocked then
  begin
    SetLength(FBlockedStreams, System.Length(FBlockedStreams) + 1);
    FBlockedStreams[High(FBlockedStreams)] := StreamId;
  end;
end;

function TQpackDecoder.DecodeFieldSection(StreamId: QWord; Data: PByte; Length: PtrUInt;
  out Fields: TQpackFieldList; out Error: QWord): TQpackDecodeResult;
var
  Input: TQpackInput;
  Encoded, Required, Delta, Base, Index: QWord;
  First: Byte;
  Field: TQpackField;
  Value, Name: string;
  Negative: Boolean;
  TotalSize: QWord;

  function Fail: TQpackDecodeResult;
  begin
    Error := QpackDecompressionFailed;
    Fields := nil;
    NoteBlocked(StreamId, False);
    Result := DecodeFailed;
  end;

  function DynamicEntry(AbsoluteIndex: QWord; out Entry: TQpackField): Boolean;
  begin
    Result := (AbsoluteIndex < Required) and FTable.Get(AbsoluteIndex, Entry);
  end;

begin
  Fields := nil;
  Error := 0;
  InitializeInput(Input, Data, Length);
  if not ReadPrefixedInteger(Input, 8, Encoded) or not DecodeRequiredInsertCount(Encoded, Required) then
    Exit(Fail);
  if not PeekByte(Input, First) then
    Exit(Fail);
  Negative := (First and $80) <> 0;
  if not ReadPrefixedInteger(Input, 7, Delta) then
    Exit(Fail);
  if Negative then
  begin
    if Delta + 1 > Required then
      Exit(Fail);
    Base := Required - Delta - 1;
  end
  else
    Base := Required + Delta;
  if Required > FTable.InsertCount then
  begin
    if (System.Length(FBlockedStreams) >= FMaximumBlockedStreams) then
    begin
      { Already counted, or one more than allowed. }
      for Index := 0 to High(FBlockedStreams) do
        if FBlockedStreams[Index] = StreamId then
          Exit(DecodeBlocked);
      Exit(Fail);
    end;
    NoteBlocked(StreamId, True);
    Exit(DecodeBlocked);
  end;
  TotalSize := 0;
  while InputRemaining(Input) > 0 do
  begin
    PeekByte(Input, First);
    if (First and $80) <> 0 then
    begin
      { Indexed Field Line. }
      if not ReadPrefixedInteger(Input, 6, Index) then
        Exit(Fail);
      if (First and $40) <> 0 then
      begin
        if not StaticEntry(Integer(Index), Field) then
          Exit(Fail);
      end
      else if (Index >= Base) or not DynamicEntry(Base - 1 - Index, Field) then
        Exit(Fail);
    end
    else if (First and $40) <> 0 then
    begin
      { Literal Field Line With Name Reference. }
      if not ReadPrefixedInteger(Input, 4, Index) or not ReadStringLiteral(Input, 7, Value) then
        Exit(Fail);
      if (First and $10) <> 0 then
      begin
        if not StaticEntry(Integer(Index), Field) then
          Exit(Fail);
      end
      else if (Index >= Base) or not DynamicEntry(Base - 1 - Index, Field) then
        Exit(Fail);
      Field.Value := Value;
    end
    else if (First and $20) <> 0 then
    begin
      { Literal Field Line With Literal Name. }
      if not ReadStringLiteral(Input, 3, Name) or not ReadStringLiteral(Input, 7, Value) then
        Exit(Fail);
      Field.Name := Name;
      Field.Value := Value;
    end
    else if (First and $10) <> 0 then
    begin
      { Indexed Field Line With Post-Base Index. }
      if not ReadPrefixedInteger(Input, 4, Index) or not DynamicEntry(Base + Index, Field) then
        Exit(Fail);
    end
    else
    begin
      { Literal Field Line With Post-Base Name Reference. }
      if not ReadPrefixedInteger(Input, 3, Index) or not ReadStringLiteral(Input, 7, Value) or
         not DynamicEntry(Base + Index, Field) then
        Exit(Fail);
      Field.Value := Value;
    end;
    TotalSize := TotalSize + EntrySize(Field.Name, Field.Value);
    if TotalSize > FMaximumSectionSize then
      Exit(Fail);
    SetLength(Fields, System.Length(Fields) + 1);
    Fields[High(Fields)] := Field;
  end;
  NoteBlocked(StreamId, False);
  if Required > 0 then
  begin
    { Section Acknowledgment. }
    AppendPrefixedInteger(FOutput, $80, 7, StreamId);
    if Required > FKnownReceivedCount then
      FKnownReceivedCount := Required;
  end;
  Result := DecodeDone;
end;

procedure TQpackDecoder.CancelStream(StreamId: QWord);
begin
  NoteBlocked(StreamId, False);
  { Stream Cancellation, only when the table is in use. }
  if FTable.MaximumCapacity > 0 then
    AppendPrefixedInteger(FOutput, $40, 6, StreamId);
end;

function TQpackDecoder.TakeDecoderStreamBytes: TBytes;
begin
  { Inserts not yet acknowledged by a section: Insert Count Increment. }
  if FTable.InsertCount > FKnownReceivedCount then
  begin
    AppendPrefixedInteger(FOutput, $00, 6, FTable.InsertCount - FKnownReceivedCount);
    FKnownReceivedCount := FTable.InsertCount;
  end;
  Result := OutputBytes(FOutput);
  FOutput.Length := 0;
end;

end.

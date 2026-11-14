{
  dd - convert and copy a file

  dd [OPERAND]...

    if=FILE      read from FILE instead of standard input
    of=FILE      write to FILE instead of standard output
    bs=BYTES     read and write BYTES at a time (ibs and obs)
    ibs=BYTES    read BYTES at a time (default 512)
    obs=BYTES    write BYTES at a time (default 512)
    count=N      copy only N input blocks
    skip=N       skip N input blocks first
    seek=N       skip N output blocks first
    conv=LIST    lcase, ucase, notrunc, sync (pad input blocks with
                 zeros), noerror, fsync
    status=LEVEL none, noxfer or progress (accepted)

  Prints the records read and written and the bytes copied on standard
  error at the end.
}
program dd;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.Messages,
  Util.Sizes;

const
  Usage: PChar = 'Usage: dd [OPERAND]...'#10 +
    'Copy a file, converting and formatting according to the operands.'#10#10 +
    '  bs=BYTES        read and write up to BYTES bytes at a time (default: 512)'#10 +
    '  cbs=BYTES       accepted for compatibility'#10 +
    '  conv=CONVS      convert the file as per the comma separated symbol list'#10 +
    '  count=N         copy only N input blocks'#10 +
    '  ibs=BYTES       read up to BYTES bytes at a time (default: 512)'#10 +
    '  if=FILE         read from FILE instead of stdin'#10 +
    '  obs=BYTES       write BYTES bytes at a time (default: 512)'#10 +
    '  of=FILE         write to FILE instead of stdout'#10 +
    '  seek=N          skip N obs-sized blocks at start of output'#10 +
    '  skip=N          skip N ibs-sized blocks at start of input'#10 +
    '  status=LEVEL    none suppresses everything but error messages'#10#10 +
    'CONVS: lcase ucase notrunc sync noerror fsync'#10;

var
  InputPath: PChar;
  OutputPath: PChar;
  InputBlockSize: QWord;
  OutputBlockSize: QWord;
  CountBlocks: Int64;
  SkipBlocks: QWord;
  SeekBlocks: QWord;
  ToLower, ToUpper, NoTruncate, PadBlocks, IgnoreErrors, SyncAtEnd: Boolean;
  Quiet: Boolean;
  NoTransferLine: Boolean;

procedure ParseNumber(Text, Name: PChar; out Value: QWord);
begin
  if not ParseSize(Text, Value) then
    Fail(1, 'invalid number: ''%s''', [ArgumentText(Text)]);
end;

procedure ParseConversions(Text: PChar);
var
  Copy: PChar;
  Start: PChar;
  Comma: PtrInt;
begin
  Copy := DuplicateText(Text);
  Start := Copy;
  repeat
    Comma := FindCharacter(Start, ',');
    if Comma >= 0 then
      Start[Comma] := #0;
    if TextIsEqual(Start, 'lcase') then ToLower := True
    else if TextIsEqual(Start, 'ucase') then ToUpper := True
    else if TextIsEqual(Start, 'notrunc') then NoTruncate := True
    else if TextIsEqual(Start, 'sync') then PadBlocks := True
    else if TextIsEqual(Start, 'noerror') then IgnoreErrors := True
    else if TextIsEqual(Start, 'fsync') or TextIsEqual(Start, 'fdatasync') then SyncAtEnd := True
    else
      Fail(1, 'invalid conversion: ''%s''', [ArgumentText(Start)]);
    if Comma >= 0 then
      Start := Start + Comma + 1;
  until Comma < 0;
  FreeMemory(Copy);
end;

procedure ParseOperand(Text: PChar);
var
  Equals: PtrInt;
  Name: array[0..15] of Char;
  Value: PChar;
  Number: QWord;
begin
  Equals := FindCharacter(Text, '=');
  if (Equals <= 0) or (Equals >= SizeOf(Name)) then
    FailWithUsageHint('unrecognized operand ''%s''', [ArgumentText(Text)]);
  CopyText(@Name[0], Text, PtrUInt(Equals) + 1);
  Value := Text + Equals + 1;
  if TextIsEqual(@Name[0], 'if') then InputPath := Value
  else if TextIsEqual(@Name[0], 'of') then OutputPath := Value
  else if TextIsEqual(@Name[0], 'bs') then
  begin
    ParseNumber(Value, @Name[0], Number);
    InputBlockSize := Number;
    OutputBlockSize := Number;
  end
  else if TextIsEqual(@Name[0], 'ibs') then ParseNumber(Value, @Name[0], InputBlockSize)
  else if TextIsEqual(@Name[0], 'obs') then ParseNumber(Value, @Name[0], OutputBlockSize)
  else if TextIsEqual(@Name[0], 'cbs') then ParseNumber(Value, @Name[0], Number)
  else if TextIsEqual(@Name[0], 'count') then
  begin
    ParseNumber(Value, @Name[0], Number);
    CountBlocks := Int64(Number);
  end
  else if TextIsEqual(@Name[0], 'skip') then ParseNumber(Value, @Name[0], SkipBlocks)
  else if TextIsEqual(@Name[0], 'seek') then ParseNumber(Value, @Name[0], SeekBlocks)
  else if TextIsEqual(@Name[0], 'conv') then ParseConversions(Value)
  else if TextIsEqual(@Name[0], 'status') then
  begin
    Quiet := TextIsEqual(Value, 'none');
    NoTransferLine := TextIsEqual(Value, 'noxfer');
  end
  else
    FailWithUsageHint('unrecognized operand ''%s''', [ArgumentText(Text)]);
  if (InputBlockSize = 0) or (OutputBlockSize = 0) then
    Fail(1, 'invalid number: ''%s''', [ArgumentText(Value)]);
end;

var
  Index: Integer;
  Input: Int64;
  Output: Int64;
  Flags: LongWord;
  InputBuffer: PByte;
  OutputBuffer: PByte;
  OutputFill: QWord;
  Count: Int64;
  FullIn, PartialIn, FullOut, PartialOut: QWord;
  TotalBytes: QWord;
  BlocksRead: Int64;
  Position: Int64;
  Take: QWord;
  Started: QWord;
  Elapsed: QWord;
  Error: LongInt;
  Skipped: QWord;

procedure WriteOutputBlock(ByteCount: QWord);
begin
  if ByteCount = 0 then
    Exit;
  Error := WriteAll(Output, OutputBuffer, ByteCount);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'error writing ''%s''', [ArgumentText(OutputPath)]);
  if ByteCount = OutputBlockSize then
    Inc(FullOut)
  else
    Inc(PartialOut);
  TotalBytes := TotalBytes + ByteCount;
end;

begin
  InputBlockSize := 512;
  OutputBlockSize := 512;
  CountBlocks := -1;
  InputPath := nil;
  OutputPath := nil;
  for Index := 1 to ArgumentTotal - 1 do
  begin
    if TextIsEqual(Argument(Index), '--help') then
    begin
      Print(Usage);
      Halt(0);
    end;
    ParseOperand(Argument(Index));
  end;

  Input := StandardInputHandle;
  if InputPath <> nil then
  begin
    Input := OpenFile(InputPath, OpenRead);
    if Input < 0 then
      FailWithError(1, ErrorCodeOf(Input), 'failed to open ''%s''', [ArgumentText(InputPath)]);
  end
  else
    InputPath := 'standard input';
  Output := StandardOutputHandle;
  if OutputPath <> nil then
  begin
    Flags := OpenWrite or OpenCreate;
    if not NoTruncate and (SeekBlocks = 0) then
      Flags := Flags or OpenTruncate;
    Output := OpenFile(OutputPath, Flags);
    if Output < 0 then
      FailWithError(1, ErrorCodeOf(Output), 'failed to open ''%s''', [ArgumentText(OutputPath)]);
    if SeekBlocks > 0 then
    begin
      SeekFile(Output, Int64(SeekBlocks * OutputBlockSize), SeekFromStart);
      if not NoTruncate then
        SetFileSize(Output, SeekBlocks * OutputBlockSize);
    end;
  end
  else
    OutputPath := 'standard output';

  InputBuffer := PByte(AllocateMemory(InputBlockSize));
  OutputBuffer := PByte(AllocateMemory(OutputBlockSize));
  Started := UptimeMilliseconds;

  { Skip by seeking when possible, otherwise by reading. }
  if SkipBlocks > 0 then
  begin
    if SeekFile(Input, Int64(SkipBlocks * InputBlockSize), SeekFromStart) < 0 then
    begin
      Skipped := 0;
      while Skipped < SkipBlocks do
      begin
        if ReadFile(Input, InputBuffer, InputBlockSize) <= 0 then
          Break;
        Inc(Skipped);
      end;
    end;
  end;

  FullIn := 0;
  PartialIn := 0;
  FullOut := 0;
  PartialOut := 0;
  TotalBytes := 0;
  OutputFill := 0;
  BlocksRead := 0;
  while (CountBlocks < 0) or (BlocksRead < CountBlocks) do
  begin
    Count := ReadFile(Input, InputBuffer, InputBlockSize);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), 'error reading ''%s''', [ArgumentText(InputPath)]);
      if not IgnoreErrors then
        Break;
      Count := 0;
    end;
    if Count = 0 then
      Break;
    Inc(BlocksRead);
    if QWord(Count) = InputBlockSize then
      Inc(FullIn)
    else
    begin
      Inc(PartialIn);
      if PadBlocks then
      begin
        ZeroMemory(InputBuffer + Count, InputBlockSize - QWord(Count));
        Count := Int64(InputBlockSize);
      end;
    end;
    for Position := 0 to Count - 1 do
    begin
      if ToUpper then
        InputBuffer[Position] := Byte(ToUpperCase(Char(InputBuffer[Position])))
      else if ToLower then
        InputBuffer[Position] := Byte(ToLowerCase(Char(InputBuffer[Position])));
    end;
    { Re-block into output blocks. }
    Position := 0;
    while Position < Count do
    begin
      Take := OutputBlockSize - OutputFill;
      if Take > QWord(Count - Position) then
        Take := QWord(Count - Position);
      CopyMemory(OutputBuffer + OutputFill, InputBuffer + Position, Take);
      OutputFill := OutputFill + Take;
      Position := Position + Int64(Take);
      if OutputFill = OutputBlockSize then
      begin
        WriteOutputBlock(OutputFill);
        OutputFill := 0;
      end;
    end;
  end;
  WriteOutputBlock(OutputFill);
  if SyncAtEnd then
    SyncFileSystems;
  if Output <> StandardOutputHandle then
    CloseFile(Output);
  if Input <> StandardInputHandle then
    CloseFile(Input);

  if not Quiet then
  begin
    WriteFormatted(StandardError, '%u+%u records in'#10'%u+%u records out'#10, [ArgumentUnsigned(FullIn),
      ArgumentUnsigned(PartialIn), ArgumentUnsigned(FullOut), ArgumentUnsigned(PartialOut)]);
    if not NoTransferLine then
    begin
      Elapsed := UptimeMilliseconds - Started;
      WriteFormatted(StandardError, '%u bytes copied, %u.%03u s'#10, [ArgumentUnsigned(TotalBytes),
        ArgumentUnsigned(Elapsed div 1000), ArgumentUnsigned(Elapsed mod 1000)]);
    end;
  end;
end.

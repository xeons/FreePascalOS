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

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Text,
  Sys.Time,
  Util.Messages,
  Util.Output,
  Util.Sizes;

const
  Usage = 'Usage: dd [OPERAND]...'#10 +
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
  InputPath: string;
  OutputPath: string;
  HasInputPath: Boolean;
  HasOutputPath: Boolean;
  InputBlockSize: QWord;
  OutputBlockSize: QWord;
  CountBlocks: Int64;
  SkipBlocks: QWord;
  SeekBlocks: QWord;
  ToLower, ToUpper, NoTruncate, PadBlocks, IgnoreErrors, SyncAtEnd: Boolean;
  Quiet: Boolean;
  NoTransferLine: Boolean;

function ParseNumber(const Text: string): QWord;
begin
  if not ParseSize(Text, Result) then
    Fail(1, Format('invalid number: ''%s''', [Text]));
end;

procedure ApplyConversion(const Name: string);
begin
  if Name = 'lcase' then ToLower := True
  else if Name = 'ucase' then ToUpper := True
  else if Name = 'notrunc' then NoTruncate := True
  else if Name = 'sync' then PadBlocks := True
  else if Name = 'noerror' then IgnoreErrors := True
  else if (Name = 'fsync') or (Name = 'fdatasync') then SyncAtEnd := True
  else
    Fail(1, Format('invalid conversion: ''%s''', [Name]));
end;

{ A comma separated list of conversions (an empty one is invalid). }
procedure ParseConversions(const Text: string);
var
  Rest: string;
  Comma: Integer;
begin
  Rest := Text;
  repeat
    Comma := Pos(',', Rest);
    if Comma > 0 then
    begin
      ApplyConversion(Copy(Rest, 1, Comma - 1));
      Delete(Rest, 1, Comma);
    end
    else
      ApplyConversion(Rest);
  until Comma = 0;
end;

procedure ParseOperand(const Text: string);
var
  Equals: Integer;
  Name: string;
  Value: string;
  Number: QWord;
begin
  Equals := Pos('=', Text);
  if Equals <= 1 then
    FailWithUsageHint(Format('unrecognized operand ''%s''', [Text]));
  Name := Copy(Text, 1, Equals - 1);
  Value := Copy(Text, Equals + 1, MaxInt);
  if Name = 'if' then
  begin
    InputPath := Value;
    HasInputPath := True;
  end
  else if Name = 'of' then
  begin
    OutputPath := Value;
    HasOutputPath := True;
  end
  else if Name = 'bs' then
  begin
    Number := ParseNumber(Value);
    InputBlockSize := Number;
    OutputBlockSize := Number;
  end
  else if Name = 'ibs' then InputBlockSize := ParseNumber(Value)
  else if Name = 'obs' then OutputBlockSize := ParseNumber(Value)
  else if Name = 'cbs' then ParseNumber(Value)
  else if Name = 'count' then CountBlocks := Int64(ParseNumber(Value))
  else if Name = 'skip' then SkipBlocks := ParseNumber(Value)
  else if Name = 'seek' then SeekBlocks := ParseNumber(Value)
  else if Name = 'conv' then ParseConversions(Value)
  else if Name = 'status' then
  begin
    Quiet := Value = 'none';
    NoTransferLine := Value = 'noxfer';
  end
  else
    FailWithUsageHint(Format('unrecognized operand ''%s''', [Text]));
  if (InputBlockSize = 0) or (OutputBlockSize = 0) then
    Fail(1, Format('invalid number: ''%s''', [Value]));
end;

var
  Index: Integer;
  Input: Int64;
  Output: Int64;
  Flags: LongWord;
  InputBuffer: array of Byte;
  OutputBuffer: array of Byte;
  OutputFill: QWord;
  Count: Int64;
  FullIn, PartialIn, FullOut, PartialOut: QWord;
  TotalBytes: QWord;
  BlocksRead: Int64;
  { Read errors end the program with status 1 (after the summary). }
  ReadFailed: Boolean;
  Position: Int64;
  Take: QWord;
  Started: QWord;
  Elapsed: QWord;
  Skipped: QWord;

procedure WriteOutputBlock(ByteCount: QWord);
var
  Error: LongInt;
begin
  if ByteCount = 0 then
    Exit;
  Error := WriteAll(Output, @OutputBuffer[0], ByteCount);
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('error writing ''%s''', [OutputPath]));
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
  for Index := 1 to ArgumentTotal - 1 do
  begin
    if Argument(Index) = '--help' then
    begin
      PrintString(Usage);
      Halt(0);
    end;
    ParseOperand(Argument(Index));
  end;

  Input := StandardInputHandle;
  if HasInputPath then
  begin
    Input := OpenFile(PChar(InputPath), OpenRead);
    if Input < 0 then
      FailWithError(1, ErrorCodeOf(Input), Format('failed to open ''%s''', [InputPath]));
  end
  else
    InputPath := 'standard input';
  Output := StandardOutputHandle;
  if HasOutputPath then
  begin
    Flags := OpenWrite or OpenCreate;
    if not NoTruncate and (SeekBlocks = 0) then
      Flags := Flags or OpenTruncate;
    Output := OpenFile(PChar(OutputPath), Flags);
    if Output < 0 then
      FailWithError(1, ErrorCodeOf(Output), Format('failed to open ''%s''', [OutputPath]));
    if SeekBlocks > 0 then
    begin
      SeekFile(Output, Int64(SeekBlocks * OutputBlockSize), SeekFromStart);
      if not NoTruncate then
        SetFileSize(Output, SeekBlocks * OutputBlockSize);
    end;
  end
  else
    OutputPath := 'standard output';

  SetLength(InputBuffer, InputBlockSize);
  SetLength(OutputBuffer, OutputBlockSize);
  Started := UptimeMilliseconds;

  { Skip by seeking when possible, otherwise by reading. }
  if SkipBlocks > 0 then
  begin
    if SeekFile(Input, Int64(SkipBlocks * InputBlockSize), SeekFromStart) < 0 then
    begin
      Skipped := 0;
      while Skipped < SkipBlocks do
      begin
        if ReadFile(Input, @InputBuffer[0], InputBlockSize) <= 0 then
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
  ReadFailed := False;
  while (CountBlocks < 0) or (BlocksRead < CountBlocks) do
  begin
    Count := ReadFile(Input, @InputBuffer[0], InputBlockSize);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), Format('error reading ''%s''', [InputPath]));
      ReadFailed := True;
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
        FillChar(InputBuffer[Count], InputBlockSize - QWord(Count), 0);
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
      Move(InputBuffer[Position], OutputBuffer[OutputFill], Take);
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
    PrintErrorString(Format('%d+%d records in'#10'%d+%d records out'#10, [FullIn, PartialIn, FullOut,
      PartialOut]));
    if not NoTransferLine then
    begin
      Elapsed := UptimeMilliseconds - Started;
      PrintErrorString(Format('%d bytes copied, %d.%.3d s'#10, [TotalBytes, Elapsed div 1000,
        Elapsed mod 1000]));
    end;
  end;
  if ReadFailed then
    Halt(1);
end.

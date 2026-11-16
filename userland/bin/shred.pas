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
  shred - overwrite a file to hide its contents, and optionally delete it

  shred [-fuvxz] [-n N] [-s SIZE] FILE...

  Each FILE is overwritten N times (default 3) with random data, then
  with zeros if -z is given. With -u it is then renamed to random names
  of shrinking length (so its name is gone too) and removed.

  As GNU shred warns: file systems that do not overwrite in place make
  this ineffective. ext2/3/4 and FAT here do overwrite in place.
}
program shred;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Crypto.Random,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.Sizes;

const
  Usage: PChar = 'Usage: shred [OPTION]... FILE...'#10 +
    'Overwrite the specified FILE(s) repeatedly, in order to make it harder'#10 +
    'for even very expensive hardware probing to recover the data.'#10#10 +
    '  -f, --force    change permissions to allow writing if necessary'#10 +
    '  -n, --iterations=N  overwrite N times instead of the default (3)'#10 +
    '  -s, --size=N   shred this many bytes (suffixes like K, M, G accepted)'#10 +
    '  -u             deallocate and remove file after overwriting'#10 +
    '  -v, --verbose  show progress'#10 +
    '  -x, --exact    do not round file sizes up to the next full block'#10 +
    '  -z, --zero     add a final overwrite with zeros to hide shredding'#10;

  OptionForce = 1;
  OptionIterations = 2;
  OptionSize = 3;
  OptionRemove = 4;
  OptionVerbose = 5;
  OptionExact = 6;
  OptionZero = 7;
  BufferSize = 65536;
  BlockSize = 4096;
  NameCharacters = '0123456789abcdefghijklmnopqrstuvwxyz';

var
  Iterations: Int64;
  Size: Int64;      { -1 = the file's size }
  Remove: Boolean;
  Verbose: Boolean;
  Exact: Boolean;
  FinalZero: Boolean;
  Force: Boolean;
  Buffer: array of Byte;

{ "<program>: <message>" on standard error, for -v. }
procedure ReportProgress(const Message: string);
begin
  WriteText(StandardError, PChar(string(ProgramName) + ': ' + Message + #10));
end;

{ Copies a heap string from the libraries and frees it. }
function TakeText(Text: PChar): string;
begin
  Result := Text;
  FreeMemory(Text);
end;

{ Directory + '/' + Name, without doubling the slash. }
function JoinPath(const Directory, Name: string): string;
begin
  if (Directory <> '') and (Directory[Length(Directory)] <> '/') then
    Result := Directory + '/' + Name
  else
    Result := Directory + Name;
end;

function OverwritePass(Handle: Int64; const Path: string; Length: QWord; UseZeros: Boolean;
  PassNumber, PassCount: Integer): Boolean;
var
  Written: QWord;
  Chunk: QWord;
  Error: LongInt;
begin
  if Verbose then
  begin
    if UseZeros then
      ReportProgress(Format('%s: pass %d/%d (000000)...', [Path, PassNumber, PassCount]))
    else
      ReportProgress(Format('%s: pass %d/%d (random)...', [Path, PassNumber, PassCount]));
  end;
  SeekFile(Handle, 0, SeekFromStart);
  Written := 0;
  while Written < Length do
  begin
    Chunk := Length - Written;
    if Chunk > BufferSize then
      Chunk := BufferSize;
    if UseZeros then
      FillChar(Buffer[0], Chunk, 0)
    else
      RandomBytes(@Buffer[0], Chunk);
    Error := WriteAll(Handle, @Buffer[0], Chunk);
    if Error <> ErrorNone then
    begin
      ReportError(Error, '%s: error writing', [ArgumentText(PChar(Path))]);
      Exit(False);
    end;
    Written := Written + Chunk;
  end;
  { Make each pass reach the disk before the next one. }
  SyncFileSystems;
  Result := True;
end;

function RandomName(Length: Integer): string;
var
  Index: Integer;
begin
  SetLength(Result, Length);
  for Index := 1 to Length do
    Result[Index] := NameCharacters[1 + RandomBelow(System.Length(NameCharacters))];
end;

{ Renames Path to ever shorter random names, then removes it. }
function WipeName(const Path: string): Boolean;
var
  Directory: string;
  Current: string;
  Candidate: string;
  Length: Integer;
  Error: LongInt;
begin
  Directory := TakeText(DirectoryName(PChar(Path)));
  Current := Path;
  Length := System.Length(TakeText(BaseName(PChar(Path))));
  while Length > 0 do
  begin
    Candidate := JoinPath(Directory, RandomName(Length));
    if not PathExists(PChar(Candidate)) and (RenamePath(PChar(Current), PChar(Candidate)) = ErrorNone) then
    begin
      if Verbose then
        ReportProgress(Current + ': renamed to ' + Candidate);
      Current := Candidate;
    end;
    Dec(Length);
  end;
  Error := RemovePath(PChar(Current));
  if Error <> ErrorNone then
    ReportError(Error, '%s: failed to remove', [ArgumentText(PChar(Current))])
  else if Verbose then
    ReportProgress(Path + ': removed');
  Result := Error = ErrorNone;
end;

function ShredFile(const Path: string): Boolean;
var
  Handle: Int64;
  Information: TFileInformation;
  Length: QWord;
  Pass: Integer;
  PassCount: Integer;
begin
  Handle := OpenFile(PChar(Path), OpenWrite);
  if (Handle < 0) and Force then
  begin
    ChangeMode(PChar(Path), $180);
    Handle := OpenFile(PChar(Path), OpenWrite);
  end;
  if Handle < 0 then
  begin
    ReportError(ErrorCodeOf(Handle), '%s: failed to open for writing', [ArgumentText(PChar(Path))]);
    Exit(False);
  end;
  GetHandleInformation(Handle, Information);
  if Information.Kind <> KindFile then
  begin
    CloseFile(Handle);
    Report('%s: invalid file type', [ArgumentText(PChar(Path))]);
    Exit(False);
  end;
  if Size >= 0 then
    Length := QWord(Size)
  else
    Length := Information.SizeInBytes;
  if not Exact and (Size < 0) then
    Length := (Length + BlockSize - 1) and not QWord(BlockSize - 1);

  PassCount := Integer(Iterations);
  if FinalZero then
    Inc(PassCount);
  Result := True;
  for Pass := 1 to Integer(Iterations) do
    if not OverwritePass(Handle, Path, Length, False, Pass, PassCount) then
    begin
      Result := False;
      Break;
    end;
  if Result and FinalZero then
    Result := OverwritePass(Handle, Path, Length, True, PassCount, PassCount);
  { Rounding up must not make the file longer than it was. }
  if (Size < 0) and (Length > Information.SizeInBytes) then
    SetFileSize(Handle, Information.SizeInBytes);
  CloseFile(Handle);
  if Result and Remove then
  begin
    { Truncate first so the data blocks are released, then the name. }
    Handle := OpenFile(PChar(Path), OpenWrite or OpenTruncate);
    if Handle >= 0 then
      CloseFile(Handle);
    Result := WipeName(Path);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  ByteCount: QWord;
  ExitStatus: LongInt;
begin
  Iterations := 3;
  Size := -1;
  BeginOptions(Parser, [
    OptionDefinition('f', 'force', False, OptionForce),
    OptionDefinition('n', 'iterations', True, OptionIterations),
    OptionDefinition('s', 'size', True, OptionSize),
    OptionDefinition('u', 'remove', False, OptionRemove),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('x', 'exact', False, OptionExact),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionForce: Force := True;
      OptionIterations:
        if not ParseInteger(Value, Iterations) or (Iterations < 0) then
          Fail(1, 'invalid number of passes: ''%s''', [ArgumentText(Value)]);
      OptionSize:
        begin
          if not ParseSize(Value, ByteCount) then
            Fail(1, 'invalid file size: ''%s''', [ArgumentText(Value)]);
          Size := Int64(ByteCount);
        end;
      OptionRemove: Remove := True;
      OptionVerbose: Verbose := True;
      OptionExact: Exact := True;
      OptionZero: FinalZero := True;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);

  SetLength(Buffer, BufferSize);
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
    if not ShredFile(Parser.Operands[Index]) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.

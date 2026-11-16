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
  gzip - compress or decompress files (RFC 1952, through libcompression)

  gzip [-cdfk] [-1..-9] [FILE...]

  Each FILE is replaced by FILE.gz (or, with -d, FILE.gz by FILE) unless
  -k keeps it or -c writes to standard output instead. With no FILE,
  or "-", standard input goes to standard output. The original name is
  kept in the header; several members in one file decompress as one.
}
program gzip;

{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  Compression.Errors,
  Compression.Formats,
  Compression.GzipFormat,
  Compression.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Paths;

const
  Usage = 'Usage: gzip [OPTION]... [FILE]...'#10 +
    'Compress or decompress FILEs (by default, compress FILES in-place).'#10 +
    #10 +
    '  -c, --stdout      write on standard output, keep original files unchanged'#10 +
    '  -d, --decompress  decompress'#10 +
    '  -f, --force       overwrite existing output files'#10 +
    '  -k, --keep        keep (don''t delete) input files'#10 +
    '  -1, --fast        compress faster'#10 +
    '  -9, --best        compress better'#10 +
    #10 +
    'With no FILE, or when FILE is -, read standard input.'#10;

  OptionStandardOutput = 100;
  OptionDecompress = 101;
  OptionForce = 102;
  OptionKeep = 103;
  { Options 1 to 9 are the levels. }

  Suffix = '.gz';
  BufferSize = 65536;

var
  ToStandardOutput: Boolean = False;
  Decompressing: Boolean = False;
  Force: Boolean = False;
  Keep: Boolean = False;
  Level: Integer = CompressionLevelDefault;
  ExitStatus: Integer = 0;

procedure CopyStream(Source: TStream; Target: TStream);
var
  Buffer: array of Byte;
  Count: LongInt;
begin
  Buffer := nil;
  SetLength(Buffer, BufferSize);
  repeat
    Count := Source.Read(Buffer[0], Length(Buffer));
    if Count > 0 then
      Target.WriteBuffer(Buffer[0], Count);
  until Count = 0;
end;

procedure Compress(Source: TStream; Target: TStream; const OriginalName: string);
var
  Writer: TCompressionStream;
  Header: TGzipHeader;
begin
  Writer := TCompressionStream.Create(Target, FormatGzip, Level);
  try
    Header := Writer.Deflater.GzipHeader;
    Header.FileName := OriginalName;
    Writer.Deflater.GzipHeader := Header;
    CopyStream(Source, Writer);
    Writer.Finish;
  finally
    Writer.Free;
  end;
end;

procedure Decompress(Source: TStream; Target: TStream);
var
  Reader: TDecompressionStream;
begin
  Reader := TDecompressionStream.Create(Source, FormatGzip);
  try
    CopyStream(Reader, Target);
  finally
    Reader.Free;
  end;
end;

procedure Convert(Source: TStream; Target: TStream; const OriginalName: string);
begin
  if Decompressing then
    Decompress(Source, Target)
  else
    Compress(Source, Target, OriginalName);
end;

procedure ConvertStandardStreams;
var
  Source: THandleStream;
  Target: THandleStream;
begin
  Source := THandleStream.Create(StdInputHandle);
  Target := THandleStream.Create(StdOutputHandle);
  try
    try
      Convert(Source, Target, '');
    except
      on Failure: ECompressionError do
      begin
        Report('stdin: ' + Failure.Message);
        ExitStatus := 1;
      end;
    end;
  finally
    Target.Free;
    Source.Free;
  end;
end;

function OutputNameFor(const Name: string; out OutputName: string): Boolean;
begin
  Result := True;
  if not Decompressing then
    OutputName := Name + Suffix
  else if (Length(Name) > Length(Suffix)) and (Copy(Name, Length(Name) - Length(Suffix) + 1, Length(Suffix)) = Suffix)
  then
    OutputName := Copy(Name, 1, Length(Name) - Length(Suffix))
  else
  begin
    Report(Name + ': unknown suffix -- ignored');
    Result := False;
  end;
end;

procedure ConvertFile(const Name: string);
var
  OutputName: string;
  Source: TFileStream;
  Target: TStream;
  Succeeded: Boolean;
begin
  if Name = '-' then
  begin
    ConvertStandardStreams;
    Exit;
  end;
  if DirectoryExists(Name) then
  begin
    Report(Name + ' is a directory -- ignored');
    ExitStatus := 1;
    Exit;
  end;
  if not ToStandardOutput and not OutputNameFor(Name, OutputName) then
  begin
    ExitStatus := 1;
    Exit;
  end;
  if not ToStandardOutput and FileExists(OutputName) and not Force then
  begin
    Report(OutputName + ' already exists');
    ExitStatus := 1;
    Exit;
  end;
  try
    Source := TFileStream.Create(Name, fmOpenRead);
  except
    on Failure: EStreamError do
    begin
      Report(Name + ': ' + Failure.Message);
      ExitStatus := 1;
      Exit;
    end;
  end;
  Succeeded := False;
  Target := nil;
  try
    try
      if ToStandardOutput then
        Target := THandleStream.Create(StdOutputHandle)
      else
        Target := TFileStream.Create(OutputName, fmCreate);
      Convert(Source, Target, BaseName(Name));
      Succeeded := True;
    except
      on Failure: Exception do
      begin
        Report(Name + ': ' + Failure.Message);
        ExitStatus := 1;
      end;
    end;
  finally
    Target.Free;
    Source.Free;
  end;
  if ToStandardOutput then
    Exit;
  if not Succeeded then
    DeleteFile(OutputName)
  else if not Keep then
    DeleteFile(Name);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'stdout', False, OptionStandardOutput),
    CommandOption('d', 'decompress', False, OptionDecompress),
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('k', 'keep', False, OptionKeep),
    CommandOption('1', 'fast', False, 1),
    CommandOption('2', '', False, 2),
    CommandOption('3', '', False, 3),
    CommandOption('4', '', False, 4),
    CommandOption('5', '', False, 5),
    CommandOption('6', '', False, 6),
    CommandOption('7', '', False, 7),
    CommandOption('8', '', False, 8),
    CommandOption('9', 'best', False, 9)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionStandardOutput: ToStandardOutput := True;
      OptionDecompress: Decompressing := True;
      OptionForce: Force := True;
      OptionKeep: Keep := True;
      1..9: Level := Code;
    end;
  if CommandLine.OperandCount = 0 then
    ConvertStandardStreams
  else
    for Operand in CommandLine.Operands do
      ConvertFile(Operand);
  CommandLine.Free;
  Halt(ExitStatus);
end.

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
  Writing zip files. Each member's data is streamed through deflate
  (libcompression) while its CRC-32 is computed, and the local header
  is written again with the sizes once they are known, so the output
  must be seekable. Data that deflate does not make smaller is written
  again stored (when the source can be read again). Names are UTF-8
  (flag 11), times go into the extended timestamp field as well as the
  DOS fields, modes into the external attributes ("made by" Unix).
  ZIP64 records are used when a size, an offset or the number of
  members needs them, or always with ForceZip64.
}
unit Archive.ZipWriter;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Entries,
  Archive.Progress;

type
  TZipWrittenMember = record
    Name: string;
    Flags: Word;
    Method: Word;
    DosDate, DosTime: Word;
    Crc32: LongWord;
    CompressedSize: QWord;
    UncompressedSize: QWord;
    LocalHeaderOffset: QWord;
    Mode: LongWord;
    ModificationTime: Int64;
    IsFolder: Boolean;
  end;

  TZipWriter = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FMembers: array of TZipWrittenMember;
    FCount: Integer;
    FForceZip64: Boolean;
    FCompressionLevel: Integer;
    FFinished: Boolean;
    FTruncateAtFinish: Boolean;
    procedure CheckOpen;
    procedure WriteBuilder(const Data: TBytes; Count: SizeInt);
    procedure AddMember(Source: TStream; const NameInArchive: string; ModificationTime: Int64;
      Mode: LongWord; IsFolder: Boolean; ExpectedSize: Int64; OnProgress: TArchiveProgressEvent);
    procedure WriteLocalHeader(const Member: TZipWrittenMember; Zip64: Boolean);
    procedure Deflate(Source: TStream; var Member: TZipWrittenMember; Progress: TProgressCounter);
    procedure Store(Source: TStream; var Member: TZipWrittenMember; Progress: TProgressCounter);
    procedure WriteCentralHeader(const Member: TZipWrittenMember);
    procedure WriteEndRecords(DirectoryOffset, DirectorySize: QWord);
  public
    { Creates (or replaces) the file. }
    constructor Create(const FileName: string);
    { Writes from the stream's position on; it must be seekable. }
    constructor Create(Stream: TStream; OwnsStream: Boolean = False);
    { Without Finish the file stays cut short (without its directory):
      the caller deletes it. }
    destructor Destroy; override;
    { A file's data, time and mode; a folder is added as AddFolder. }
    procedure AddFile(const SourcePath, NameInArchive: string; OnProgress: TArchiveProgressEvent = nil);
    { Source's data from its position to its end. Mode 0 means
      rw-r--r--; permission bits alone get the regular file type. }
    procedure AddStream(Source: TStream; const NameInArchive: string; ModificationTime: Int64; Mode: LongWord;
      OnProgress: TArchiveProgressEvent = nil);
    { A folder member (its name gets a final '/'); Mode 0 means
      rwxr-xr-x. }
    procedure AddFolder(const NameInArchive: string; ModificationTime: Int64; Mode: LongWord);
    { A symbolic link member: its data is the target. }
    procedure AddLink(const NameInArchive, Target: string; ModificationTime: Int64);
    { Writes the central directory and the end records. }
    procedure Finish;
    property Count: Integer read FCount;
    { ZIP64 records for every member and the end, whatever the sizes. }
    property ForceZip64: Boolean read FForceZip64 write FForceZip64;
    { Deflate level, 1 to 9 (0 stores everything). }
    property CompressionLevel: Integer read FCompressionLevel write FCompressionLevel;
  end;

implementation

uses
  Compression.Formats,
  Compression.Checksums,
  Compression.Deflater,
  Archive.Cp437,
  Archive.Times,
  Archive.FileSystem,
  Archive.ZipFormat;

const
  CopyBufferSize = 65536;
  { Members expected to be this large get ZIP64 local headers, leaving
    room for deflate making incompressible data a little larger. }
  Zip64SizeThreshold = QWord($FF000000);
  ExtendedTimestampFieldSize = 5;
  Zip64LocalFieldSize = 16;

constructor TZipWriter.Create(const FileName: string);
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(FileName, fmCreate);
  except
    on Error: Exception do
      raise EArchiveError.CreateFmt('Cannot create %s: %s', [FileName, Error.Message]);
  end;
  Create(Stream, True);
end;

constructor TZipWriter.Create(Stream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  FCompressionLevel := CompressionLevelDefault;
end;

destructor TZipWriter.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

procedure TZipWriter.CheckOpen;
begin
  if FFinished then
    raise EArchiveError.Create('The zip file is already finished');
end;

procedure TZipWriter.WriteBuilder(const Data: TBytes; Count: SizeInt);
begin
  if Count > 0 then
    FStream.WriteBuffer(Data[0], Count);
end;

function TimestampFits(ModificationTime: Int64): Boolean;
begin
  Result := (ModificationTime >= Low(LongInt)) and (ModificationTime <= High(LongInt));
end;

procedure TZipWriter.WriteLocalHeader(const Member: TZipWrittenMember; Zip64: Boolean);
var
  Header: TByteBuilder;
  ExtraLength: Word;
begin
  Header := Default(TByteBuilder);
  ExtraLength := 0;
  if Zip64 then
    Inc(ExtraLength, 4 + Zip64LocalFieldSize);
  if TimestampFits(Member.ModificationTime) then
    Inc(ExtraLength, 4 + ExtendedTimestampFieldSize);
  Header.AddLongWord(LocalHeaderSignature);
  if Zip64 then
    Header.AddWord(VersionZip64)
  else
    Header.AddWord(VersionDefault);
  Header.AddWord(Member.Flags);
  Header.AddWord(Member.Method);
  Header.AddWord(Member.DosTime);
  Header.AddWord(Member.DosDate);
  Header.AddLongWord(Member.Crc32);
  if Zip64 then
  begin
    Header.AddLongWord(LongWord(Max32));
    Header.AddLongWord(LongWord(Max32));
  end
  else
  begin
    Header.AddLongWord(LongWord(Member.CompressedSize));
    Header.AddLongWord(LongWord(Member.UncompressedSize));
  end;
  Header.AddWord(Length(Member.Name));
  Header.AddWord(ExtraLength);
  Header.AddText(Member.Name);
  if Zip64 then
  begin
    Header.AddWord(ExtraZip64);
    Header.AddWord(Zip64LocalFieldSize);
    Header.AddQWord(Member.UncompressedSize);
    Header.AddQWord(Member.CompressedSize);
  end;
  if TimestampFits(Member.ModificationTime) then
  begin
    Header.AddWord(ExtraExtendedTimestamp);
    Header.AddWord(ExtendedTimestampFieldSize);
    Header.AddByte(1);
    Header.AddLongWord(LongWord(LongInt(Member.ModificationTime)));
  end;
  WriteBuilder(Header.Data, Header.Length);
end;

procedure TZipWriter.Store(Source: TStream; var Member: TZipWrittenMember; Progress: TProgressCounter);
var
  Buffer: array of Byte;
  Got: LongInt;
begin
  Buffer := nil;
  SetLength(Buffer, CopyBufferSize);
  Member.Method := MethodStored;
  Member.Crc32 := Crc32Initial;
  Member.UncompressedSize := 0;
  repeat
    Got := Source.Read(Buffer[0], CopyBufferSize);
    if Got <= 0 then
      Break;
    Member.Crc32 := Crc32(Member.Crc32, @Buffer[0], Got);
    FStream.WriteBuffer(Buffer[0], Got);
    Inc(Member.UncompressedSize, Got);
    if Progress <> nil then
      Progress.Advance(Got);
  until False;
  Member.CompressedSize := Member.UncompressedSize;
end;

procedure TZipWriter.Deflate(Source: TStream; var Member: TZipWrittenMember; Progress: TProgressCounter);
var
  Deflater: TDeflater;
  Input, Output: array of Byte;
  Got: LongInt;
  Written: SizeInt;
  Outcome: TDeflateResult;
begin
  Input := nil;
  Output := nil;
  SetLength(Input, CopyBufferSize);
  SetLength(Output, CopyBufferSize);
  Member.Method := MethodDeflated;
  Member.Crc32 := Crc32Initial;
  Member.UncompressedSize := 0;
  Member.CompressedSize := 0;
  Deflater := TDeflater.Create(FormatRaw, FCompressionLevel);
  try
    repeat
      Got := Source.Read(Input[0], CopyBufferSize);
      if Got <= 0 then
        Break;
      Member.Crc32 := Crc32(Member.Crc32, @Input[0], Got);
      Inc(Member.UncompressedSize, Got);
      Deflater.SetInput(@Input[0], Got);
      repeat
        Outcome := Deflater.Compress(@Output[0], CopyBufferSize, Written, False);
        if Written > 0 then
        begin
          FStream.WriteBuffer(Output[0], Written);
          Inc(Member.CompressedSize, Written);
        end;
      until (Outcome = DeflateNeedsInput) and (Deflater.InputRemaining = 0);
      if Progress <> nil then
        Progress.Advance(Got);
    until False;
    repeat
      Outcome := Deflater.Compress(@Output[0], CopyBufferSize, Written, True);
      if Written > 0 then
      begin
        FStream.WriteBuffer(Output[0], Written);
        Inc(Member.CompressedSize, Written);
      end;
    until Outcome = DeflateFinished;
  finally
    Deflater.Free;
  end;
end;

{ Whether the stream can go back to Position (and went there). }
function Rewind(Source: TStream; Position: Int64): Boolean;
begin
  try
    Source.Position := Position;
    Result := Source.Position = Position;
  except
    Result := False;
  end;
end;

function CompleteMode(Mode: LongWord; IsFolder: Boolean): LongWord;
begin
  Result := Mode;
  if Result = 0 then
  begin
    if IsFolder then
      Result := ModeDefaultFolder
    else
      Result := ModeDefaultFile;
  end
  else if (Result and ModeTypeMask) = 0 then
  begin
    if IsFolder then
      Result := Result or ModeFolder
    else
      Result := Result or ModeRegularFile;
  end;
end;

procedure TZipWriter.AddMember(Source: TStream; const NameInArchive: string; ModificationTime: Int64;
  Mode: LongWord; IsFolder: Boolean; ExpectedSize: Int64; OnProgress: TArchiveProgressEvent);
var
  Member: TZipWrittenMember;
  LocalZip64: Boolean;
  DataStart, SourceStart, DataEnd: Int64;
  Progress: TProgressCounter;
begin
  CheckOpen;
  Member := Default(TZipWrittenMember);
  Member.Name := StringReplace(NameInArchive, '\', '/', [rfReplaceAll]);
  while Copy(Member.Name, 1, 1) = '/' do
    Delete(Member.Name, 1, 1);
  if IsFolder and not NameIsFolder(Member.Name) then
    Member.Name := Member.Name + '/';
  if (Member.Name = '') or (Length(Member.Name) > Max16) then
    raise EArchiveError.CreateFmt('"%s" cannot be a name in a zip file', [NameInArchive]);
  Member.IsFolder := IsFolder;
  Member.Mode := CompleteMode(Mode, IsFolder);
  Member.ModificationTime := ModificationTime;
  UnixToDosDateTime(ModificationTime, Member.DosDate, Member.DosTime);
  if not IsAscii(Member.Name) then
    Member.Flags := FlagUtf8;
  Member.Method := MethodStored;
  Member.LocalHeaderOffset := QWord(FStream.Position);
  LocalZip64 := FForceZip64 or (ExpectedSize < 0) or (QWord(ExpectedSize) >= Zip64SizeThreshold);

  WriteLocalHeader(Member, LocalZip64);
  DataStart := FStream.Position;
  if Source <> nil then
  begin
    Progress := TProgressCounter.Create(OnProgress);
    try
      SourceStart := Source.Position;
      if (FCompressionLevel <= CompressionLevelStore) or (ExpectedSize = 0) then
        Store(Source, Member, Progress)
      else
      begin
        Deflate(Source, Member, Progress);
        if (Member.CompressedSize >= Member.UncompressedSize) and Rewind(Source, SourceStart) then
        begin
          FStream.Position := DataStart;
          Store(Source, Member, nil);
          FTruncateAtFinish := True;
        end;
      end;
    finally
      Progress.Free;
    end;
  end;
  DataEnd := FStream.Position;
  if not LocalZip64 and ((Member.CompressedSize >= Max32) or (Member.UncompressedSize >= Max32)) then
    raise EArchiveError.CreateFmt('%s grew past 4 GiB while it was added', [NameInArchive]);

  FStream.Position := Int64(Member.LocalHeaderOffset);
  WriteLocalHeader(Member, LocalZip64);
  FStream.Position := DataEnd;

  if FCount >= Length(FMembers) then
    SetLength(FMembers, 2 * FCount + 16);
  FMembers[FCount] := Member;
  Inc(FCount);
end;

procedure TZipWriter.AddStream(Source: TStream; const NameInArchive: string; ModificationTime: Int64;
  Mode: LongWord; OnProgress: TArchiveProgressEvent);
var
  ExpectedSize: Int64;
begin
  try
    ExpectedSize := Source.Size - Source.Position;
  except
    ExpectedSize := -1;
  end;
  AddMember(Source, NameInArchive, ModificationTime, Mode, False, ExpectedSize, OnProgress);
end;

procedure TZipWriter.AddFile(const SourcePath, NameInArchive: string; OnProgress: TArchiveProgressEvent);
var
  ModificationTime: Int64;
  Mode: LongWord;
  Source: TFileStream;
begin
  if not GetPathDetails(SourcePath, ModificationTime, Mode) then
    raise EArchiveError.CreateFmt('Cannot read %s', [SourcePath]);
  if (Mode and ModeTypeMask) = ModeFolder then
  begin
    AddFolder(NameInArchive, ModificationTime, Mode);
    Exit;
  end;
  try
    Source := TFileStream.Create(SourcePath, fmOpenRead or fmShareDenyNone);
  except
    on Error: Exception do
      raise EArchiveError.CreateFmt('Cannot read %s: %s', [SourcePath, Error.Message]);
  end;
  try
    AddMember(Source, NameInArchive, ModificationTime, (Mode and not ModeTypeMask) or ModeRegularFile, False,
      Source.Size, OnProgress);
  finally
    Source.Free;
  end;
end;

procedure TZipWriter.AddFolder(const NameInArchive: string; ModificationTime: Int64; Mode: LongWord);
begin
  AddMember(nil, NameInArchive, ModificationTime, Mode, True, 0, nil);
end;

procedure TZipWriter.AddLink(const NameInArchive, Target: string; ModificationTime: Int64);
var
  Source: TStringStream;
begin
  Source := TStringStream.Create(Target);
  try
    AddMember(Source, NameInArchive, ModificationTime, ModeDefaultLink, False, Length(Target), nil);
  finally
    Source.Free;
  end;
end;

procedure TZipWriter.WriteCentralHeader(const Member: TZipWrittenMember);
var
  Header, Zip64Field: TByteBuilder;
  CompressedField, UncompressedField, OffsetField: LongWord;
  ExtraLength: Word;
  Version: Word;
  ExternalAttributes: LongWord;
begin
  Header := Default(TByteBuilder);
  Zip64Field := Default(TByteBuilder);
  UncompressedField := LongWord(Member.UncompressedSize and Max32);
  CompressedField := LongWord(Member.CompressedSize and Max32);
  OffsetField := LongWord(Member.LocalHeaderOffset and Max32);
  if FForceZip64 or (Member.UncompressedSize >= Max32) then
  begin
    UncompressedField := LongWord(Max32);
    Zip64Field.AddQWord(Member.UncompressedSize);
  end;
  if FForceZip64 or (Member.CompressedSize >= Max32) then
  begin
    CompressedField := LongWord(Max32);
    Zip64Field.AddQWord(Member.CompressedSize);
  end;
  if FForceZip64 or (Member.LocalHeaderOffset >= Max32) then
  begin
    OffsetField := LongWord(Max32);
    Zip64Field.AddQWord(Member.LocalHeaderOffset);
  end;
  ExtraLength := 0;
  if Zip64Field.Length > 0 then
  begin
    Inc(ExtraLength, 4 + Zip64Field.Length);
    Version := VersionZip64;
  end
  else
    Version := VersionDefault;
  if TimestampFits(Member.ModificationTime) then
    Inc(ExtraLength, 4 + ExtendedTimestampFieldSize);
  ExternalAttributes := Member.Mode shl 16;
  if Member.IsFolder then
    ExternalAttributes := ExternalAttributes or DosFolderAttribute;

  Header.AddLongWord(CentralHeaderSignature);
  Header.AddWord((MadeByUnix shl 8) or VersionZip64);
  Header.AddWord(Version);
  Header.AddWord(Member.Flags);
  Header.AddWord(Member.Method);
  Header.AddWord(Member.DosTime);
  Header.AddWord(Member.DosDate);
  Header.AddLongWord(Member.Crc32);
  Header.AddLongWord(CompressedField);
  Header.AddLongWord(UncompressedField);
  Header.AddWord(Length(Member.Name));
  Header.AddWord(ExtraLength);
  Header.AddWord(0);  { comment }
  Header.AddWord(0);  { disk }
  Header.AddWord(0);  { internal attributes }
  Header.AddLongWord(ExternalAttributes);
  Header.AddLongWord(OffsetField);
  Header.AddText(Member.Name);
  if Zip64Field.Length > 0 then
  begin
    Header.AddWord(ExtraZip64);
    Header.AddWord(Zip64Field.Length);
    Header.AddBytes(Zip64Field.Data, Zip64Field.Length);
  end;
  if TimestampFits(Member.ModificationTime) then
  begin
    Header.AddWord(ExtraExtendedTimestamp);
    Header.AddWord(ExtendedTimestampFieldSize);
    Header.AddByte(1);
    Header.AddLongWord(LongWord(LongInt(Member.ModificationTime)));
  end;
  WriteBuilder(Header.Data, Header.Length);
end;

function Clamp16(Value: QWord): Word;
begin
  if Value >= Max16 then
    Result := Max16
  else
    Result := Word(Value);
end;

function Clamp32(Value: QWord): LongWord;
begin
  if Value >= Max32 then
    Result := LongWord(Max32)
  else
    Result := LongWord(Value);
end;

procedure TZipWriter.WriteEndRecords(DirectoryOffset, DirectorySize: QWord);
var
  Records: TByteBuilder;
  Zip64RecordOffset: QWord;
begin
  Records := Default(TByteBuilder);
  if FForceZip64 or (FCount >= Max16) or (DirectoryOffset >= Max32) or (DirectorySize >= Max32) then
  begin
    Zip64RecordOffset := QWord(FStream.Position);
    Records.AddLongWord(Zip64EndOfCentralDirectorySignature);
    Records.AddQWord(Zip64EndOfCentralDirectorySize - 12);
    Records.AddWord((MadeByUnix shl 8) or VersionZip64);
    Records.AddWord(VersionZip64);
    Records.AddLongWord(0);
    Records.AddLongWord(0);
    Records.AddQWord(QWord(FCount));
    Records.AddQWord(QWord(FCount));
    Records.AddQWord(DirectorySize);
    Records.AddQWord(DirectoryOffset);
    Records.AddLongWord(Zip64EndLocatorSignature);
    Records.AddLongWord(0);
    Records.AddQWord(Zip64RecordOffset);
    Records.AddLongWord(1);
  end;
  Records.AddLongWord(EndOfCentralDirectorySignature);
  Records.AddWord(0);
  Records.AddWord(0);
  Records.AddWord(Clamp16(QWord(FCount)));
  Records.AddWord(Clamp16(QWord(FCount)));
  Records.AddLongWord(Clamp32(DirectorySize));
  Records.AddLongWord(Clamp32(DirectoryOffset));
  Records.AddWord(0);
  WriteBuilder(Records.Data, Records.Length);
end;

procedure TZipWriter.Finish;
var
  DirectoryOffset: QWord;
  Index: Integer;
begin
  CheckOpen;
  DirectoryOffset := QWord(FStream.Position);
  for Index := 0 to FCount - 1 do
    WriteCentralHeader(FMembers[Index]);
  WriteEndRecords(DirectoryOffset, QWord(FStream.Position) - DirectoryOffset);
  if FTruncateAtFinish then
    FStream.Size := FStream.Position;
  FFinished := True;
end;

end.

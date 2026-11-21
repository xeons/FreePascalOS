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
  Reading zip files: the members are listed from the central directory
  (ZIP64 included), so local headers and data descriptors only matter
  for finding where a member's data starts. Stored and deflated data
  is extracted and checked against its CRC-32 and size.
}
unit Archive.ZipReader;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Entries,
  Archive.Progress,
  Archive.Readers;

type
  TZipMemberLocation = record
    LocalHeaderOffset: QWord;
    Flags: Word;
  end;

  TZipReader = class(TArchiveReader)
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FLocations: array of TZipMemberLocation;
    procedure ReadCentralDirectory;
    procedure ReadLinkTargets;
    function DataStart(Index: Integer): Int64;
    procedure CopyStored(Index: Integer; Destination: TStream; Progress: TProgressCounter; out Crc: LongWord;
      out Written: QWord);
    procedure Inflate(Index: Integer; Destination: TStream; Progress: TProgressCounter; out Crc: LongWord;
      out Written: QWord);
  protected
    procedure WriteEntryData(Index: Integer; Destination: TStream; Progress: TProgressCounter); override;
  public
    constructor Create(const FileName: string);
    constructor Create(Stream: TStream; OwnsStream: Boolean = False);
    destructor Destroy; override;
  end;

implementation

uses
  Compression.Errors,
  Compression.Formats,
  Compression.Checksums,
  Compression.Inflater,
  Archive.Cp437,
  Archive.Times,
  Archive.ZipFormat,
  Archive.ZipEndRecord,
  Archive.ZipExtraFields;

const
  CopyBufferSize = 65536;
  { Link targets longer than this are not read when listing. }
  LongestLinkTarget = 4096;

constructor TZipReader.Create(const FileName: string);
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    on Error: Exception do
      raise EArchiveError.CreateFmt('Cannot open %s: %s', [FileName, Error.Message]);
  end;
  Create(Stream, True);
end;

constructor TZipReader.Create(Stream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FFormat := ArchiveZip;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  ReadCentralDirectory;
  ReadLinkTargets;
end;

destructor TZipReader.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

function RawText(const Data: TBytes; Offset, Count: SizeInt): string;
begin
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(Data[Offset], Result[1], Count);
end;

{ The offset the stored offsets are off by: what comes before the zip
  (a self-extracting program), found where the directory really is. }
function PrefixLength(Stream: TStream; const ZipEnd: TZipEnd): Int64;
var
  DirectoryEnd, Expected: Int64;
  Signature: LongWord;
begin
  Result := 0;
  if ZipEnd.IsZip64 then
    DirectoryEnd := ZipEnd.Zip64RecordPosition
  else
    DirectoryEnd := ZipEnd.EndRecordPosition;
  Expected := DirectoryEnd - Int64(ZipEnd.DirectorySize);
  if (Expected <= Int64(ZipEnd.DirectoryOffset)) or (ZipEnd.EntryCount = 0) then
    Exit;
  Signature := 0;
  Stream.Position := Int64(ZipEnd.DirectoryOffset);
  if (Stream.Read(Signature, 4) = 4) and (LEtoN(Signature) = CentralHeaderSignature) then
    Exit;
  Result := Expected - Int64(ZipEnd.DirectoryOffset);
end;

procedure TZipReader.ReadCentralDirectory;
var
  ZipEnd: TZipEnd;
  Directory: TBytes;
  Prefix: Int64;
  Position: SizeInt;
  EntryNumber: QWord;
  NameLength, ExtraLength, CommentLength, Flags, MadeBy: Word;
  ExternalAttributes: LongWord;
  RawName: string;
  Values: TZip64Values;
  Info: TZipExtraInfo;
  Entry: TArchiveEntry;
  Location: TZipMemberLocation;
begin
  if not FindZipEnd(FStream, ZipEnd) then
    raise EArchiveError.Create('Not a zip file (no end of central directory record)');
  Prefix := PrefixLength(FStream, ZipEnd);
  if ZipEnd.DirectorySize > QWord(FStream.Size) then
    raise EArchiveError.Create('Damaged zip file (central directory size)');
  Directory := nil;
  SetLength(Directory, ZipEnd.DirectorySize);
  FStream.Position := Int64(ZipEnd.DirectoryOffset) + Prefix;
  if (ZipEnd.DirectorySize > 0) and
    (FStream.Read(Directory[0], ZipEnd.DirectorySize) <> Int64(ZipEnd.DirectorySize)) then
    raise EArchiveError.Create('Damaged zip file (central directory cut short)');
  if ZipEnd.EntryCount > ZipEnd.DirectorySize div CentralHeaderSize then
    raise EArchiveError.Create('Damaged zip file (entry count)');
  SetLength(FLocations, ZipEnd.EntryCount);
  Position := 0;
  EntryNumber := 0;
  while EntryNumber < ZipEnd.EntryCount do
  begin
    if (Position + CentralHeaderSize > Length(Directory)) or
      (ReadLongWord(Directory, Position) <> CentralHeaderSignature) then
      raise EArchiveError.Create('Damaged zip file (central directory header)');
    MadeBy := ReadWord(Directory, Position + 4);
    Flags := ReadWord(Directory, Position + 8);
    NameLength := ReadWord(Directory, Position + 28);
    ExtraLength := ReadWord(Directory, Position + 30);
    CommentLength := ReadWord(Directory, Position + 32);
    if Position + CentralHeaderSize + NameLength + ExtraLength + CommentLength > Length(Directory) then
      raise EArchiveError.Create('Damaged zip file (central directory header)');
    ExternalAttributes := ReadLongWord(Directory, Position + 38);
    Values.CompressedSize := ReadLongWord(Directory, Position + 20);
    Values.UncompressedSize := ReadLongWord(Directory, Position + 24);
    Values.LocalHeaderOffset := ReadLongWord(Directory, Position + 42);
    RawName := RawText(Directory, Position + CentralHeaderSize, NameLength);
    ReadExtraFields(Directory, Position + CentralHeaderSize + NameLength, ExtraLength, RawName, Values, Info);

    Entry := Default(TArchiveEntry);
    if (Flags and FlagUtf8) <> 0 then
      Entry.Name := RawName
    else if Info.HasUnicodePath then
      Entry.Name := Info.UnicodePath
    else
      Entry.Name := Cp437ToUtf8(RawName);
    if (MadeBy shr 8) = MadeByDos then
      Entry.Name := StringReplace(Entry.Name, '\', '/', [rfReplaceAll]);
    Entry.Method := ReadWord(Directory, Position + 10);
    Entry.Crc32 := ReadLongWord(Directory, Position + 16);
    Entry.Size := Values.UncompressedSize;
    Entry.CompressedSize := Values.CompressedSize;
    if Info.HasModificationTime then
      Entry.ModificationTime := Info.ModificationTime
    else
      Entry.ModificationTime := DosDateTimeToUnix(ReadWord(Directory, Position + 14),
        ReadWord(Directory, Position + 12));
    if (MadeBy shr 8) = MadeByUnix then
      Entry.Mode := ExternalAttributes shr 16;
    Entry.IsFolder := NameIsFolder(Entry.Name) or ((Entry.Mode and ModeTypeMask) = ModeFolder) or
      (((Entry.Mode and ModeTypeMask) = 0) and ((ExternalAttributes and DosFolderAttribute) <> 0));
    if Entry.IsFolder and not NameIsFolder(Entry.Name) then
      Entry.Name := Entry.Name + '/';
    Entry.IsLink := not Entry.IsFolder and ((Entry.Mode and ModeTypeMask) = ModeSymbolicLink);
    if (Entry.Mode <> 0) and ((Entry.Mode and ModeTypeMask) = 0) then
    begin
      if Entry.IsFolder then
        Entry.Mode := Entry.Mode or ModeFolder
      else
        Entry.Mode := Entry.Mode or ModeRegularFile;
    end;
    Entry.Encrypted := ((Flags and FlagEncrypted) <> 0) or (Entry.Method = MethodAesEncrypted);

    Location.LocalHeaderOffset := Values.LocalHeaderOffset + QWord(Prefix);
    Location.Flags := Flags;
    FLocations[EntryNumber] := Location;
    AddEntry(Entry);

    Inc(Position, CentralHeaderSize + NameLength + ExtraLength + CommentLength);
    Inc(EntryNumber);
  end;
end;

procedure TZipReader.ReadLinkTargets;
var
  Index: Integer;
  Target: TStringStream;
  Entry: TArchiveEntry;
begin
  for Index := 0 to Count - 1 do
  begin
    Entry := Entries[Index];
    if not Entry.IsLink or Entry.Encrypted or (Entry.Size > LongestLinkTarget) then
      Continue;
    Target := TStringStream.Create('');
    try
      try
        WriteEntryData(Index, Target, nil);
        SetEntryLinkTarget(Index, Target.DataString);
      except
        on EArchiveError do
          ;
      end;
    finally
      Target.Free;
    end;
  end;
end;

function TZipReader.DataStart(Index: Integer): Int64;
var
  Header: TBytes;
begin
  Header := nil;
  SetLength(Header, LocalHeaderSize);
  FStream.Position := Int64(FLocations[Index].LocalHeaderOffset);
  if (FStream.Read(Header[0], LocalHeaderSize) <> LocalHeaderSize) or
    (ReadLongWord(Header, 0) <> LocalHeaderSignature) then
    raise EArchiveError.CreateFmt('Damaged zip file (local header of %s)', [Entries[Index].Name]);
  Result := Int64(FLocations[Index].LocalHeaderOffset) + LocalHeaderSize + ReadWord(Header, 26) +
    ReadWord(Header, 28);
end;

procedure TZipReader.CopyStored(Index: Integer; Destination: TStream; Progress: TProgressCounter;
  out Crc: LongWord; out Written: QWord);
var
  Buffer: array of Byte;
  Remaining: QWord;
  Piece: Integer;
begin
  Buffer := nil;
  SetLength(Buffer, CopyBufferSize);
  Crc := Crc32Initial;
  Written := 0;
  Remaining := Entries[Index].CompressedSize;
  while Remaining > 0 do
  begin
    if Remaining > CopyBufferSize then
      Piece := CopyBufferSize
    else
      Piece := Integer(Remaining);
    if FStream.Read(Buffer[0], Piece) <> Piece then
      raise EArchiveError.CreateFmt('%s is cut short', [Entries[Index].Name]);
    Crc := Crc32(Crc, @Buffer[0], Piece);
    Destination.WriteBuffer(Buffer[0], Piece);
    Dec(Remaining, Piece);
    Inc(Written, Piece);
    if Progress <> nil then
      Progress.Advance(Piece);
  end;
end;

procedure TZipReader.Inflate(Index: Integer; Destination: TStream; Progress: TProgressCounter;
  out Crc: LongWord; out Written: QWord);
var
  Inflater: TInflater;
  Input, Output: array of Byte;
  Remaining: QWord;
  Piece: Integer;
  Produced: SizeInt;
  Outcome: TInflateResult;
begin
  Input := nil;
  Output := nil;
  SetLength(Input, CopyBufferSize);
  SetLength(Output, CopyBufferSize);
  Crc := Crc32Initial;
  Written := 0;
  Remaining := Entries[Index].CompressedSize;
  Inflater := TInflater.Create(FormatRaw);
  try
    Outcome := InflateNeedsInput;
    while Outcome <> InflateFinished do
    begin
      if Outcome = InflateNeedsInput then
      begin
        if Remaining = 0 then
          raise EArchiveError.CreateFmt('%s is cut short', [Entries[Index].Name]);
        if Remaining > CopyBufferSize then
          Piece := CopyBufferSize
        else
          Piece := Integer(Remaining);
        if FStream.Read(Input[0], Piece) <> Piece then
          raise EArchiveError.CreateFmt('%s is cut short', [Entries[Index].Name]);
        Dec(Remaining, Piece);
        Inflater.SetInput(@Input[0], Piece);
      end;
      Outcome := Inflater.Decompress(@Output[0], CopyBufferSize, Produced);
      if Outcome = InflateFailed then
        raise EArchiveError.CreateFmt('%s is damaged: %s',
          [Entries[Index].Name, CompressionErrorMessage(Inflater.Error)]);
      if Produced > 0 then
      begin
        Crc := Crc32(Crc, @Output[0], Produced);
        Destination.WriteBuffer(Output[0], Produced);
        Inc(Written, Produced);
        if Progress <> nil then
          Progress.Advance(Produced);
      end;
    end;
  finally
    Inflater.Free;
  end;
end;

procedure TZipReader.WriteEntryData(Index: Integer; Destination: TStream; Progress: TProgressCounter);
var
  Entry: TArchiveEntry;
  Crc: LongWord;
  Written: QWord;
begin
  Entry := Entries[Index];
  if Entry.Encrypted then
    raise EArchiveError.CreateFmt('%s is encrypted; encrypted zip members cannot be extracted', [Entry.Name]);
  if (Entry.Method <> MethodStored) and (Entry.Method <> MethodDeflated) then
    raise EArchiveError.CreateFmt('%s is compressed with method %d, which is not supported',
      [Entry.Name, Entry.Method]);
  FStream.Position := DataStart(Index);
  if Entry.Method = MethodStored then
    CopyStored(Index, Destination, Progress, Crc, Written)
  else
    Inflate(Index, Destination, Progress, Crc, Written);
  if Written <> Entry.Size then
    raise EArchiveError.CreateFmt('%s has the wrong size (%d bytes, not %d)', [Entry.Name, Written, Entry.Size]);
  if Crc <> Entry.Crc32 then
    raise EArchiveError.CreateFmt('%s is damaged (CRC-32 mismatch)', [Entry.Name]);
end;

end.

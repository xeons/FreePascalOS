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
  Reading tar files, plain or gzip-compressed: ustar, GNU (long names
  and link names in 'L' and 'K' members) and old v7 headers, pax
  extended headers (path, linkpath, size, mtime). Regular files,
  folders and symbolic links are listed; a hard link is listed as a
  file with the data of the member it links to; devices and fifos are
  left out. The whole file is read once when it is opened to list it.
}
unit Archive.TarReader;

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
  TTarReader = class(TArchiveReader)
  private
    FData: TStream;
    FOwnsData: Boolean;
    { Where each member's data starts in the (decompressed) tar. }
    FDataOffsets: array of Int64;
    procedure ReadHeaders;
    function ReadMetadata(Position: Int64; Size: QWord): string;
    procedure AddMember(const Entry: TArchiveEntry; DataOffset: Int64);
  protected
    procedure WriteEntryData(Index: Integer; Destination: TStream; Progress: TProgressCounter); override;
  public
    constructor Create(const FileName: string; Gzipped: Boolean);
    constructor Create(Stream: TStream; Gzipped: Boolean; OwnsStream: Boolean = False);
    destructor Destroy; override;
  end;

implementation

uses
  Archive.TarFormat,
  Archive.RewindingStreams;

const
  CopyBufferSize = 65536;
  { Long names and pax headers larger than this are taken for damage. }
  LargestMetadata = 1024 * 1024;

constructor TTarReader.Create(const FileName: string; Gzipped: Boolean);
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    on Error: Exception do
      raise EArchiveError.CreateFmt('Cannot open %s: %s', [FileName, Error.Message]);
  end;
  Create(Stream, Gzipped, True);
end;

constructor TTarReader.Create(Stream: TStream; Gzipped: Boolean; OwnsStream: Boolean);
begin
  inherited Create;
  if Gzipped then
  begin
    FFormat := ArchiveTarGzip;
    FData := TRewindingGzipStream.Create(Stream, OwnsStream);
    FOwnsData := True;
  end
  else
  begin
    FFormat := ArchiveTar;
    FData := Stream;
    FOwnsData := OwnsStream;
  end;
  ReadHeaders;
end;

destructor TTarReader.Destroy;
begin
  if FOwnsData then
    FData.Free;
  inherited Destroy;
end;

function TTarReader.ReadMetadata(Position: Int64; Size: QWord): string;
begin
  Result := '';
  if Size > LargestMetadata then
    raise EArchiveError.Create('Damaged tar file (a long name or pax header is too large)');
  SetLength(Result, Size);
  if FData.Position <> Position then
    FData.Position := Position;
  if (Size > 0) and (FData.Read(Result[1], Size) <> LongInt(Size)) then
    raise EArchiveError.Create('The tar file is cut short');
  { GNU long names end with a NUL. }
  while (Length(Result) > 0) and (Result[Length(Result)] = #0) do
    SetLength(Result, Length(Result) - 1);
end;

procedure TTarReader.AddMember(const Entry: TArchiveEntry; DataOffset: Int64);
begin
  if Count >= Length(FDataOffsets) then
    SetLength(FDataOffsets, 2 * Count + 16);
  FDataOffsets[Count] := DataOffset;
  AddEntry(Entry);
end;

{ Without leading "./" and "/" (as GNU tar extracts them). }
function CleanMemberName(const Name: string): string;
begin
  Result := Name;
  while True do
    if Copy(Result, 1, 2) = './' then
      Delete(Result, 1, 2)
    else if Copy(Result, 1, 1) = '/' then
      Delete(Result, 1, 1)
    else
      Break;
end;

procedure TTarReader.ReadHeaders;
var
  Block: TTarBlock;
  Position, DataOffset, Number: Int64;
  DataSize: QWord;
  TypeFlag: Char;
  LongName, LongLink: string;
  HasLongName, HasLongLink: Boolean;
  Local, Global: TPaxRecords;
  Entry: TArchiveEntry;
  LinkedIndex: Integer;
begin
  Position := 0;
  HasLongName := False;
  HasLongLink := False;
  LongName := '';
  LongLink := '';
  Local := Default(TPaxRecords);
  Global := Default(TPaxRecords);
  while True do
  begin
    if FData.Position <> Position then
      FData.Position := Position;
    if FData.Read(Block, TarBlockSize) <> TarBlockSize then
      Break;
    if BlockIsZero(Block) then
      Break;
    if not TarChecksumIsValid(Block) then
      raise EArchiveError.Create('Damaged tar file (header checksum)');
    if not TarNumber(Block, TarSizeOffset, 12, Number) or (Number < 0) then
      raise EArchiveError.Create('Damaged tar file (member size)');
    DataSize := QWord(Number);
    TypeFlag := Chr(Block[TarTypeOffset]);
    DataOffset := Position + TarBlockSize;
    if (TypeFlag <> TarTypePaxHeader) and (TypeFlag <> TarTypePaxGlobalHeader) and Local.HasSize then
      DataSize := Local.Size;

    case TypeFlag of
      TarTypeGnuLongName:
        begin
          LongName := ReadMetadata(DataOffset, DataSize);
          HasLongName := True;
        end;
      TarTypeGnuLongLink:
        begin
          LongLink := ReadMetadata(DataOffset, DataSize);
          HasLongLink := True;
        end;
      TarTypePaxHeader:
        ParsePaxRecords(ReadMetadata(DataOffset, DataSize), Local);
      TarTypePaxGlobalHeader:
        ParsePaxRecords(ReadMetadata(DataOffset, DataSize), Global);
      '3', '4', '6', 'V':
        { Devices, fifos and volume labels: not extracted. }
        begin
          HasLongName := False;
          HasLongLink := False;
          Local := Default(TPaxRecords);
        end;
    else
      begin
        Entry := Default(TArchiveEntry);
        if Local.HasPath then
          Entry.Name := Local.Path
        else if HasLongName then
          Entry.Name := LongName
        else if Global.HasPath then
          Entry.Name := Global.Path
        else
          Entry.Name := TarHeaderName(Block);
        if Local.HasLinkPath then
          Entry.LinkTarget := Local.LinkPath
        else if HasLongLink then
          Entry.LinkTarget := LongLink
        else
          Entry.LinkTarget := TarText(Block, TarLinkNameOffset, TarLinkNameLength);
        if Local.HasModificationTime then
          Entry.ModificationTime := Local.ModificationTime
        else if Global.HasModificationTime then
          Entry.ModificationTime := Global.ModificationTime
        else if TarNumber(Block, TarModificationTimeOffset, 12, Number) then
          Entry.ModificationTime := Number;
        if TarNumber(Block, TarModeOffset, 8, Number) then
          Entry.Mode := LongWord(Number and $FFF);
        Entry.Name := CleanMemberName(Entry.Name);
        Entry.Method := 0;

        LinkedIndex := -1;
        if TypeFlag = TarTypeFolder then
          Entry.IsFolder := True
        else if TypeFlag = TarTypeSymbolicLink then
          Entry.IsLink := True
        else if TypeFlag = TarTypeHardLink then
          LinkedIndex := IndexOf(CleanMemberName(Entry.LinkTarget))
        else if (TypeFlag = TarTypeRegularOld) and NameIsFolder(Entry.Name) then
          Entry.IsFolder := True;

        if Entry.IsFolder then
        begin
          if not NameIsFolder(Entry.Name) then
            Entry.Name := Entry.Name + '/';
          Entry.Mode := Entry.Mode or ModeFolder;
          Entry.LinkTarget := '';
        end
        else if Entry.IsLink then
        begin
          Entry.Mode := Entry.Mode or ModeSymbolicLink;
          Entry.Size := Length(Entry.LinkTarget);
        end
        else
        begin
          Entry.Mode := Entry.Mode or ModeRegularFile;
          Entry.LinkTarget := '';
          Entry.Size := DataSize;
        end;
        Entry.CompressedSize := Entry.Size;

        if (Entry.Name <> '') and (Entry.Name <> '/') then
        begin
          if TypeFlag = TarTypeHardLink then
          begin
            if (LinkedIndex >= 0) and not Entries[LinkedIndex].IsFolder and not Entries[LinkedIndex].IsLink then
            begin
              Entry.Size := Entries[LinkedIndex].Size;
              Entry.CompressedSize := Entry.Size;
              AddMember(Entry, FDataOffsets[LinkedIndex]);
            end;
          end
          else
            AddMember(Entry, DataOffset);
        end;
        HasLongName := False;
        HasLongLink := False;
        Local := Default(TPaxRecords);
      end;
    end;
    { Hard links, links and folders have no data, whatever the size says. }
    if TypeFlag in [TarTypeHardLink, TarTypeSymbolicLink, TarTypeFolder] then
      DataSize := 0;
    Position := DataOffset + Int64(DataSize + TarPadding(DataSize));
  end;
end;

procedure TTarReader.WriteEntryData(Index: Integer; Destination: TStream; Progress: TProgressCounter);
var
  Entry: TArchiveEntry;
  Buffer: array of Byte;
  Remaining: QWord;
  Piece: LongInt;
begin
  Entry := Entries[Index];
  if Entry.IsLink then
  begin
    if Entry.LinkTarget <> '' then
      Destination.WriteBuffer(Entry.LinkTarget[1], Length(Entry.LinkTarget));
    if Progress <> nil then
      Progress.Advance(Length(Entry.LinkTarget));
    Exit;
  end;
  Buffer := nil;
  SetLength(Buffer, CopyBufferSize);
  if FData.Position <> FDataOffsets[Index] then
    FData.Position := FDataOffsets[Index];
  Remaining := Entry.Size;
  while Remaining > 0 do
  begin
    if Remaining > CopyBufferSize then
      Piece := CopyBufferSize
    else
      Piece := LongInt(Remaining);
    if FData.Read(Buffer[0], Piece) <> Piece then
      raise EArchiveError.CreateFmt('%s is cut short', [Entry.Name]);
    Destination.WriteBuffer(Buffer[0], Piece);
    Dec(Remaining, Piece);
    if Progress <> nil then
      Progress.Advance(Piece);
  end;
end;

end.

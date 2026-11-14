{
  Attributes and free space for FAT12, FAT16 and FAT32.

  FAT has no owners or permission bits: a mode without any write
  permission sets the read-only attribute, any other mode clears it, and
  changing the owner or group to anything but 0 is not supported. The
  modification time is kept to two seconds, the access time to the day.
}
unit FileSystem.Fat.Attributes;

{$mode objfpc}

interface

uses
  FileSystem.Types;

function FatSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
function FatGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;

implementation

uses
  Runtime.Time,
  FileSystem.Fat.Structures,
  FileSystem.Fat.Volume;

const
  AnyWritePermission = $92; { -w--w--w- }
  ModeReadOnly = $124;      { r--r--r-- }
  ModeWritable = $1A4;      { rw-r--r-- }

function FatSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
var
  FatNode: PFatNode;
  DirectoryRecord: TDirectoryRecord;
  DateWord: Word;
  TimeWord: Word;
begin
  FatNode := PFatNode(Node);
  if FatNode^.IsRoot then
    Exit(StatusUnsupported);
  if (((Changes.Fields and AttributeChangeOwner) <> 0) and (Changes.OwnerId <> 0)) or
     (((Changes.Fields and AttributeChangeGroup) <> 0) and (Changes.GroupId <> 0)) then
    Exit(StatusUnsupported);

  if not VolumeRead(Node^.Volume, FatNode^.EntryOffset, DirectoryEntrySize, @DirectoryRecord) then
    Exit(StatusIoError);

  if (Changes.Fields and AttributeChangeMode) <> 0 then
  begin
    if (Changes.Mode and AnyWritePermission) = 0 then
    begin
      DirectoryRecord.Attributes := DirectoryRecord.Attributes or AttributeReadOnly;
      Node^.Information.Mode := ModeReadOnly;
    end
    else
    begin
      DirectoryRecord.Attributes := DirectoryRecord.Attributes and not AttributeReadOnly;
      Node^.Information.Mode := ModeWritable;
    end;
    if Node^.Information.Kind = NodeKindDirectory then
      Node^.Information.Mode := Node^.Information.Mode or $49; { searchable }
  end;
  if (Changes.Fields and AttributeChangeModificationTime) <> 0 then
  begin
    UnixTimeToDosDateTime(Changes.ModificationTime, DateWord, TimeWord);
    DirectoryRecord.WriteDate := DateWord;
    DirectoryRecord.WriteTime := TimeWord;
    Node^.Information.ModificationTime := DosDateTimeToUnixTime(DateWord, TimeWord);
    Node^.Information.ChangeTime := Node^.Information.ModificationTime;
  end;
  if (Changes.Fields and AttributeChangeAccessTime) <> 0 then
  begin
    UnixTimeToDosDateTime(Changes.AccessTime, DateWord, TimeWord);
    DirectoryRecord.LastAccessDate := DateWord;
    Node^.Information.AccessTime := DosDateTimeToUnixTime(DateWord, 0);
  end;

  if not VolumeWrite(Node^.Volume, FatNode^.EntryOffset, DirectoryEntrySize, @DirectoryRecord) then
    Exit(StatusIoError);
  Result := StatusSuccess;
end;

function FatGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;
var
  Fat: PFatVolume;
begin
  FreeBytes := 0;
  Fat := PFatVolume(Volume^.DriverData);
  { Writable volumes keep the count up to date; read-only ones were never
    counted, and do not change, so count now. }
  if Volume^.IsReadOnly then
  begin
    Result := CountFreeClusters(Volume);
    if Result <> StatusSuccess then
      Exit;
  end;
  FreeBytes := QWord(Fat^.FreeClusterCount) * Fat^.BytesPerCluster;
  Result := StatusSuccess;
end;

end.

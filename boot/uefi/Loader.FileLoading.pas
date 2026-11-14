{
  Reads files from the volume the loader itself was started from.
}
unit Loader.FileLoading;

{$mode objfpc}

interface

uses
  Uefi.Base;

type
  TLoadedFile = record
    Contents: Pointer;
    SizeInBytes: QWord;
  end;

{ Reads an entire file into a temporary buffer. Path uses backslashes, for
  example '\FreePascalOS\kernel.elf'. }
function LoadFileFromBootVolume(Path: PChar; out LoadedFile: TLoadedFile): TEfiStatus;

procedure ReleaseLoadedFile(var LoadedFile: TLoadedFile);

implementation

uses
  Uefi.LoadedImage,
  Uefi.FileSystem,
  Loader.Firmware,
  Loader.Console,
  Loader.Memory;

const
  MaximumPathLength = 260;
  FileInformationBufferSize = 512;

function OpenBootVolumeRoot(out Root: PEfiFileProtocol): TEfiStatus;
var
  LoadedImage: PEfiLoadedImageProtocol;
  FileSystem: PEfiSimpleFileSystemProtocol;
begin
  Root := nil;

  Result := FirmwareBootServices^.HandleProtocol(LoaderImageHandle,
    @LoadedImageProtocolGuid, @LoadedImage);
  if EfiIsError(Result) then
    Exit;

  Result := FirmwareBootServices^.HandleProtocol(LoadedImage^.DeviceHandle,
    @SimpleFileSystemProtocolGuid, @FileSystem);
  if EfiIsError(Result) then
    Exit;

  Result := FileSystem^.OpenVolume(FileSystem, @Root);
end;

function QueryFileSize(FileHandle: PEfiFileProtocol; out SizeInBytes: QWord): TEfiStatus;
var
  InformationBuffer: array[0..FileInformationBufferSize - 1] of Byte;
  BufferSize: QWord;
begin
  SizeInBytes := 0;
  BufferSize := SizeOf(InformationBuffer);
  Result := FileHandle^.GetInfo(FileHandle, @FileInformationGuid, @BufferSize,
    @InformationBuffer[0]);
  if not EfiIsError(Result) then
    SizeInBytes := PEfiFileInformation(@InformationBuffer[0])^.FileSize;
end;

function LoadFileFromBootVolume(Path: PChar; out LoadedFile: TLoadedFile): TEfiStatus;
var
  WidePath: array[0..MaximumPathLength] of WideChar;
  Root: PEfiFileProtocol;
  FileHandle: PEfiFileProtocol;
  FileSize: QWord;
  BytesRead: QWord;
begin
  LoadedFile.Contents := nil;
  LoadedFile.SizeInBytes := 0;

  if not ConvertAsciiToUtf16(Path, @WidePath[0], Length(WidePath)) then
    Exit(EfiInvalidParameter);

  Result := OpenBootVolumeRoot(Root);
  if EfiIsError(Result) then
    Exit;

  Result := Root^.Open(Root, @FileHandle, @WidePath[0], EfiFileModeRead, 0);
  if EfiIsError(Result) then
  begin
    Root^.Close(Root);
    Exit;
  end;

  Result := QueryFileSize(FileHandle, FileSize);
  if not EfiIsError(Result) then
  begin
    LoadedFile.Contents := AllocateTemporaryBuffer(FileSize);
    if LoadedFile.Contents = nil then
      Result := EfiOutOfResources;
  end;

  if not EfiIsError(Result) then
  begin
    BytesRead := FileSize;
    Result := FileHandle^.Read(FileHandle, @BytesRead, LoadedFile.Contents);
    if (not EfiIsError(Result)) and (BytesRead <> FileSize) then
      Result := EfiLoadError;
  end;

  if EfiIsError(Result) then
    ReleaseLoadedFile(LoadedFile)
  else
    LoadedFile.SizeInBytes := FileSize;

  FileHandle^.Close(FileHandle);
  Root^.Close(Root);
end;

procedure ReleaseLoadedFile(var LoadedFile: TLoadedFile);
begin
  FreeTemporaryBuffer(LoadedFile.Contents);
  LoadedFile.Contents := nil;
  LoadedFile.SizeInBytes := 0;
end;

end.

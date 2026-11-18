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
    { Zero: a temporary buffer from the firmware's pool. Otherwise
      whole pages of this memory type, kept for the kernel. }
    MemoryType: LongWord;
  end;

const
  TemporaryFileMemory = 0;

{ Reads an entire file into a temporary buffer. Path uses backslashes, for
  example '\FreePascalOS\kernel.elf'. }
function LoadFileFromBootVolume(Path: PChar; out LoadedFile: TLoadedFile): TEfiStatus;

procedure ReleaseLoadedFile(var LoadedFile: TLoadedFile);

{ Gives LoadedFile room for SizeInBytes bytes: a temporary buffer, or
  pages of MemoryType. False if there is not enough memory. }
function AllocateLoadedFile(var LoadedFile: TLoadedFile; SizeInBytes: QWord;
  MemoryType: LongWord): Boolean;

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
  LoadedFile.MemoryType := TemporaryFileMemory;

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
  if (not EfiIsError(Result)) and not AllocateLoadedFile(LoadedFile, FileSize, TemporaryFileMemory) then
    Result := EfiOutOfResources;

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

function AllocateLoadedFile(var LoadedFile: TLoadedFile; SizeInBytes: QWord;
  MemoryType: LongWord): Boolean;
begin
  LoadedFile.MemoryType := MemoryType;
  LoadedFile.SizeInBytes := 0;
  if MemoryType = TemporaryFileMemory then
    LoadedFile.Contents := AllocateTemporaryBuffer(SizeInBytes)
  else
    LoadedFile.Contents := Pointer(AllocateLoaderPages(PagesNeededFor(SizeInBytes), MemoryType));
  Result := LoadedFile.Contents <> nil;
  if Result then
    LoadedFile.SizeInBytes := SizeInBytes;
end;

procedure ReleaseLoadedFile(var LoadedFile: TLoadedFile);
begin
  if LoadedFile.Contents <> nil then
  begin
    if LoadedFile.MemoryType = TemporaryFileMemory then
      FreeTemporaryBuffer(LoadedFile.Contents)
    else
      FirmwareBootServices^.FreePages(TEfiPhysicalAddress(LoadedFile.Contents),
        PagesNeededFor(LoadedFile.SizeInBytes));
  end;
  LoadedFile.Contents := nil;
  LoadedFile.SizeInBytes := 0;
end;

end.

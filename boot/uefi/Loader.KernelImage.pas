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
  Loads the kernel ELF executable into physical memory: the layout
  (Boot.KernelElf, shared with the native boot stub) in pages of the
  loader's kernel image memory type.
}
unit Loader.KernelImage;

{$mode objfpc}

interface

uses
  Uefi.Base,
  Boot.KernelElf,
  Loader.FileLoading;

type
  TKernelSegment = Boot.KernelElf.TKernelSegment;
  TLoadedKernelImage = Boot.KernelElf.TLoadedKernelImage;

function LoadKernelImage(const KernelFile: TLoadedFile; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TEfiStatus;

implementation

uses
  Loader.Console,
  Loader.Memory;

function LoadKernelImage(const KernelFile: TLoadedFile; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TEfiStatus;
var
  Status: TKernelElfStatus;
begin
  Status := MeasureKernelElf(KernelFile.Contents, KernelFile.SizeInBytes, ExpectedMachine, Image);
  if Status = KernelElfValid then
  begin
    Image.PhysicalBase := AllocateLoaderPages(Image.SizeInBytes div LoaderPageSize,
      LoaderMemoryTypeKernelImage);
    if Image.PhysicalBase = 0 then
      Exit(EfiOutOfResources);
    Status := CopyKernelElfSegments(KernelFile.Contents, Image);
  end;
  if Status <> KernelElfValid then
  begin
    PrintLine(KernelElfStatusText(Status));
    Exit(EfiLoadError);
  end;
  Result := EfiSuccess;
end;

end.

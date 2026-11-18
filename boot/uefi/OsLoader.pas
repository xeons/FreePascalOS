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
  FreePascalOS UEFI loader.

  Responsibilities, in order:
    1. Find the framebuffer and the ACPI tables.
    2. Read the options and the kernel executable from the boot volume,
       or from a server when booting from the network
       (Loader.NetworkBoot), and load the kernel; a network boot also
       reads the system volume's image into memory (the RAM disk).
    3. Allocate the boot information record and the kernel boot stack.
    4. Build the initial page tables.
    5. Capture the final memory map and exit boot services.
    6. Jump to the kernel.
}
program OsLoader;

{$mode objfpc}

uses
  Uefi.Base,
  Uefi.SystemTable,
  Uefi.TextOutput,
  Boot.Information,
  Boot.AddressLayout,
  Runtime.Memory,
  Loader.Firmware,
  Loader.Console,
  Loader.Memory,
  Loader.FileLoading,
  Loader.Options,
  Loader.NetworkBoot,
  Loader.KernelImage,
  Loader.Graphics,
  Loader.MemoryMap,
  Loader.Clock,
  Loader.Arch.PageTables,
  Loader.Arch.Handoff;

const
  KernelFilePath = '\FreePascalOS\kernel.elf';
  OptionsFilePath = '\FreePascalOS\options.txt';
  { The same files on a network boot server, and the system volume. }
  NetworkKernelPath = 'FreePascalOS/kernel.elf';
  NetworkOptionsPath = 'FreePascalOS/options.txt';
  NetworkSystemImagePath = 'FreePascalOS/system.img';
  BootStackSizeInBytes = 64 * 1024;
  FailureDisplayMicroseconds = 10 * 1000 * 1000;

function FindAcpiRootPointer: QWord;
var
  Table: Pointer;
begin
  Table := FindConfigurationTable(Acpi20TableGuid);
  if Table = nil then
    Table := FindConfigurationTable(Acpi10TableGuid);
  Result := QWord(Table);
end;

function MaximumOf(First, Second: QWord): QWord;
begin
  if First > Second then
    Result := First
  else
    Result := Second;
end;

{ The physical memory window must cover all RAM, the framebuffer, and at
  least the first 4 GiB where most memory mapped devices live. }
function DeterminePhysicalCoverage(const Framebuffer: TFramebufferInformation): QWord;
const
  OneGibibyte = QWord(1024) * 1024 * 1024;
var
  Coverage: QWord;
begin
  Coverage := MaximumOf(FindHighestMemoryAddress, MinimumPhysicalWindowCoverage);
  Coverage := MaximumOf(Coverage, Framebuffer.PhysicalBase + Framebuffer.SizeInBytes);
  Result := (Coverage + OneGibibyte - 1) and not (OneGibibyte - 1);
end;

{ Copies the options file of the boot volume (if there is one) into the
  command line. }
procedure LoadLocalOptions(var BootInformation: TBootInformation);
var
  OptionsFile: TLoadedFile;
begin
  BootInformation.CommandLine[0] := #0;
  if EfiIsError(LoadFileFromBootVolume(OptionsFilePath, OptionsFile)) then
    Exit;
  SetCommandLineFromFile(BootInformation, OptionsFile);
  ReleaseLoadedFile(OptionsFile);
end;

{ Starts a network boot if one is wanted: the server's options file
  (if it has one) replaces the boot volume's. False if the boot files
  come from the boot volume. }
function StartBootFromNetwork(var BootInformation: TBootInformation): Boolean;
var
  Status: TEfiStatus;
  OptionsFile: TLoadedFile;
begin
  Result := False;
  if not DetectNetworkBoot(@BootInformation.CommandLine[0]) then
    Exit;
  Status := StartNetworkBoot;
  if EfiIsError(Status) then
  begin
    PrintErrorAndStatus('no network for the network boot, using the boot volume', Status);
    Exit;
  end;

  Status := FetchNetworkBootFile(NetworkOptionsPath, TemporaryFileMemory, OptionsFile);
  if not EfiIsError(Status) then
  begin
    SetCommandLineFromFile(BootInformation, OptionsFile);
    ReleaseLoadedFile(OptionsFile);
  end
  else if Status <> EfiNotFound then
    PrintErrorAndStatus('could not read the server''s options.txt', Status);
  PutNetworkBootFirst(BootInformation, NetworkBootBaseUrl);
  Result := True;
end;

function LoadKernelFile(BootingFromNetwork: Boolean; out KernelFile: TLoadedFile): TEfiStatus;
begin
  if BootingFromNetwork then
  begin
    PrintText('Loading ');
    PrintText(NetworkBootBaseUrl);
    PrintLine(NetworkKernelPath);
    Result := FetchNetworkBootFile(NetworkKernelPath, TemporaryFileMemory, KernelFile);
    if not EfiIsError(Result) then
      Exit;
    PrintErrorAndStatus('could not read the kernel from the server, trying the boot volume', Result);
  end;
  PrintText('Loading ');
  PrintLine(KernelFilePath);
  Result := LoadFileFromBootVolume(KernelFilePath, KernelFile);
end;

{ A network boot's system volume: the server's system image, kept in
  memory as the RAM disk. Without one the kernel uses its disks. }
procedure LoadSystemImage(var BootInformation: TBootInformation);
var
  ImageFile: TLoadedFile;
  Status: TEfiStatus;
begin
  PrintText('Loading ');
  PrintText(NetworkBootBaseUrl);
  PrintLine(NetworkSystemImagePath);
  Status := FetchNetworkBootFile(NetworkSystemImagePath, LoaderMemoryTypeRamDisk, ImageFile);
  if Status = EfiNotFound then
  begin
    PrintLine('No system image on the server: the system volume comes from the disks');
    Exit;
  end;
  if EfiIsError(Status) then
  begin
    PrintErrorAndStatus('could not read the system image', Status);
    Exit;
  end;
  BootInformation.RamDiskPhysicalBase := QWord(ImageFile.Contents);
  BootInformation.RamDiskSizeInBytes := ImageFile.SizeInBytes;
  PrintText('RAM disk: ');
  PrintDecimal(ImageFile.SizeInBytes div 1024);
  PrintText(' KiB at physical ');
  PrintHexadecimal(BootInformation.RamDiskPhysicalBase);
  PrintLine('');
end;

procedure PrintBanner;
begin
  ClearConsole;
  SetConsoleColor(EfiTextColorLightCyan);
  PrintLine('FreePascalOS loader');
  SetConsoleColor(EfiTextColorLightGray);
  PrintLine('');
end;

function RunLoader: TEfiStatus;
var
  BootInformationAddress: QWord;
  BootInformation: PBootInformation;
  KernelFile: TLoadedFile;
  KernelImage: TLoadedKernelImage;
  BootingFromNetwork: Boolean;
  BootStackPhysicalBase: QWord;
  PhysicalCoverage: QWord;
  PageTableRoot: QWord;
  BootStackTopVirtual: QWord;
  BootInformationVirtual: QWord;
begin
  PrintBanner;

  { Without this the firmware resets the machine after five minutes. }
  FirmwareBootServices^.SetWatchdogTimer(0, 0, 0, nil);

  BootInformationAddress := AllocateLoaderPages(PagesNeededFor(SizeOf(TBootInformation)),
    LoaderMemoryTypeBootData);
  if BootInformationAddress = 0 then
  begin
    PrintErrorAndStatus('could not allocate boot information', EfiOutOfResources);
    Exit(EfiOutOfResources);
  end;
  BootInformation := PBootInformation(BootInformationAddress);
  BootInformation^.Signature := BootInformationSignature;
  BootInformation^.Version := BootInformationVersion;

  if DescribeFramebuffer(BootInformation^.Framebuffer) then
  begin
    PrintText('Framebuffer: ');
    PrintDecimal(BootInformation^.Framebuffer.Width);
    PrintText(' x ');
    PrintDecimal(BootInformation^.Framebuffer.Height);
    PrintText(' at ');
    PrintHexadecimal(BootInformation^.Framebuffer.PhysicalBase);
    PrintLine('');
  end
  else
    PrintLine('Framebuffer: none (serial output only)');

  BootInformation^.AcpiRootPointer := FindAcpiRootPointer;
  BootInformation^.FirmwareTime := ReadFirmwareTime;
  LoadLocalOptions(BootInformation^);
  BootingFromNetwork := StartBootFromNetwork(BootInformation^);
  if BootInformation^.CommandLine[0] <> #0 then
  begin
    PrintText('Kernel options: ');
    PrintLine(@BootInformation^.CommandLine[0]);
  end;

  Result := LoadKernelFile(BootingFromNetwork, KernelFile);
  if EfiIsError(Result) then
  begin
    PrintErrorAndStatus('could not read the kernel file', Result);
    Exit;
  end;

  Result := LoadKernelImage(KernelFile, KernelElfMachine, KernelImage);
  ReleaseLoadedFile(KernelFile);
  if EfiIsError(Result) then
  begin
    PrintErrorAndStatus('could not load the kernel image', Result);
    Exit;
  end;

  PrintText('Kernel image: ');
  PrintDecimal(KernelImage.SizeInBytes div 1024);
  PrintText(' KiB at physical ');
  PrintHexadecimal(KernelImage.PhysicalBase);
  PrintText(', entry ');
  PrintHexadecimal(KernelImage.EntryPoint);
  PrintLine('');

  BootInformation^.KernelImage.PhysicalBase := KernelImage.PhysicalBase;
  BootInformation^.KernelImage.VirtualBase := KernelImage.VirtualBase;
  BootInformation^.KernelImage.SizeInBytes := KernelImage.SizeInBytes;

  if BootingFromNetwork then
    LoadSystemImage(BootInformation^);

  BootStackPhysicalBase := AllocateLoaderPages(PagesNeededFor(BootStackSizeInBytes),
    LoaderMemoryTypeBootData);
  if BootStackPhysicalBase = 0 then
  begin
    PrintErrorAndStatus('could not allocate the kernel boot stack', EfiOutOfResources);
    Exit(EfiOutOfResources);
  end;
  BootInformation^.BootStackPhysicalBase := BootStackPhysicalBase;
  BootInformation^.BootStackSizeInBytes := BootStackSizeInBytes;

  PhysicalCoverage := DeterminePhysicalCoverage(BootInformation^.Framebuffer);
  PageTableRoot := BuildInitialPageTables(BootInformation^, PhysicalCoverage, KernelImage);
  if PageTableRoot = 0 then
  begin
    PrintErrorAndStatus('could not build the kernel page tables', EfiOutOfResources);
    Exit(EfiOutOfResources);
  end;
  BootInformation^.PageTableRoot := PageTableRoot;
  BootInformation^.PhysicalMemoryWindowBase := PhysicalMemoryWindowBase;

  PrintLine('Starting kernel...');

  Result := ExitBootServicesAndRecordMemoryMap(BootInformation^);
  if EfiIsError(Result) then
  begin
    PrintErrorAndStatus('could not exit boot services', Result);
    Exit;
  end;

  { From here on the firmware console is gone and nothing may fail. }
  BootStackTopVirtual := PhysicalMemoryWindowBase + BootStackPhysicalBase + BootStackSizeInBytes;
  BootInformationVirtual := PhysicalMemoryWindowBase + BootInformationAddress;
  TransferControlToKernel(PageTableRoot, BootStackTopVirtual, BootInformationVirtual,
    KernelImage.EntryPoint);

  Result := EfiLoadError;
end;

function EfiMain(ImageHandle: TEfiHandle; SystemTable: PEfiSystemTable): TEfiStatus;
  [public, alias: '_mainCRTStartup'];
begin
  InitializeFirmwareAccess(ImageHandle, SystemTable);
  Result := RunLoader;

  if EfiIsError(Result) then
  begin
    PrintLine('Returning to firmware in 10 seconds.');
    FirmwareBootServices^.Stall(FailureDisplayMicroseconds);
  end;
end;

begin
end.

{
  FreePascalOS UEFI loader.

  Responsibilities, in order:
    1. Find the framebuffer and the ACPI tables.
    2. Read the kernel executable from the boot volume and load it.
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
  Loader.KernelImage,
  Loader.Graphics,
  Loader.MemoryMap,
  Loader.Arch.PageTables,
  Loader.Arch.Handoff;

const
  KernelFilePath = '\FreePascalOS\kernel.elf';
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

  PrintText('Loading ');
  PrintLine(KernelFilePath);
  Result := LoadFileFromBootVolume(KernelFilePath, KernelFile);
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
  PageTableRoot := BuildInitialPageTables(PhysicalCoverage, KernelImage);
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

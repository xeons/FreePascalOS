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
  The native boot stub: what the UEFI loader does, for firmware that
  loads a kernel image directly and describes the machine with a device
  tree (a Raspberry Pi 5's EEPROM bootloader and firmware, QEMU's
  -kernel). NativeEntry.s relocated the image and calls NativeMain with
  the tree, MMU off. In order:

    1. Open the tree; the console UART (stdout-path) for messages.
    2. RAM from /memory, less the reservations; the stub's image, the
       tree and the initial RAM disk claimed (Native.MemoryMap).
    3. The boot information: the kernel options (/chosen bootargs), the
       framebuffer (a simple-framebuffer, or QEMU's ramfb), the RAM disk
       (/chosen linux,initrd-*, the system volume), a copy of the tree.
    4. The kernel ELF carried at the end of the image (KernelPayload.s)
       copied to its block, a boot stack, the translation tables
       (Native.PageTables) and the memory map.
    5. The hand-off the UEFI loader uses (LoaderHandoff.s): EL2 left for
       EL1 if need be, translation on, into the kernel with x0 = the boot
       information.
}
program NativeBoot;

{$mode objfpc}

uses
  Elf64,
  Runtime.Memory,
  Runtime.Text,
  Boot.Information,
  Boot.AddressLayout,
  Boot.KernelElf,
  DeviceTree.Blob,
  DeviceTree.Chosen,
  Native.Console,
  Native.MemoryMap,
  Native.PageTables,
  Native.QemuFramebuffer;

const
  BootStackSizeInBytes = 64 * 1024;

var
  { Filled here, copied into boot data pages last of all, so nothing is
    allocated before every claim (RAM disk, framebuffer) is known. }
  Information: TBootInformation;
  KernelPayloadStart: Byte; external name 'KernelPayloadStart';
  KernelPayloadEnd: Byte; external name 'KernelPayloadEnd';

procedure ArchEnterKernel(KernelRoot, IdentityRoot, StackTop, BootInformation, EntryPoint: QWord);
  external name 'ArchEnterKernel';

procedure Fail(Message: PChar);
begin
  PrintText('Native boot failed: ');
  PrintLine(Message);
end;

procedure PrintRange(Name: PChar; Start, Size: QWord);
begin
  PrintText(Name);
  PrintHexadecimal(Start);
  PrintText(', ');
  PrintDecimal(Size div 1024);
  PrintLine(' KiB');
end;

procedure SetCommandLine(var BootInformation: TBootInformation; constref Tree: TDeviceTree);
var
  Arguments: PChar;
begin
  BootInformation.CommandLine[0] := #0;
  Arguments := ReadBootArguments(Tree);
  if Arguments <> nil then
    CopyText(@BootInformation.CommandLine[0], Arguments, CommandLineCapacity);
end;

{ The firmware's screen, else QEMU's ramfb if there is one. }
procedure DescribeFramebuffer(var BootInformation: TBootInformation; constref Tree: TDeviceTree);
var
  Found: TDeviceTreeFramebuffer;
  Framebuffer: ^TFramebufferInformation;
begin
  Framebuffer := @BootInformation.Framebuffer;
  if FindSimpleFramebuffer(Tree, Found) then
  begin
    Framebuffer^.PhysicalBase := Found.PhysicalAddress;
    Framebuffer^.SizeInBytes := QWord(Found.StrideInBytes) * Found.Height;
    Framebuffer^.Width := Found.Width;
    Framebuffer^.Height := Found.Height;
    Framebuffer^.PixelsPerScanLine := Found.StrideInBytes div (Found.BitsPerPixel div 8);
    if Found.BitsPerPixel = 16 then
      Framebuffer^.PixelFormat := PixelFormatRedGreenBlue565
    else if Found.IsBlueGreenRed then
      Framebuffer^.PixelFormat := PixelFormatBlueGreenRed
    else
      Framebuffer^.PixelFormat := PixelFormatRedGreenBlue;
    { The kernel keeps it, wherever it is. }
    ClaimMemory(Framebuffer^.PhysicalBase, Framebuffer^.SizeInBytes, MemoryRegionReserved);
  end
  else if not SetUpQemuFramebuffer(Tree, Framebuffer^) then
  begin
    PrintLine('Framebuffer: none');
    Exit;
  end;
  PrintText('Framebuffer: ');
  PrintDecimal(Framebuffer^.Width);
  PrintText(' x ');
  PrintDecimal(Framebuffer^.Height);
  if Framebuffer^.PixelFormat = PixelFormatRedGreenBlue565 then
    PrintText(', 16 bits')
  else
    PrintText(', 32 bits');
  PrintText(' at ');
  PrintHexadecimal(Framebuffer^.PhysicalBase);
  PrintLine('');
end;

procedure DescribeRamDisk(var BootInformation: TBootInformation; constref Tree: TDeviceTree);
var
  StartAddress: QWord;
  EndAddress: QWord;
begin
  if not ReadInitrdRange(Tree, StartAddress, EndAddress) then
  begin
    PrintLine('RAM disk: none (the system volume comes from the disks)');
    Exit;
  end;
  ClaimMemory(StartAddress, EndAddress - StartAddress, MemoryRegionRamDisk);
  BootInformation.RamDiskPhysicalBase := StartAddress;
  BootInformation.RamDiskSizeInBytes := EndAddress - StartAddress;
  PrintRange('RAM disk: ', StartAddress, EndAddress - StartAddress);
end;

{ The tree, copied into boot data the kernel keeps. }
function CopyDeviceTree(var BootInformation: TBootInformation; constref Tree: TDeviceTree): Boolean;
var
  Copy: QWord;
begin
  Copy := AllocatePages(PagesFor(Tree.TotalSize), MemoryRegionBootData);
  if Copy = 0 then
    Exit(False);
  CopyMemory(Pointer(Copy), Tree.Base, Tree.TotalSize);
  BootInformation.DeviceTreePhysicalBase := Copy;
  BootInformation.DeviceTreeSizeInBytes := Tree.TotalSize;
  Result := True;
end;

function LoadKernel(out Image: TLoadedKernelImage): Boolean;
var
  Status: TKernelElfStatus;
  PayloadSize: QWord;
begin
  PayloadSize := QWord(@KernelPayloadEnd) - QWord(@KernelPayloadStart);
  Status := MeasureKernelElf(@KernelPayloadStart, PayloadSize, ElfMachineAarch64, Image);
  if Status = KernelElfValid then
  begin
    Image.PhysicalBase := AllocatePages(Image.SizeInBytes div NativePageSize, MemoryRegionKernelImage);
    if Image.PhysicalBase = 0 then
    begin
      Fail('no memory for the kernel image');
      Exit(False);
    end;
    Status := CopyKernelElfSegments(@KernelPayloadStart, Image);
  end;
  Result := Status = KernelElfValid;
  if not Result then
    Fail(KernelElfStatusText(Status));
end;

procedure RunNativeBoot(DeviceTreeAddress, ImageStart, ImageEnd: QWord);
var
  Tree: TDeviceTree;
  Uart: TDeviceTreeUart;
  InformationPages: PBootInformation;
  KernelImage: TLoadedKernelImage;
  BootStack: QWord;
  KernelRoot: QWord;
begin
  if not OpenDeviceTree(Pointer(DeviceTreeAddress), Tree) then
    Exit;
  if FindConsoleUart(Tree, Uart) then
    AttachConsole(Uart);
  PrintLine('');
  PrintLine('FreePascalOS native boot');
  PrintRange('Image: ', ImageStart, ImageEnd - ImageStart);
  PrintRange('Device tree: ', DeviceTreeAddress, Tree.TotalSize);

  if not InitializeMemoryMap(Tree) then
  begin
    Fail('the device tree describes no memory');
    Exit;
  end;
  PrintText('Memory: ');
  PrintDecimal(TotalMemoryBytes div (1024 * 1024));
  PrintLine(' MiB');
  ClaimMemory(ImageStart, ImageEnd - ImageStart, MemoryRegionBootOnly);
  ClaimMemory(DeviceTreeAddress, Tree.TotalSize, MemoryRegionBootOnly);

  ZeroMemory(@Information, SizeOf(Information));
  Information.Signature := BootInformationSignature;
  Information.Version := BootInformationVersion;
  SetCommandLine(Information, Tree);
  if Information.CommandLine[0] <> #0 then
  begin
    PrintText('Kernel options: ');
    PrintLine(@Information.CommandLine[0]);
  end;
  DescribeRamDisk(Information, Tree);
  DescribeFramebuffer(Information, Tree);
  if not CopyDeviceTree(Information, Tree) then
  begin
    Fail('no memory for the device tree');
    Exit;
  end;

  if not LoadKernel(KernelImage) then
    Exit;
  PrintRange('Kernel image: ', KernelImage.PhysicalBase, KernelImage.SizeInBytes);
  Information.KernelImage.PhysicalBase := KernelImage.PhysicalBase;
  Information.KernelImage.VirtualBase := KernelImage.VirtualBase;
  Information.KernelImage.SizeInBytes := KernelImage.SizeInBytes;

  BootStack := AllocatePages(PagesFor(BootStackSizeInBytes), MemoryRegionBootData);
  if BootStack = 0 then
  begin
    Fail('no memory for the boot stack');
    Exit;
  end;
  Information.BootStackPhysicalBase := BootStack;
  Information.BootStackSizeInBytes := BootStackSizeInBytes;

  KernelRoot := BuildNativePageTables(Information, KernelImage, Uart.PhysicalAddress);
  if KernelRoot = 0 then
  begin
    Fail('no memory for the translation tables');
    Exit;
  end;
  Information.PageTableRoot := KernelRoot;
  Information.PhysicalMemoryWindowBase := PhysicalMemoryWindowBase;
  Information.AcpiRootPointer := 0;
  InformationPages := PBootInformation(AllocatePages(PagesFor(SizeOf(TBootInformation)), MemoryRegionBootData));
  if InformationPages = nil then
  begin
    Fail('no memory for the boot information');
    Exit;
  end;
  ExportMemoryMap(Information);
  CopyMemory(InformationPages, @Information, SizeOf(Information));
  PrintText('Memory map: ');
  PrintDecimal(Information.MemoryRegionCount);
  PrintLine(' regions');

  PrintLine('Starting kernel...');
  ArchEnterKernel(KernelRoot, NativeIdentityRoot, PhysicalMemoryWindowBase + BootStack + BootStackSizeInBytes,
    PhysicalMemoryWindowBase + QWord(InformationPages), KernelImage.EntryPoint);
end;

procedure NativeMain(DeviceTreeAddress, ImageStart, ImageEnd: QWord); [public, alias: 'NativeMain'];
begin
  RunNativeBoot(DeviceTreeAddress, ImageStart, ImageEnd);
end;

begin
end.

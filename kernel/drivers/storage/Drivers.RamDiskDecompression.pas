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
  A compressed RAM disk image unpacked (Drivers.RamDisk).

  The boot loader passes the image as it got it: a Raspberry Pi's
  firmware fetches it over TFTP at a few hundred KiB/s and gives up
  after a minute, so the served system image is compressed (xz, or
  gzip). Its magic says which (Compression.MemoryImages); the format
  states the decompressed size (xz: its index, gzip: its trailer, or the
  ramdisksize=MIB option for a gzip image over 4 GiB), for which this
  allocates physically contiguous pages, decompresses into them,
  checking the format's CRC, and frees the compressed copy's pages.

  It runs in phase 1 with the caches on (the native boot stub runs with
  them off, which would make it many times slower), from the same
  decoders userland's libcompression has (userland/lib/compression,
  freestanding units).
}
unit Drivers.RamDiskDecompression;

{$mode objfpc}

interface

type
  TRamDiskImage = record
    PhysicalBase: QWord;
    SizeInBytes: QWord;
    { The boot memory map's RAM disk region around the image (its pages
      hold nothing else), zero if none was found. }
    RegionStart: QWord;
    RegionEnd: QWord;
  end;

{ If the image is compressed, replaces it with its decompressed copy
  and frees the compressed one. False if it is compressed but could not
  be decompressed (said in the log); the image is then unchanged. }
function ExpandRamDiskImage(var Image: TRamDiskImage): Boolean;

implementation

uses
  Compression.DecodeResults,
  Compression.MemoryImages,
  Memory.Layout,
  Memory.PhysicalPages,
  Kernel.Clock,
  Kernel.Options,
  Debug.Output;

const
  Mebibyte = QWord(1024 * 1024);
  { Room left for everything else after the decompressed image. }
  MinimumMemoryLeft = 64 * Mebibyte;

var
  { The decoders' state, about 40 KiB, used once at startup. }
  Workspace: TDecompressionWorkspace;

{ A size in MiB with one decimal ("4.6 MiB"). }
procedure WriteMebibytes(ByteCount: QWord);
var
  Tenths: QWord;
begin
  Tenths := (ByteCount * 10 + Mebibyte div 2) div Mebibyte;
  DebugWriteDecimal(Tenths div 10);
  DebugWriteCharacter('.');
  DebugWriteDecimal(Tenths mod 10);
  DebugWrite(' MiB');
end;

procedure ReportFailure(Kind: TCompressedImageKind; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('ramdisk');
  DebugWrite(CompressedImageKindName(Kind));
  DebugWrite(' image not unpacked: ');
  DebugWriteLine(Reason);
  DebugEndMessage;
end;

{ The decompressed size: the option's if given, else the image's. }
function FindExpandedSize(Kind: TCompressedImageKind; Contents: PByte; SizeInBytes: QWord;
  out ExpandedSize: QWord): Boolean;
var
  Outcome: TDecodeResult;
  OptionMebibytes: QWord;
begin
  Result := False;
  if GetKernelOptionNumber('ramdisksize', OptionMebibytes) and (OptionMebibytes > 0) then
    ExpandedSize := OptionMebibytes * Mebibyte
  else
  begin
    Outcome := CompressedImageSize(Kind, Contents, SizeInBytes, ExpandedSize);
    if Outcome <> DecodeSucceeded then
    begin
      ReportFailure(Kind, DecodeResultText(Outcome));
      Exit;
    end;
  end;
  if ExpandedSize = 0 then
  begin
    ReportFailure(Kind, 'it is empty');
    Exit;
  end;
  Result := True;
end;

function EnoughMemoryFor(ByteCount: QWord): Boolean;
var
  Statistics: TPhysicalMemoryStatistics;
begin
  GetPhysicalMemoryStatistics(Statistics);
  Result := ByteCount div PageSize + MinimumMemoryLeft div PageSize < Statistics.FreePages;
end;

{ The compressed copy's pages: those of the RAM disk region it is in. }
procedure FreeCompressedPages(const Image: TRamDiskImage);
var
  Page: QWord;
  Last: QWord;
begin
  if Image.RegionEnd <= Image.RegionStart then
    Exit;
  Page := Image.RegionStart;
  Last := Image.RegionEnd;
  while Page < Last do
  begin
    if PageUsageOf(Page) = PageUsageGeneral then
      FreePhysicalPage(Page);
    Inc(Page, PageSize);
  end;
end;

procedure ReportExpansion(Kind: TCompressedImageKind; CompressedSize: QWord; ExpandedSize: QWord;
  Nanoseconds: QWord);
begin
  DebugBeginMessage;
  DebugWriteTag('ramdisk');
  DebugWrite(CompressedImageKindName(Kind));
  DebugWrite(' image: compressed ');
  WriteMebibytes(CompressedSize);
  DebugWrite(' -> ');
  WriteMebibytes(ExpandedSize);
  DebugWrite(' in ');
  DebugWriteDecimal(Nanoseconds div 1000000);
  DebugWriteLine(' ms, checksum verified');
  DebugEndMessage;
end;

function ExpandRamDiskImage(var Image: TRamDiskImage): Boolean;
var
  Kind: TCompressedImageKind;
  Contents: PByte;
  ExpandedSize: QWord;
  PageCount: QWord;
  ExpandedBase: QWord;
  Started: QWord;
  Outcome: TDecodeResult;
  Page: QWord;
begin
  Contents := PByte(PhysicalToVirtual(Image.PhysicalBase));
  Kind := DetectCompressedImage(Contents, Image.SizeInBytes);
  if Kind = ImageNotCompressed then
    Exit(True);
  Result := False;
  if not FindExpandedSize(Kind, Contents, Image.SizeInBytes, ExpandedSize) then
    Exit;
  if not EnoughMemoryFor(ExpandedSize) then
  begin
    ReportFailure(Kind, 'not enough memory for the decompressed image');
    Exit;
  end;
  PageCount := (ExpandedSize + PageSize - 1) div PageSize;
  ExpandedBase := AllocateZeroedContiguousPhysicalPages(PageCount, High(QWord), PageUsageGeneral);
  if ExpandedBase = 0 then
  begin
    ReportFailure(Kind, 'no contiguous memory for the decompressed image');
    Exit;
  end;

  Started := ClockNanoseconds;
  Outcome := DecompressImage(Workspace, Kind, Contents, Image.SizeInBytes, PByte(PhysicalToVirtual(ExpandedBase)),
    ExpandedSize);
  if Outcome <> DecodeSucceeded then
  begin
    ReportFailure(Kind, DecodeResultText(Outcome));
    Page := 0;
    while Page < PageCount do
    begin
      FreePhysicalPage(ExpandedBase + Page * PageSize);
      Inc(Page);
    end;
    Exit;
  end;
  ReportExpansion(Kind, Image.SizeInBytes, ExpandedSize, ClockNanoseconds - Started);

  FreeCompressedPages(Image);
  Image.PhysicalBase := ExpandedBase;
  Image.SizeInBytes := ExpandedSize;
  Image.RegionStart := 0;
  Image.RegionEnd := 0;
  Result := True;
end;

end.

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
  The virtio GPU (virtio 1.x on PCI, 1AF4:1050), in 2D: each enabled
  scanout is a display of its own.

  The device has no video memory to draw in: a scanout shows a resource
  the host keeps, copied from guest memory. So each scanout gets a
  framebuffer of ordinary memory, physically contiguous and big enough
  for the largest mode offered (2560x1600, or less if that much cannot
  be found), which the program maps and draws in like any framebuffer;
  then it names the rectangles it drew (ControlDisplayFlush) and only
  those are copied to the host and shown (transfer to host, flush). The
  display says so (DisplayCapabilityNeedsFlush), so a program copies
  and flushes only what changed.

  Modes: the display information gives each scanout's preferred size
  (and whether it is enabled), the EDID (when the device offers it) the
  rest of the list and the physical size. Setting a mode makes a
  resource of that size on the same memory (lines of width times 4
  bytes), shows it on the scanout and drops the old one; the picture is
  cleared.

  The cursor (Drivers.VirtioGpuCursor) is the host's, from a 64 x 64
  resource on the display's cursor image page.

  A device whose memory holds the firmware's framebuffer (virtio-vga
  used through its VGA side) is left alone: the firmware's framebuffer
  is the console's display, as before. Without any virtio GPU nothing
  changes.

  Suspend to RAM: waking resets the device, so the queues are given
  again and every resource made again on the memory it had (which kept
  the picture), shown and flushed, and the cursor too.
}
unit Drivers.VirtioGpu;

{$mode objfpc}

interface

uses
  Boot.Information;

{ Registers a display for each enabled scanout of every virtio GPU but
  one holding Framebuffer; returns how many. }
function RegisterVirtioGpuDisplays(const Framebuffer: TFramebufferInformation): LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Io.Pci,
  Io.PowerManagement,
  Debug.Output,
  Drivers.Edid,
  Drivers.DisplayDevice,
  Drivers.VirtioPci,
  Drivers.VirtioGpuProtocol,
  Drivers.VirtioGpuQueues,
  Drivers.VirtioGpuResources,
  Drivers.VirtioGpuCursor;

const
  BytesPerPixel = 4;
  FallbackWidth = 1024;
  FallbackHeight = 768;
  MaximumScanoutsUsed = 8;
  PageBytes = 4096;
  AnyAddress = High(QWord);
  VgaFramebufferBar = 0;

type
  TFramebufferBudget = record
    Width: LongWord;
    Height: LongWord;
  end;

const
  { Tried in turn: the largest mode the framebuffer can hold. }
  Budgets: array[0..2] of TFramebufferBudget = (
    (Width: 2560; Height: 1600),
    (Width: 1920; Height: 1200),
    (Width: 1280; Height: 1024));

var
  Scanouts: array[0..MaximumScanoutsUsed - 1] of TGpuScanout;
  ScanoutCount: LongInt;

{ --- Showing ------------------------------------------------------------------- }

{ Makes a Width x Height resource on the scanout's memory and shows it,
  dropping the one it had. The batch is empty; the lock is held. }
function ShowNewResource(Scanout: PGpuScanout; Width, Height: LongWord): Boolean;
var
  Device: PGpuDevice;
  ResourceId: LongWord;
  OldResourceId: LongWord;
begin
  Device := Scanout^.Device;
  ResourceId := NewGpuResourceId(Device);
  OldResourceId := Scanout^.ResourceId;
  ZeroMemory(PhysicalToVirtual(Scanout^.FramebufferPhysical), QWord(Width) * Height * BytesPerPixel);
  Result := BeginCreateResource(Device, ResourceId, GpuFormatBlueGreenRedUnused, Width, Height) and
    BeginAttachBacking(Device, ResourceId, Scanout^.FramebufferPhysical, QWord(Width) * Height * BytesPerPixel) and
    BeginSetScanout(Device, Scanout^.Index, ResourceId, Width, Height) and
    BeginTransferToHost(Device, ResourceId, Width, 0, 0, Width, Height) and
    BeginFlushResource(Device, ResourceId, 0, 0, Width, Height) and
    RunGpuCommands(Device);
  if not Result then
    Exit;
  Scanout^.ResourceId := ResourceId;
  Scanout^.Width := Width;
  Scanout^.Height := Height;
  if OldResourceId <> 0 then
  begin
    BeginUnreferenceResource(Device, OldResourceId);
    RunGpuCommands(Device);
  end;
end;

function SetGpuMode(Adapter: PDisplayAdapter; Width, Height: LongWord; out Pitch: QWord): Boolean;
var
  Scanout: PGpuScanout;
begin
  Scanout := PGpuScanout(Adapter^.Context);
  Pitch := QWord(Width) * BytesPerPixel;
  if QWord(Width) * Height * BytesPerPixel > Scanout^.FramebufferBytes then
    Exit(False);
  AcquireMutex(Scanout^.Device^.Lock);
  Result := ShowNewResource(Scanout, Width, Height);
  ReleaseMutex(Scanout^.Device^.Lock);
end;

function FlushGpu(Adapter: PDisplayAdapter; X, Y, Width, Height: LongWord): Boolean;
var
  Scanout: PGpuScanout;
  Device: PGpuDevice;
begin
  Scanout := PGpuScanout(Adapter^.Context);
  Device := Scanout^.Device;
  AcquireMutex(Device^.Lock);
  Result := BeginTransferToHost(Device, Scanout^.ResourceId, Scanout^.Width, X, Y, Width, Height) and
    BeginFlushResource(Device, Scanout^.ResourceId, X, Y, Width, Height) and RunGpuCommands(Device);
  ReleaseMutex(Device^.Lock);
end;

{ --- Suspend to RAM ----------------------------------------------------------- }

procedure SuspendGpu(Context: Pointer);
begin
  { Nothing in flight: every command is waited for under the lock. }
end;

{ The resource made again on the memory it had (the picture kept). }
procedure RestoreScanout(Scanout: PGpuScanout);
var
  Device: PGpuDevice;
begin
  Device := Scanout^.Device;
  if not BeginCreateResource(Device, Scanout^.ResourceId, GpuFormatBlueGreenRedUnused, Scanout^.Width,
       Scanout^.Height) or
     not BeginAttachBacking(Device, Scanout^.ResourceId, Scanout^.FramebufferPhysical,
       QWord(Scanout^.Width) * Scanout^.Height * BytesPerPixel) or
     not BeginSetScanout(Device, Scanout^.Index, Scanout^.ResourceId, Scanout^.Width, Scanout^.Height) or
     not BeginTransferToHost(Device, Scanout^.ResourceId, Scanout^.Width, 0, 0, Scanout^.Width, Scanout^.Height) or
     not BeginFlushResource(Device, Scanout^.ResourceId, 0, 0, Scanout^.Width, Scanout^.Height) then
    Exit;
  RunGpuCommands(Device);
  RestoreGpuCursor(Scanout);
end;

procedure ResumeGpu(Context: Pointer);
var
  Device: PGpuDevice;
  Index: LongInt;
begin
  Device := PGpuDevice(Context);
  Device^.PollOnly := True;
  if RestartGpuQueues(Device) then
    for Index := 0 to ScanoutCount - 1 do
      if Scanouts[Index].Device = Device then
        RestoreScanout(@Scanouts[Index]);
  Device^.PollOnly := False;
end;

{ --- Finding the scanouts ----------------------------------------------------- }

{ virtio-vga keeps its VGA framebuffer in BAR 0. }
function HoldsFramebuffer(Pci: PPciDevice; Physical: QWord): Boolean;
var
  Bar: TPciBar;
begin
  Result := (Physical <> 0) and PciReadBar(Pci, VgaFramebufferBar, Bar) and not Bar.IsIoPort and
    (Bar.PhysicalAddress <> 0) and
    (Bar.SizeInBytes > 0) and (Physical >= Bar.PhysicalAddress) and (Physical < Bar.PhysicalAddress + Bar.SizeInBytes);
end;

function ReadDisplayInfo(Device: PGpuDevice; out Info: TGpuDisplayInfo): Boolean;
begin
  ZeroMemory(@Info, SizeOf(Info));
  Result := (BeginGpuCommand(Device, GpuCommandGetDisplayInfo, SizeOf(TGpuHeader)) <> nil) and
    RunGpuCommands(Device);
  if Result then
    Info := PGpuDisplayInfo(GpuAnswer(Device, 0))^;
end;

{ The scanout's EDID base block into the adapter, if the device has one. }
procedure ReadEdid(Device: PGpuDevice; Scanout: LongWord; var Adapter: TDisplayAdapter);
var
  Command: ^TGpuGetEdid;
  Answer: PGpuEdid;
  Size: TEdidSize;
begin
  if not Device^.HasEdid then
    Exit;
  Command := BeginGpuCommand(Device, GpuCommandGetEdid, SizeOf(TGpuGetEdid));
  if Command = nil then
    Exit;
  Command^.Scanout := Scanout;
  if not RunGpuCommands(Device) then
    Exit;
  Answer := PGpuEdid(GpuAnswer(Device, 0));
  if Answer^.Size < EdidBlockSize then
    Exit;
  CopyMemory(@Adapter.Edid[0], @Answer^.Edid[0], EdidBlockSize);
  Adapter.HasEdid := ParseEdid(@Adapter.Edid[0], Size);
end;

{ Contiguous memory for the largest budget that can be had, at least
  Width x Height. }
function AllocateFramebuffer(Scanout: PGpuScanout; Width, Height: LongWord; out MaximumWidth,
  MaximumHeight: LongWord): Boolean;
var
  Index: LongInt;
  Bytes: QWord;
  Wanted: TFramebufferBudget;
begin
  for Index := Low(Budgets) to High(Budgets) + 1 do
  begin
    if Index <= High(Budgets) then
      Wanted := Budgets[Index]
    else
    begin
      Wanted.Width := Width;
      Wanted.Height := Height;
    end;
    if (Wanted.Width < Width) or (Wanted.Height < Height) then
      Continue;
    Bytes := RoundUpToPage(QWord(Wanted.Width) * Wanted.Height * BytesPerPixel);
    Scanout^.FramebufferPhysical := AllocateZeroedContiguousPhysicalPages(Bytes div PageBytes, AnyAddress,
      PageUsageGeneral);
    if Scanout^.FramebufferPhysical <> 0 then
    begin
      Scanout^.FramebufferBytes := Bytes;
      MaximumWidth := Wanted.Width;
      MaximumHeight := Wanted.Height;
      Exit(True);
    end;
  end;
  Result := False;
end;

{ Why a device or a scanout is not used. }
procedure LogFailure(What: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('virtio-gpu');
  DebugWriteLine(What);
  DebugEndMessage;
end;

procedure LogScanout(Scanout: PGpuScanout; const Adapter: TDisplayAdapter; UsesInterrupts: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('virtio-gpu');
  DebugWrite('scanout ');
  DebugWriteDecimal(Scanout^.Index);
  DebugWrite(': ');
  DebugWriteDecimal(Scanout^.Width);
  DebugWrite('x');
  DebugWriteDecimal(Scanout^.Height);
  DebugWrite(', up to ');
  DebugWriteDecimal(Adapter.MaximumWidth);
  DebugWrite('x');
  DebugWriteDecimal(Adapter.MaximumHeight);
  if Adapter.HasEdid then
    DebugWrite(', EDID');
  if (Adapter.Capabilities and DisplayCapabilityHardwareCursor) <> 0 then
    DebugWrite(', hardware cursor');
  if UsesInterrupts then
    DebugWriteLine(', interrupts by MSI-X')
  else
    DebugWriteLine(', polled');
  DebugEndMessage;
end;

{ Sets the scanout up in its preferred mode and registers its display. }
procedure StartScanout(Device: PGpuDevice; Index: LongWord; const Mode: TGpuDisplayMode);
var
  Scanout: PGpuScanout;
  Adapter: TDisplayAdapter;
  Width: LongWord;
  Height: LongWord;
  Size: TEdidSize;
begin
  if ScanoutCount = MaximumScanoutsUsed then
    Exit;
  Scanout := @Scanouts[ScanoutCount];
  ZeroMemory(Scanout, SizeOf(Scanout^));
  Scanout^.Device := Device;
  Scanout^.Index := Index;
  ZeroMemory(@Adapter, SizeOf(Adapter));
  ReadEdid(Device, Index, Adapter);
  Width := Mode.Rectangle.Width;
  Height := Mode.Rectangle.Height;
  if ((Width = 0) or (Height = 0)) and Adapter.HasEdid and ParseEdid(@Adapter.Edid[0], Size) then
  begin
    Width := Size.PreferredWidth;
    Height := Size.PreferredHeight;
  end;
  if (Width = 0) or (Height = 0) then
  begin
    Width := FallbackWidth;
    Height := FallbackHeight;
  end;
  if not AllocateFramebuffer(Scanout, Width, Height, Adapter.MaximumWidth, Adapter.MaximumHeight) then
  begin
    LogFailure('no contiguous memory for a framebuffer');
    Exit;
  end;
  if not ShowNewResource(Scanout, Width, Height) then
  begin
    LogFailure('the device refused the scanout''s resource');
    Exit;
  end;
  Adapter.FramebufferPhysical := Scanout^.FramebufferPhysical;
  Adapter.FramebufferBytes := Scanout^.FramebufferBytes;
  Adapter.PixelFormat := DisplayFormatBlueGreenRed;
  Adapter.Width := Width;
  Adapter.Height := Height;
  Adapter.Pitch := QWord(Width) * BytesPerPixel;
  Adapter.SetMode := @SetGpuMode;
  Adapter.Flush := @FlushGpu;
  Adapter.Capabilities := DisplayCapabilityNeedsFlush or DisplayCapabilityMemoryFramebuffer;
  Adapter.Context := Scanout;
  Scanout^.CursorImagePhysical := AllocateZeroedContiguousPhysicalPages(RoundUpToPage(DisplayCursorImageBytes) div
    PageBytes, AnyAddress, PageUsageGeneral);
  if (Scanout^.CursorImagePhysical <> 0) and SetUpGpuCursor(Scanout) then
  begin
    Adapter.CursorImagePhysical := Scanout^.CursorImagePhysical;
    Adapter.UpdateCursor := @UpdateGpuCursor;
    Adapter.Capabilities := Adapter.Capabilities or DisplayCapabilityHardwareCursor;
  end;
  Inc(ScanoutCount);
  LogScanout(Scanout, Adapter, Device^.Virtio.UsesInterrupts);
  RegisterDisplay(Adapter);
end;

function StartDevice(Pci: PPciDevice): LongInt;
var
  Device: PGpuDevice;
  Accepted: QWord;
  Info: TGpuDisplayInfo;
  Index: LongWord;
  ScanoutsOffered: LongWord;
  Before: LongInt;
begin
  Result := 0;
  Device := PGpuDevice(AllocateZeroedKernelMemory(SizeOf(TGpuDevice)));
  if Device = nil then
    Exit;
  if not OpenVirtioDevice(Pci, Device^.Virtio) then
  begin
    LogFailure('not a virtio 1.x device');
    Exit;
  end;
  if not NegotiateVirtioFeatures(Device^.Virtio, QWord(1) shl GpuFeatureEdid, Accepted) or
     not SetUpGpuQueues(Device) then
  begin
    LogFailure('the features or the queues were refused');
    FailVirtioDevice(Device^.Virtio);
    Exit;
  end;
  Device^.HasEdid := (Accepted and (QWord(1) shl GpuFeatureEdid)) <> 0;
  if not ReadDisplayInfo(Device, Info) then
  begin
    LogFailure('no answer to the display information');
    FailVirtioDevice(Device^.Virtio);
    Exit;
  end;
  ScanoutsOffered := PLongWord(Device^.Virtio.DeviceConfiguration + GpuConfigurationScanoutCount)^;
  if ScanoutsOffered > GpuMaximumScanouts then
    ScanoutsOffered := GpuMaximumScanouts;
  Before := ScanoutCount;
  for Index := 0 to GpuMaximumScanouts - 1 do
    if (Index < ScanoutsOffered) and (Info.Modes[Index].Enabled <> 0) then
      StartScanout(Device, Index, Info.Modes[Index]);
  { None enabled (no monitor said so): the first anyway. }
  if (ScanoutCount = Before) and (ScanoutsOffered > 0) then
    StartScanout(Device, 0, Info.Modes[0]);
  Result := ScanoutCount - Before;
  if Result > 0 then
    RegisterPowerHandler('virtio GPU', PowerStageDevices, @SuspendGpu, @ResumeGpu, Device);
end;

function RegisterVirtioGpuDisplays(const Framebuffer: TFramebufferInformation): LongInt;
var
  Index: LongInt;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.VendorId <> VirtioVendorId) or (Pci^.DeviceId <> VirtioModernDeviceIdBase + VirtioDeviceTypeGpu) or
       HoldsFramebuffer(Pci, Framebuffer.PhysicalBase) then
      Continue;
    Result := Result + StartDevice(Pci);
  end;
end;

end.

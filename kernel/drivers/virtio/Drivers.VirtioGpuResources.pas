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
  A virtio GPU's scanouts and the 2D resources they show.

  A resource is a picture the host keeps (a width, a height, a pixel
  format), backed by guest memory it copies from: here one physically
  contiguous piece each, lines of width times 4 bytes. Drawing goes to
  that memory; copying a rectangle to the host (transfer to host) and
  then flushing it shows it on the scanouts the resource is set to.

  Each routine here only begins its command in the device's batch
  (Drivers.VirtioGpuQueues); the caller runs the batch.
}
unit Drivers.VirtioGpuResources;

{$mode objfpc}

interface

uses
  Drivers.DisplayDevice,
  Drivers.VirtioGpuQueues;

type
  PGpuScanout = ^TGpuScanout;
  TGpuScanout = record
    Device: PGpuDevice;
    Index: LongWord;
    { The resource shown, and its size (the mode). }
    ResourceId: LongWord;
    Width: LongWord;
    Height: LongWord;
    { The memory behind it: enough for the largest mode offered. }
    FramebufferPhysical: QWord;
    FramebufferBytes: QWord;
    { The cursor's 64 x 64 resource, backed by the cursor image page. }
    CursorResourceId: LongWord;
    CursorImagePhysical: QWord;
    { What the device was last told of the cursor. }
    Cursor: TDisplayCursor;
    CursorShown: Boolean;
    { The cursor's place last written to the log. }
    LoggedX: LongInt;
    LoggedY: LongInt;
  end;

function NewGpuResourceId(Device: PGpuDevice): LongWord;
function BeginCreateResource(Device: PGpuDevice; ResourceId, Format, Width, Height: LongWord): Boolean;
function BeginAttachBacking(Device: PGpuDevice; ResourceId: LongWord; Physical, Bytes: QWord): Boolean;
function BeginUnreferenceResource(Device: PGpuDevice; ResourceId: LongWord): Boolean;
function BeginSetScanout(Device: PGpuDevice; Scanout, ResourceId, Width, Height: LongWord): Boolean;
{ Copies the rectangle from the backing (lines of Width * 4 bytes, the
  resource's width) to the host's copy. }
function BeginTransferToHost(Device: PGpuDevice; ResourceId, ResourceWidth, X, Y, Width, Height: LongWord): Boolean;
function BeginFlushResource(Device: PGpuDevice; ResourceId, X, Y, Width, Height: LongWord): Boolean;

implementation

uses
  Drivers.VirtioGpuProtocol;

const
  BytesPerPixel = 4;

function NewGpuResourceId(Device: PGpuDevice): LongWord;
begin
  Result := Device^.NextResourceId;
  Inc(Device^.NextResourceId);
  if Device^.NextResourceId = 0 then
    Device^.NextResourceId := 1;
end;

procedure SetRectangle(out Rectangle: TGpuRectangle; X, Y, Width, Height: LongWord);
begin
  Rectangle.X := X;
  Rectangle.Y := Y;
  Rectangle.Width := Width;
  Rectangle.Height := Height;
end;

function BeginCreateResource(Device: PGpuDevice; ResourceId, Format, Width, Height: LongWord): Boolean;
var
  Command: ^TGpuResourceCreate2d;
begin
  Command := BeginGpuCommand(Device, GpuCommandResourceCreate2d, SizeOf(TGpuResourceCreate2d));
  Result := Command <> nil;
  if not Result then
    Exit;
  Command^.ResourceId := ResourceId;
  Command^.Format := Format;
  Command^.Width := Width;
  Command^.Height := Height;
end;

function BeginAttachBacking(Device: PGpuDevice; ResourceId: LongWord; Physical, Bytes: QWord): Boolean;
var
  Command: ^TGpuAttachBacking;
begin
  Command := BeginGpuCommand(Device, GpuCommandResourceAttachBacking, SizeOf(TGpuAttachBacking));
  Result := Command <> nil;
  if not Result then
    Exit;
  Command^.ResourceId := ResourceId;
  Command^.EntryCount := 1;
  Command^.Entry.Address := Physical;
  Command^.Entry.Length := LongWord(Bytes);
end;

function BeginUnreferenceResource(Device: PGpuDevice; ResourceId: LongWord): Boolean;
var
  Command: ^TGpuResourceUnreference;
begin
  Command := BeginGpuCommand(Device, GpuCommandResourceUnreference, SizeOf(TGpuResourceUnreference));
  Result := Command <> nil;
  if Result then
    Command^.ResourceId := ResourceId;
end;

function BeginSetScanout(Device: PGpuDevice; Scanout, ResourceId, Width, Height: LongWord): Boolean;
var
  Command: ^TGpuSetScanout;
begin
  Command := BeginGpuCommand(Device, GpuCommandSetScanout, SizeOf(TGpuSetScanout));
  Result := Command <> nil;
  if not Result then
    Exit;
  SetRectangle(Command^.Rectangle, 0, 0, Width, Height);
  Command^.ScanoutId := Scanout;
  Command^.ResourceId := ResourceId;
end;

function BeginTransferToHost(Device: PGpuDevice; ResourceId, ResourceWidth, X, Y, Width, Height: LongWord): Boolean;
var
  Command: ^TGpuTransferToHost2d;
begin
  Command := BeginGpuCommand(Device, GpuCommandTransferToHost2d, SizeOf(TGpuTransferToHost2d));
  Result := Command <> nil;
  if not Result then
    Exit;
  SetRectangle(Command^.Rectangle, X, Y, Width, Height);
  Command^.Offset := (QWord(Y) * ResourceWidth + X) * BytesPerPixel;
  Command^.ResourceId := ResourceId;
end;

function BeginFlushResource(Device: PGpuDevice; ResourceId, X, Y, Width, Height: LongWord): Boolean;
var
  Command: ^TGpuResourceFlush;
begin
  Command := BeginGpuCommand(Device, GpuCommandResourceFlush, SizeOf(TGpuResourceFlush));
  Result := Command <> nil;
  if not Result then
    Exit;
  SetRectangle(Command^.Rectangle, X, Y, Width, Height);
  Command^.ResourceId := ResourceId;
end;

end.

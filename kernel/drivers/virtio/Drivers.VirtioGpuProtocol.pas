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
  The virtio GPU device's commands (virtio 1.x, section 5.7), the 2D
  part only: what travels on its control queue and its cursor queue.

  Every command starts with a header (its type, flags, a fence number
  and a context) and is answered with a header whose type says how it
  went (OK_*, or an error). All numbers are little-endian, as the
  processor's are.
}
unit Drivers.VirtioGpuProtocol;

{$mode objfpc}

interface

const
  GpuControlQueue = 0;
  GpuCursorQueue = 1;

  { Feature bits. }
  GpuFeatureEdid = 1;

  { Device configuration: events_read, events_clear, num_scanouts. }
  GpuConfigurationEventsRead = 0;
  GpuConfigurationEventsClear = 4;
  GpuConfigurationScanoutCount = 8;
  GpuEventDisplay = 1;

  GpuMaximumScanouts = 16;

  { Commands. }
  GpuCommandGetDisplayInfo = $0100;
  GpuCommandResourceCreate2d = $0101;
  GpuCommandResourceUnreference = $0102;
  GpuCommandSetScanout = $0103;
  GpuCommandResourceFlush = $0104;
  GpuCommandTransferToHost2d = $0105;
  GpuCommandResourceAttachBacking = $0106;
  GpuCommandGetEdid = $010A;
  GpuCommandUpdateCursor = $0300;
  GpuCommandMoveCursor = $0301;

  { Answers. }
  GpuAnswerOkNoData = $1100;
  GpuAnswerOkDisplayInfo = $1101;
  GpuAnswerOkEdid = $1104;

  { Pixel formats: the bytes in memory, first to last. }
  GpuFormatBlueGreenRedAlpha = 1;
  GpuFormatBlueGreenRedUnused = 2;
  GpuFormatRedGreenBlueUnused = 134;

  GpuEdidBytes = 1024;

type
  TGpuHeader = packed record
    CommandType: LongWord;
    Flags: LongWord;
    FenceId: QWord;
    ContextId: LongWord;
    RingIndex: Byte;
    Padding: array[0..2] of Byte;
  end;

  TGpuRectangle = packed record
    X: LongWord;
    Y: LongWord;
    Width: LongWord;
    Height: LongWord;
  end;

  TGpuDisplayMode = packed record
    Rectangle: TGpuRectangle;
    Enabled: LongWord;
    Flags: LongWord;
  end;

  TGpuDisplayInfo = packed record
    Header: TGpuHeader;
    Modes: array[0..GpuMaximumScanouts - 1] of TGpuDisplayMode;
  end;
  PGpuDisplayInfo = ^TGpuDisplayInfo;

  TGpuGetEdid = packed record
    Header: TGpuHeader;
    Scanout: LongWord;
    Padding: LongWord;
  end;

  TGpuEdid = packed record
    Header: TGpuHeader;
    Size: LongWord;
    Padding: LongWord;
    Edid: array[0..GpuEdidBytes - 1] of Byte;
  end;
  PGpuEdid = ^TGpuEdid;

  TGpuResourceCreate2d = packed record
    Header: TGpuHeader;
    ResourceId: LongWord;
    Format: LongWord;
    Width: LongWord;
    Height: LongWord;
  end;

  TGpuResourceUnreference = packed record
    Header: TGpuHeader;
    ResourceId: LongWord;
    Padding: LongWord;
  end;

  TGpuMemoryEntry = packed record
    Address: QWord;
    Length: LongWord;
    Padding: LongWord;
  end;

  { With one memory entry: each backing here is contiguous. }
  TGpuAttachBacking = packed record
    Header: TGpuHeader;
    ResourceId: LongWord;
    EntryCount: LongWord;
    Entry: TGpuMemoryEntry;
  end;

  TGpuSetScanout = packed record
    Header: TGpuHeader;
    Rectangle: TGpuRectangle;
    ScanoutId: LongWord;
    ResourceId: LongWord;
  end;

  TGpuResourceFlush = packed record
    Header: TGpuHeader;
    Rectangle: TGpuRectangle;
    ResourceId: LongWord;
    Padding: LongWord;
  end;

  TGpuTransferToHost2d = packed record
    Header: TGpuHeader;
    Rectangle: TGpuRectangle;
    { Where the rectangle's first pixel is in the backing. }
    Offset: QWord;
    ResourceId: LongWord;
    Padding: LongWord;
  end;

  TGpuCursorPosition = packed record
    ScanoutId: LongWord;
    X: LongWord;
    Y: LongWord;
    Padding: LongWord;
  end;

  { Both cursor commands: moving uses only the position. Resource 0
    hides the cursor. }
  TGpuUpdateCursor = packed record
    Header: TGpuHeader;
    Position: TGpuCursorPosition;
    ResourceId: LongWord;
    HotspotX: LongWord;
    HotspotY: LongWord;
    Padding: LongWord;
  end;

implementation

end.

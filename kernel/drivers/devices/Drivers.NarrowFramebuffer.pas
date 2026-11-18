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
  A firmware framebuffer of 16 bits a pixel (r5g6b5: what a Raspberry
  Pi's firmware sets up unless config.txt asks for 32 bits) as a display.

  Programs draw 32-bit pixels (DisplayFormat*). The display gets a
  framebuffer of that kind in ordinary memory and says it needs flushing
  (DisplayCapabilityNeedsFlush, as a virtio GPU does): each rectangle a
  program names is narrowed into the real framebuffer then.
}
unit Drivers.NarrowFramebuffer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information;

{ Registers the display; False if Framebuffer is not 16 bits a pixel or
  there is no memory for the copy. }
function RegisterNarrowFramebufferDisplay(const Framebuffer: TFramebufferInformation): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Drivers.DisplayDevice;

const
  WideBytesPerPixel = 4;
  NarrowBytesPerPixel = 2;
  PageBytes = 4096;
  AnyAddress = High(QWord);

type
  TNarrowScreen = record
    { The real framebuffer, through the window. }
    Screen: PByte;
    ScreenPitch: QWord;
    { The 32-bit copy programs draw in. }
    Copy: PByte;
    CopyPitch: QWord;
    Width: LongWord;
    Height: LongWord;
  end;

var
  NarrowScreen: TNarrowScreen;

function NarrowPixel(Pixel: LongWord): Word;
begin
  Result := Word(((Pixel shr 8) and $F800) or ((Pixel shr 5) and $07E0) or ((Pixel shr 3) and $001F));
end;

function FlushNarrowScreen(Adapter: PDisplayAdapter; X, Y, Width, Height: LongWord): Boolean;
var
  Row: LongWord;
  Column: LongWord;
  Source: PLongWord;
  Destination: PWord;
begin
  Result := False;
  if (X >= NarrowScreen.Width) or (Y >= NarrowScreen.Height) then
    Exit;
  if Width > NarrowScreen.Width - X then
    Width := NarrowScreen.Width - X;
  if Height > NarrowScreen.Height - Y then
    Height := NarrowScreen.Height - Y;
  Row := 0;
  while Row < Height do
  begin
    Source := PLongWord(NarrowScreen.Copy + QWord(Y + Row) * NarrowScreen.CopyPitch) + X;
    Destination := PWord(NarrowScreen.Screen + QWord(Y + Row) * NarrowScreen.ScreenPitch) + X;
    Column := 0;
    while Column < Width do
    begin
      Destination[Column] := NarrowPixel(Source[Column]);
      Inc(Column);
    end;
    Inc(Row);
  end;
  Result := True;
end;

function RegisterNarrowFramebufferDisplay(const Framebuffer: TFramebufferInformation): Boolean;
var
  Adapter: TDisplayAdapter;
  CopyBytes: QWord;
  CopyPhysical: QWord;
begin
  Result := False;
  if (Framebuffer.PixelFormat <> PixelFormatRedGreenBlue565) or (Framebuffer.PhysicalBase = 0) or
     (Framebuffer.Width = 0) then
    Exit;
  CopyBytes := (QWord(Framebuffer.Width) * Framebuffer.Height * WideBytesPerPixel + PageBytes - 1) and
    not QWord(PageBytes - 1);
  CopyPhysical := AllocateZeroedContiguousPhysicalPages(CopyBytes div PageBytes, AnyAddress, PageUsageGeneral);
  if CopyPhysical = 0 then
    Exit;
  NarrowScreen.Screen := PByte(PhysicalToVirtual(Framebuffer.PhysicalBase));
  NarrowScreen.ScreenPitch := QWord(Framebuffer.PixelsPerScanLine) * NarrowBytesPerPixel;
  NarrowScreen.Copy := PByte(PhysicalToVirtual(CopyPhysical));
  NarrowScreen.CopyPitch := QWord(Framebuffer.Width) * WideBytesPerPixel;
  NarrowScreen.Width := Framebuffer.Width;
  NarrowScreen.Height := Framebuffer.Height;

  ZeroMemory(@Adapter, SizeOf(Adapter));
  Adapter.FramebufferPhysical := CopyPhysical;
  Adapter.FramebufferBytes := CopyBytes;
  Adapter.Width := Framebuffer.Width;
  Adapter.Height := Framebuffer.Height;
  Adapter.Pitch := NarrowScreen.CopyPitch;
  Adapter.MaximumWidth := Framebuffer.Width;
  Adapter.MaximumHeight := Framebuffer.Height;
  Adapter.PixelFormat := DisplayFormatBlueGreenRed;
  Adapter.Capabilities := DisplayCapabilityNeedsFlush or DisplayCapabilityMemoryFramebuffer;
  Adapter.Flush := @FlushNarrowScreen;
  Adapter.Context := @NarrowScreen;
  Result := RegisterDisplay(Adapter);
end;

end.

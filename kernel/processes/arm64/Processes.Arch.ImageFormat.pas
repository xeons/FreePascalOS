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
  What ELF programs and libraries look like on AArch64, for the image
  loader (Processes.ImageLoader) and the thread storage
  (Processes.ThreadStorage): the machine, the relocation types, and the
  thread-local storage layout.

  Thread-local storage is "variant I": the thread pointer (TPIDR_EL0)
  points at the 16-byte thread control block, and the TLS blocks of the
  program and its libraries follow it, the program's first, at
  TP + align(16, its alignment) as the linker expects for the local exec
  model. A module's TlsOffset is the distance from the thread pointer up
  to its block.

      region start           thread pointer
      | (alignment) runtime word | control block | program TLS block | ... |

  The word just below the thread pointer belongs to the user runtime
  (ThreadBlockDynamicVectorOffset: its dynamic TLS vector); the thread
  pointer lies the largest TLS alignment (at least 16 bytes) into the
  region, which starts on a page, so it stays aligned for every block.

  TLS descriptors (R_AARCH64_TLSDESC, what C compilers use for the
  general dynamic model) get libsystem's static resolver, which returns
  the descriptor's second word: the variable's offset from the thread
  pointer.
}
unit Processes.Arch.ImageFormat;

{$mode objfpc}

interface

uses
  Elf64;

const
  ImageMachine = ElfMachineAarch64;
  { The resolver for TLS descriptors of static TLS, in libsystem. }
  TlsDescriptorResolverName = '__tlsdesc_static';
  { The resolver for TLS descriptors of libraries loaded late (dynamic
    TLS: the runtime makes each thread's block when first touched). }
  TlsDynamicDescriptorResolverName = '__tlsdesc_dynamic';

type
  { What a relocation does, whatever its number on this processor. }
  TRelocationKind = (
    RelocationKindNone,
    RelocationKindRelative,          { base + addend }
    RelocationKindAbsolute64,        { symbol + addend }
    RelocationKindSymbol,            { symbol (GOT entries, PLT slots) }
    RelocationKindCopy,              { the symbol's data copied here }
    RelocationKindTlsModule,         { the module id for __tls_get_addr }
    RelocationKindTlsOffset,         { the offset in the module's block }
    RelocationKindThreadPointerOffset64,
    RelocationKindThreadPointerOffset32,
    { A TLS descriptor: the resolver's address and its argument. }
    RelocationKindTlsDescriptor,
    RelocationKindUnsupported);

function ClassifyRelocation(RelocationType: LongWord): TRelocationKind;

{ Places a TLS block of BlockSize bytes, aligned to Alignment, after the
  StaticTlsSize bytes placed so far. Returns the block's TlsOffset and
  the new StaticTlsSize. }
function PlaceStaticTlsBlock(var StaticTlsSize: QWord; BlockSize, Alignment: QWord): QWord;

{ The address of a module's block minus the thread pointer. }
function TlsBlockDisplacement(TlsOffset: QWord): Int64;

{ The size of a thread's data region (control block and TLS blocks) and
  where the thread pointer is in it, for StaticTlsSize bytes of TLS
  whose largest alignment is Alignment. The region starts on a page. }
procedure LayOutThreadRegion(StaticTlsSize, Alignment: QWord; out RegionSize, ThreadPointerOffset: QWord);

implementation

uses
  Abi.SystemCalls;

function ClassifyRelocation(RelocationType: LongWord): TRelocationKind;
begin
  case RelocationType of
    RelocationAarch64None, RelocationAarch64NoneWithdrawn: Result := RelocationKindNone;
    RelocationAarch64Relative: Result := RelocationKindRelative;
    RelocationAarch64Absolute64: Result := RelocationKindAbsolute64;
    RelocationAarch64GlobalData, RelocationAarch64JumpSlot: Result := RelocationKindSymbol;
    RelocationAarch64Copy: Result := RelocationKindCopy;
    RelocationAarch64TlsModule64: Result := RelocationKindTlsModule;
    RelocationAarch64TlsOffset64: Result := RelocationKindTlsOffset;
    RelocationAarch64ThreadPointerOffset64: Result := RelocationKindThreadPointerOffset64;
    RelocationAarch64TlsDescriptor: Result := RelocationKindTlsDescriptor;
  else
    Result := RelocationKindUnsupported;
  end;
end;

function PlaceStaticTlsBlock(var StaticTlsSize: QWord; BlockSize, Alignment: QWord): QWord;
var
  Start: QWord;
begin
  { The control block comes first. }
  Start := StaticTlsSize;
  if Start < ThreadBlockSize then
    Start := ThreadBlockSize;
  Result := (Start + Alignment - 1) and not (Alignment - 1);
  StaticTlsSize := Result + BlockSize;
end;

function TlsBlockDisplacement(TlsOffset: QWord): Int64;
begin
  Result := Int64(TlsOffset);
end;

procedure LayOutThreadRegion(StaticTlsSize, Alignment: QWord; out RegionSize, ThreadPointerOffset: QWord);
begin
  { The region starts on a page and alignments are at most a page, so a
    thread pointer Alignment bytes in is aligned for every block, with
    room below it for the runtime's word. }
  if StaticTlsSize < ThreadBlockSize then
    StaticTlsSize := ThreadBlockSize;
  if Alignment < 16 then
    Alignment := 16;
  ThreadPointerOffset := Alignment;
  RegionSize := (ThreadPointerOffset + StaticTlsSize + 15) and not QWord(15);
end;

end.
